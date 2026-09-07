USE ANALISIS_DATOS;
GO

/*
========================================================================================
PROCEDIMIENTOS DE CARGA del modelo de aplicacion de pagos
========================================================================================
Cuatro procs, incrementales por ventana de fecha_compensacion del PAGO. Se corren SIEMPRE
en este orden - cada uno depende del anterior:

    1. gold.load_fact_pagos
    2. gold.load_fact_facturas
    3. gold.load_fact_aplicacion_pagos
    4. gold.load_fact_pagos_sin_aplicacion

Firma comun: @fecha_desde DATE, @fecha_hasta DATE = NULL
  @fecha_desde NULL  -> arranca en el primer dia del mes anterior (modo diario)
  @fecha_hasta NULL  -> sin tope superior

--- ATOMICIDAD: EL DELETE Y EL INSERT VAN JUNTOS O NO VAN ---
Cada proc borra su ventana antes de insertarla. Los dos van dentro de UNA transaccion,
con XACT_ABORT ON y ROLLBACK en el CATCH.
No es precaucion teorica: el 2026-09-07 estos procs fallaron dos veces en el dia y las
dos dejaron la tabla mutilada, porque el DELETE ya habia entrado y el INSERT no.
    load_fact_pagos     -> gold.fact_pagos bajo de 614,353 a 601,392 filas
    load_fact_facturas  -> se perdieron las compensadas desde agosto (PK duplicada)
Lo grave no fue perder las filas: fue que el proc muere con un mensaje que nadie tiene
por que estar leyendo, y la tabla queda consultable, con menos dinero, sin senal alguna.
Un reporte contra esa tabla se ve normal.

--- BORRADO POR LOTES, NO DE UN JALON ---
El DELETE va en lotes de 50,000 filas con WHILE + TOP. OJO: adentro de la transaccion el
loteo YA NO acota el log - el log no puede truncarse hasta el COMMIT, asi que la ventana
completa vive ahi de todas formas. Lo que sigue haciendo es evitar un solo DELETE gigante
(escalamiento de bloqueos y un rollback monstruoso si truena).
Lo que acota el log es el TAMANO DE LA VENTANA, y por eso estos procs son SOLO para carga
incremental: una ventana diaria/mensual son ~150K filas y corre en segundos. El backfill
historico NO los usa - inserta por anio en backfill_fact_aplicacion_pagos.sql, justamente
porque un solo INSERT de 3.2M filas llena los 2 GB de log de este servidor (ya provoco
Msg 9002 en este proyecto). No llames a estos procs con @fecha_desde en 2022.

--- LAS FACTURAS LLEVAN UN PATRON MIXTO, Y NO ES UN DESCUIDO ---
gold.fact_facturas junta dos poblaciones con ritmos distintos:
  compensadas -> historia inmutable. Se cargan por ventana y ya no cambian.
  abiertas    -> FOTO DEL PRESENTE. Cambian todos los dias: una factura abierta hoy
                 puede estar compensada manana, y entonces tiene que DESAPARECER del
                 lado abierto.
Por eso el lado abierto se borra y recarga COMPLETO en cada corrida, sin ventana. Si se
cargara por ventana, se acumularian facturas "abiertas" que se pagaron hace meses.
Es la misma logica del reset FBRA aplicada a la carga: bsid manda sobre el estado de hoy.

--- LOS TRES FILTROS QUE DEFINEN EL MODELO ---
Aparecen en varios procs; si se cambian, hay que cambiarlos en todos:
  1. alcance de cliente: canal 10/40/60, estatus <> FUERA_DE_ALCANCE
  2. pagos: DZ + sgtxt 'Asignacion Aut. Deposito', EXCLUYENDO lineas de documento hijo
  3. facturas: debe_haber='S', clase F% o D1, EXCLUYENDO resets FBRA del lado compensado
========================================================================================
*/


-- ========================================================================================
-- 1. gold.load_fact_pagos
-- ========================================================================================
IF OBJECT_ID('gold.load_fact_pagos', 'P') IS NOT NULL
    DROP PROCEDURE gold.load_fact_pagos;
GO

CREATE PROCEDURE gold.load_fact_pagos
    @fecha_desde DATE = NULL,
    @fecha_hasta DATE = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;   -- ver "ATOMICIDAD" en la cabecera
    DECLARE @t0 DATETIME = GETDATE(), @n INT, @lote INT;

    IF @fecha_desde IS NULL
        SET @fecha_desde = DATEADD(MONTH, DATEDIFF(MONTH, 0, GETDATE()) - 1, 0);

    BEGIN TRY
        PRINT '>> gold.load_fact_pagos | fecha_compensacion >= ' + CONVERT(VARCHAR(10), @fecha_desde, 120)
            + CASE WHEN @fecha_hasta IS NULL THEN ' (sin tope)'
                   ELSE ' y < ' + CONVERT(VARCHAR(10), @fecha_hasta, 120) END;

        -- Ver "ATOMICIDAD" en la cabecera. Todo lo que sigue va junto o no va.
        BEGIN TRANSACTION;

        -- Borrado de la ventana, en lotes (ver cabecera).
        SET @lote = 1;
        WHILE @lote > 0
        BEGIN
            DELETE TOP (50000) FROM gold.fact_pagos
            WHERE fecha_compensacion >= @fecha_desde
              AND (@fecha_hasta IS NULL OR fecha_compensacion < @fecha_hasta);
            SET @lote = @@ROWCOUNT;
        END

        INSERT INTO gold.fact_pagos (
            sociedad, cliente_id, ejercicio, documento_id, posicion,
            documento_compensacion, ejercicio_compensacion,
            fecha_documento, fecha_contabilizacion, fecha_compensacion,
            monto, texto, clave_contabilizacion,
            cliente_comercial_sk, cliente_credito_sk
        )
        SELECT
            b.sociedad, b.cliente_id, b.ejercicio, b.documento_id, b.posicion,
            b.documento_compensacion, b.ejercicio_compensacion,
            b.fecha_documento, b.fecha_contabilizacion, b.fecha_compensacion,
            -- silver.sap_bsad NUNCA trae el monto firmado: siempre positivo.
            CASE WHEN b.debe_haber = 'H' THEN b.monto_moneda_local
                 ELSE -1 * b.monto_moneda_local END,
            b.sgtxt, b.clave_contabilizacion,
            dcc.id_surrogate, dck.id_surrogate
        FROM silver.sap_bsad b
        LEFT JOIN gold.dim_cliente_comercial dcc
               ON dcc.cliente_id = b.cliente_id
              AND b.fecha_contabilizacion >= dcc.fecha_inicio_vigencia
              AND (dcc.fecha_fin_vigencia IS NULL OR b.fecha_contabilizacion <= dcc.fecha_fin_vigencia)
        LEFT JOIN gold.dim_cliente_credito dck
               ON dck.cliente_id = b.cliente_id
              AND b.fecha_contabilizacion >= dck.fecha_inicio_vigencia
              AND (dck.fecha_fin_vigencia IS NULL OR b.fecha_contabilizacion <= dck.fecha_fin_vigencia)
        WHERE b.mandante = '400'
          AND b.clase_documento = 'DZ'
          AND b.sgtxt = 'Asignación Aut. Deposito'
          AND b.fecha_compensacion >= @fecha_desde
          AND (@fecha_hasta IS NULL OR b.fecha_compensacion < @fecha_hasta)
          AND b.cliente_id IN (
                SELECT c1.cliente_id FROM gold.dim_cliente_comercial c1
                WHERE c1.estatus_comercial <> 'FUERA_DE_ALCANCE'
                  AND c1.canal_distribucion IN (10, 40, 60))
          -- Excluye lineas de DOCUMENTO HIJO: su clave 15 reaplica dinero ya contado en
          -- la clave 11 y su clave 08 es el espejo. Sin esto se cuenta dos veces.
          -- El alias `b.` NO es cosmetico: sin calificar, la columna se resuelve contra
          -- la tabla INTERNA y la condicion se vuelve siempre verdadera.
          AND NOT EXISTS (
                SELECT 1 FROM silver.sap_bsad h
                WHERE h.mandante = '400' AND h.clase_documento = 'DZ'
                  AND h.clave_contabilizacion = '11'
                  AND h.documento_compensacion = b.documento_id);
        SET @n = @@ROWCOUNT;

        COMMIT TRANSACTION;

        PRINT '   Filas: ' + CAST(@n AS VARCHAR(12))
            + ' | Duracion: ' + CAST(DATEDIFF(SECOND, @t0, GETDATE()) AS VARCHAR(10)) + ' s';
    END TRY
    BEGIN CATCH
        -- Sin esto la ventana queda con el hueco del DELETE y el proc muere
        -- "limpio": el reporte del dia sale con menos dinero y nada avisa.
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        PRINT 'ERROR en gold.load_fact_pagos: ' + ERROR_MESSAGE();
        THROW;
    END CATCH;
END;
GO
PRINT 'Procedure gold.load_fact_pagos created successfully.';
GO


-- ========================================================================================
-- 2. gold.load_fact_facturas   (patron MIXTO - ver cabecera)
-- ========================================================================================
IF OBJECT_ID('gold.load_fact_facturas', 'P') IS NOT NULL
    DROP PROCEDURE gold.load_fact_facturas;
GO

CREATE PROCEDURE gold.load_fact_facturas
    @fecha_desde DATE = NULL,
    @fecha_hasta DATE = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;   -- ver "ATOMICIDAD" en la cabecera
    DECLARE @t0 DATETIME = GETDATE(), @n_comp INT, @n_abie INT, @lote INT;

    IF @fecha_desde IS NULL
        SET @fecha_desde = DATEADD(MONTH, DATEDIFF(MONTH, 0, GETDATE()) - 1, 0);

    /* @fecha_hasta SE IGNORA EN EL LADO COMPENSADO, Y ES DELIBERADO.
       Un pago compensado en el mes puede alcanzar, via el segundo salto
       (virgen -> hijo -> grupo final), una factura que se compenso DESPUES. Poner techo
       trunca esas cadenas: probado el 2026-09-07, cargar agosto con @fecha_hasta
       '2026-09-01' dejo fuera 181 lineas de factura cuyo grupo final cae en septiembre,
       y el puente perdio exactamente esas 181 filas de SEGUNDO_SALTO (1,650 en vez de
       1,831). El parametro se acepta por consistencia de firma, pero aqui no aplica.
       Consecuencia: este proc siempre recarga de @fecha_desde en adelante. Para la carga
       diaria eso son ~2 meses; para el backfill se corre UNA sola vez desde 2022. */
    BEGIN TRY
        PRINT '>> gold.load_fact_facturas | compensadas desde la fecha (SIN techo) + abiertas recarga completa';

        -- Ver "ATOMICIDAD" en la cabecera. Todo lo que sigue va junto o no va.
        BEGIN TRANSACTION;

        ------------------------------------------------------- BORRADO (LAS DOS)
        /* LOS DOS DELETE VAN ANTES DE LOS DOS INSERT, Y NO ES ESTILO.
           La PK es (sociedad, cliente_id, ejercicio, documento_id, posicion): NO lleva
           flag_compensada. Una factura que estaba abierta y ya se compenso ocupa esa PK
           dos veces - la fila vieja con flag 0 y la nueva con flag 1 - asi que si el
           INSERT de compensadas corre antes de borrar las abiertas, choca contra su
           propia version anterior.
           Probado el 2026-09-07: con el orden viejo la primera recarga despues del
           backfill murio con "Violation of PRIMARY KEY constraint 'PK_fact_facturas'...
           (2000, 10000109, 2026, 7404851852, 1)", y habia 845 facturas en ese estado.
           No se veia en el backfill porque ahi la tabla arrancaba vacia. */

        -- Compensadas: solo la ventana. SIN @fecha_hasta a proposito, ver nota arriba.
        SET @lote = 1;
        WHILE @lote > 0
        BEGIN
            DELETE TOP (50000) FROM gold.fact_facturas
            WHERE flag_compensada = 1
              AND fecha_compensacion >= @fecha_desde;
            SET @lote = @@ROWCOUNT;
        END

        -- Abiertas: TODAS, sin ventana. Ver cabecera: es una foto del presente.
        SET @lote = 1;
        WHILE @lote > 0
        BEGIN
            DELETE TOP (50000) FROM gold.fact_facturas WHERE flag_compensada = 0;
            SET @lote = @@ROWCOUNT;
        END

        ---------------------------------------------------------------- COMPENSADAS
        INSERT INTO gold.fact_facturas (
            sociedad, cliente_id, ejercicio, documento_id, posicion,
            documento_compensacion, ejercicio_compensacion, clase_documento,
            fecha_documento, fecha_vencimiento, fecha_contabilizacion, fecha_compensacion,
            monto, clave_contabilizacion, flag_compensada,
            cliente_comercial_sk, cliente_credito_sk
        )
        SELECT b.sociedad, b.cliente_id, b.ejercicio, b.documento_id, b.posicion,
               b.documento_compensacion, b.ejercicio_compensacion, b.clase_documento,
               b.fecha_documento, b.fecha_vencimiento, b.fecha_contabilizacion, b.fecha_compensacion,
               b.monto_moneda_local, b.clave_contabilizacion, 1,
               dcc.id_surrogate, dck.id_surrogate
        FROM silver.sap_bsad b
        LEFT JOIN gold.dim_cliente_comercial dcc
               ON dcc.cliente_id = b.cliente_id
              AND b.fecha_contabilizacion >= dcc.fecha_inicio_vigencia
              AND (dcc.fecha_fin_vigencia IS NULL OR b.fecha_contabilizacion <= dcc.fecha_fin_vigencia)
        LEFT JOIN gold.dim_cliente_credito dck
               ON dck.cliente_id = b.cliente_id
              AND b.fecha_contabilizacion >= dck.fecha_inicio_vigencia
              AND (dck.fecha_fin_vigencia IS NULL OR b.fecha_contabilizacion <= dck.fecha_fin_vigencia)
        WHERE b.mandante = '400'
          AND b.debe_haber = 'S'
          AND (b.clase_documento LIKE 'F%' OR b.clase_documento = 'D1')
          AND b.fecha_compensacion >= @fecha_desde
          -- SIN tope superior, aunque venga @fecha_hasta. Ver la nota del proc.
          AND b.cliente_id IN (
                SELECT c1.cliente_id FROM gold.dim_cliente_comercial c1
                WHERE c1.estatus_comercial <> 'FUERA_DE_ALCANCE'
                  AND c1.canal_distribucion IN (10, 40, 60))
          -- Reset de compensacion (FBRA): la linea sigue en bsad como compensada pero
          -- volvio a bsid porque se deshizo la compensacion. GANA BSID, que es el estado
          -- de hoy. Sin esto la PK revienta, y peor: el modelo diria que una factura esta
          -- pagada cuando sigue abierta.
          AND NOT EXISTS (
                SELECT 1 FROM silver.sap_bsid i
                WHERE i.mandante = b.mandante AND i.sociedad = b.sociedad
                  AND i.cliente_id = b.cliente_id AND i.ejercicio = b.ejercicio
                  AND i.documento_id = b.documento_id AND i.posicion = b.posicion);
        SET @n_comp = @@ROWCOUNT;

        ---------------------------------------------------------------- ABIERTAS
        INSERT INTO gold.fact_facturas (
            sociedad, cliente_id, ejercicio, documento_id, posicion,
            documento_compensacion, ejercicio_compensacion, clase_documento,
            fecha_documento, fecha_vencimiento, fecha_contabilizacion, fecha_compensacion,
            monto, clave_contabilizacion, flag_compensada,
            cliente_comercial_sk, cliente_credito_sk
        )
        SELECT b.sociedad, b.cliente_id, b.ejercicio, b.documento_id, b.posicion,
               NULL, NULL, b.clase_documento,
               b.fecha_documento, b.fecha_vencimiento, b.fecha_contabilizacion, NULL,
               b.monto_moneda_local, b.clave_contabilizacion, 0,
               dcc.id_surrogate, dck.id_surrogate
        FROM silver.sap_bsid b
        LEFT JOIN gold.dim_cliente_comercial dcc
               ON dcc.cliente_id = b.cliente_id
              AND b.fecha_contabilizacion >= dcc.fecha_inicio_vigencia
              AND (dcc.fecha_fin_vigencia IS NULL OR b.fecha_contabilizacion <= dcc.fecha_fin_vigencia)
        LEFT JOIN gold.dim_cliente_credito dck
               ON dck.cliente_id = b.cliente_id
              AND b.fecha_contabilizacion >= dck.fecha_inicio_vigencia
              AND (dck.fecha_fin_vigencia IS NULL OR b.fecha_contabilizacion <= dck.fecha_fin_vigencia)
        WHERE b.mandante = '400'
          AND b.debe_haber = 'S'
          AND (b.clase_documento LIKE 'F%' OR b.clase_documento = 'D1')
          AND b.cliente_id IN (
                SELECT c1.cliente_id FROM gold.dim_cliente_comercial c1
                WHERE c1.estatus_comercial <> 'FUERA_DE_ALCANCE'
                  AND c1.canal_distribucion IN (10, 40, 60));
        SET @n_abie = @@ROWCOUNT;

        COMMIT TRANSACTION;

        PRINT '   Compensadas: ' + CAST(@n_comp AS VARCHAR(12))
            + ' | Abiertas: ' + CAST(@n_abie AS VARCHAR(12))
            + ' | Duracion: ' + CAST(DATEDIFF(SECOND, @t0, GETDATE()) AS VARCHAR(10)) + ' s';
    END TRY
    BEGIN CATCH
        -- Sin esto la ventana queda con el hueco del DELETE y el proc muere
        -- "limpio": el reporte del dia sale con menos dinero y nada avisa.
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        PRINT 'ERROR en gold.load_fact_facturas: ' + ERROR_MESSAGE();
        THROW;
    END CATCH;
END;
GO
PRINT 'Procedure gold.load_fact_facturas created successfully.';
GO


-- ========================================================================================
-- 3. gold.load_fact_aplicacion_pagos   (las tres reglas)
-- ========================================================================================
IF OBJECT_ID('gold.load_fact_aplicacion_pagos', 'P') IS NOT NULL
    DROP PROCEDURE gold.load_fact_aplicacion_pagos;
GO

CREATE PROCEDURE gold.load_fact_aplicacion_pagos
    @fecha_desde DATE = NULL,
    @fecha_hasta DATE = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;   -- ver "ATOMICIDAD" en la cabecera
    DECLARE @t0 DATETIME = GETDATE(), @n1 INT, @n2 INT, @n3 INT, @lote INT, @multi INT;

    IF @fecha_desde IS NULL
        SET @fecha_desde = DATEADD(MONTH, DATEDIFF(MONTH, 0, GETDATE()) - 1, 0);

    BEGIN TRY
        PRINT '>> gold.load_fact_aplicacion_pagos';

        -- Ver "ATOMICIDAD" en la cabecera. Todo lo que sigue va junto o no va.
        BEGIN TRANSACTION;

        SET @lote = 1;
        WHILE @lote > 0
        BEGIN
            DELETE TOP (50000) FROM gold.fact_aplicacion_pagos
            WHERE fecha_compensacion >= @fecha_desde
              AND (@fecha_hasta IS NULL OR fecha_compensacion < @fecha_hasta);
            SET @lote = @@ROWCOUNT;
        END

        -------------------------------------------------------- REGLA 1: GRUPO
        INSERT INTO gold.fact_aplicacion_pagos (
            sociedad, cliente_id, ejercicio_pago, pago_id, posicion_pago,
            ejercicio_factura, factura_id, posicion_factura,
            documento_compensacion, fecha_compensacion, regla)
        SELECT p.sociedad, p.cliente_id, p.ejercicio, p.documento_id, p.posicion,
               f.ejercicio, f.documento_id, f.posicion,
               p.documento_compensacion, p.fecha_compensacion, 'GRUPO'
        FROM   gold.fact_pagos p
        JOIN   gold.fact_facturas f
               ON  f.documento_compensacion = p.documento_compensacion
               AND f.ejercicio_compensacion = p.ejercicio_compensacion
        WHERE  p.fecha_compensacion >= @fecha_desde
          AND (@fecha_hasta IS NULL OR p.fecha_compensacion < @fecha_hasta);
        SET @n1 = @@ROWCOUNT;

        -------------------------------------------------------- apoyos para 2 y 3
        -- El salto, al grano (hijo, grupo_final) AGREGADO. Por linea seria incorrecto:
        -- un hijo con 3 lineas clave 15 al mismo grupo duplicaria cada factura 3 veces.
        IF OBJECT_ID('tempdb..#salto') IS NOT NULL DROP TABLE #salto;
        SELECT   h.documento_id           AS hijo,
                 h.documento_compensacion AS grupo_final,
                 h.ejercicio_compensacion AS ejercicio_final
        INTO     #salto
        FROM     silver.sap_bsad h
        WHERE    h.mandante = '400' AND h.clase_documento = 'DZ'
          AND    h.clave_contabilizacion = '15'
          AND    h.documento_compensacion IS NOT NULL
        GROUP BY h.documento_id, h.documento_compensacion, h.ejercicio_compensacion;
        CREATE UNIQUE CLUSTERED INDEX ix_salto ON #salto(hijo, grupo_final, ejercicio_final);

        -- Guarda: cuantos DOCUMENTOS DE PAGO alimentan al intermedio. Si es mas de uno,
        -- el dinero se mezclo ahi dentro y no se puede decir cual financio que linea.
        -- Cuenta claves 11 y 15, no solo virgenes: los pagos directos tambien participan
        -- del salto y "un virgen detras" no significa nada cuando no hay virgen.
        IF OBJECT_ID('tempdb..#guarda') IS NOT NULL DROP TABLE #guarda;
        SELECT   documento_compensacion AS intermedio,
                 COUNT(DISTINCT documento_id) AS n_pagos
        INTO     #guarda
        FROM     silver.sap_bsad
        WHERE    mandante = '400' AND clase_documento = 'DZ' AND debe_haber = 'H'
          AND    clave_contabilizacion IN ('11','15')
          AND    documento_compensacion IS NOT NULL
        GROUP BY documento_compensacion;
        CREATE UNIQUE CLUSTERED INDEX ix_guarda ON #guarda(intermedio);

        -------------------------------------------------------- REGLA 2: SEGUNDO_SALTO
        INSERT INTO gold.fact_aplicacion_pagos (
            sociedad, cliente_id, ejercicio_pago, pago_id, posicion_pago,
            ejercicio_factura, factura_id, posicion_factura,
            documento_compensacion, fecha_compensacion, regla)
        SELECT p.sociedad, p.cliente_id, p.ejercicio, p.documento_id, p.posicion,
               f.ejercicio, f.documento_id, f.posicion,
               s.grupo_final,          -- donde esta la factura, no el grupo del pago
               p.fecha_compensacion, 'SEGUNDO_SALTO'
        FROM   gold.fact_pagos p
        JOIN   #salto s            ON s.hijo = p.documento_compensacion
        JOIN   gold.fact_facturas f ON f.documento_compensacion = s.grupo_final
                                   AND f.ejercicio_compensacion = s.ejercicio_final
        -- LEFT JOIN, nunca INNER: la guarda es un dato de control, no un filtro. Con
        -- INNER tiraba en silencio los pagos que no son virgenes y por tanto no estan
        -- en #guarda (109 pagos legitimos en julio 2026).
        LEFT JOIN #guarda g        ON g.intermedio = p.documento_compensacion
        WHERE  p.fecha_compensacion >= @fecha_desde
          AND (@fecha_hasta IS NULL OR p.fecha_compensacion < @fecha_hasta)
          -- Las lineas clave 08 quedan fuera POR DECISION, no por accidente de un join:
          -- son debitos espejo y atribuirles facturas no significa nada.
          AND  p.clave_contabilizacion IN ('11','15')
          AND  ISNULL(g.n_pagos, 1) = 1
          -- Solo donde GRUPO no encontro nada. Esto las hace excluyentes.
          AND  NOT EXISTS (SELECT 1 FROM gold.fact_facturas ff
                           WHERE ff.documento_compensacion = p.documento_compensacion
                             AND ff.ejercicio_compensacion = p.ejercicio_compensacion);
        SET @n2 = @@ROWCOUNT;

        -------------------------------------------------------- REGLA 3: REFERENCIA
        -- La unica que aterriza en facturas ABIERTAS. El deposito virgen NUNCA trae
        -- REBZG (todos 'V'); la referencia vive en la linea clave 15 ABIERTA del hijo.
        INSERT INTO gold.fact_aplicacion_pagos (
            sociedad, cliente_id, ejercicio_pago, pago_id, posicion_pago,
            ejercicio_factura, factura_id, posicion_factura,
            documento_compensacion, fecha_compensacion, regla)
        SELECT p.sociedad, p.cliente_id, p.ejercicio, p.documento_id, p.posicion,
               f.ejercicio, f.documento_id, f.posicion,
               p.documento_compensacion,   -- la factura abierta no tiene grupo propio
               p.fecha_compensacion, 'REFERENCIA'
        FROM   gold.fact_pagos p
        JOIN   silver.sap_bsid a
               ON  a.documento_id          = p.documento_compensacion
               AND a.mandante              = '400'
               AND a.clase_documento       = 'DZ'
               AND a.clave_contabilizacion = '15'
               AND a.factura_referencia_documento IS NOT NULL
               AND a.factura_referencia_documento <> 'V'
        JOIN   gold.fact_facturas f
               ON  f.documento_id = a.factura_referencia_documento
               AND f.ejercicio    = a.factura_referencia_ejercicio
               -- SOLO facturas ABIERTAS. Sin esto entran lineas donde el pago sigue
               -- abierto pero la factura ya se liquido por otro lado: eso no es un pago
               -- parcial, y atribuirsela diria que este pago la liquido.
               AND f.flag_compensada = 0
        LEFT JOIN #guarda g ON g.intermedio = p.documento_compensacion
        WHERE  p.fecha_compensacion >= @fecha_desde
          AND (@fecha_hasta IS NULL OR p.fecha_compensacion < @fecha_hasta)
          AND  p.clave_contabilizacion IN ('11','15')
          AND  ISNULL(g.n_pagos, 1) = 1;
        SET @n3 = @@ROWCOUNT;

        COMMIT TRANSACTION;

        -- INVARIANTE: pagos que la guarda dejo REALMENTE fuera - los que habrian entrado
        -- por el segundo salto y no entraron por ambiguedad.
        -- Una version anterior contaba todos los pagos con intermedio multi-pago SIN
        -- excluir los que ya entraron por GRUPO: daba 1,893 en agosto 2026 cuando el
        -- numero real es otro. Una invariante que grita de mas se aprende a ignorar, y
        -- el dia que signifique algo nadie la ve.
        SELECT @multi = COUNT(DISTINCT p.documento_id)
        FROM   gold.fact_pagos p
        JOIN   #guarda g ON g.intermedio = p.documento_compensacion
        JOIN   #salto  s ON s.hijo       = p.documento_compensacion
        WHERE  g.n_pagos > 1
          AND  p.fecha_compensacion >= @fecha_desde
          AND (@fecha_hasta IS NULL OR p.fecha_compensacion < @fecha_hasta)
          AND  p.clave_contabilizacion IN ('11','15')
          -- solo los que NO entraron por GRUPO: esos son los que de verdad se pierden
          AND  NOT EXISTS (SELECT 1 FROM gold.fact_facturas ff
                           WHERE ff.documento_compensacion = p.documento_compensacion
                             AND ff.ejercicio_compensacion = p.ejercicio_compensacion);

        PRINT '   GRUPO: ' + CAST(@n1 AS VARCHAR(12))
            + ' | SEGUNDO_SALTO: ' + CAST(@n2 AS VARCHAR(12))
            + ' | REFERENCIA: ' + CAST(@n3 AS VARCHAR(12));
        PRINT '   Intermedios multi-pago excluidos por la guarda: ' + CAST(@multi AS VARCHAR(12));
        PRINT '   Duracion: ' + CAST(DATEDIFF(SECOND, @t0, GETDATE()) AS VARCHAR(10)) + ' s';
    END TRY
    BEGIN CATCH
        -- Sin esto la ventana queda con el hueco del DELETE y el proc muere
        -- "limpio": el reporte del dia sale con menos dinero y nada avisa.
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        PRINT 'ERROR en gold.load_fact_aplicacion_pagos: ' + ERROR_MESSAGE();
        THROW;
    END CATCH;
END;
GO
PRINT 'Procedure gold.load_fact_aplicacion_pagos created successfully.';
GO


-- ========================================================================================
-- 4. gold.load_fact_pagos_sin_aplicacion
-- ========================================================================================
IF OBJECT_ID('gold.load_fact_pagos_sin_aplicacion', 'P') IS NOT NULL
    DROP PROCEDURE gold.load_fact_pagos_sin_aplicacion;
GO

CREATE PROCEDURE gold.load_fact_pagos_sin_aplicacion
    @fecha_desde DATE = NULL,
    @fecha_hasta DATE = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;   -- ver "ATOMICIDAD" en la cabecera
    DECLARE @t0 DATETIME = GETDATE(), @n INT, @lote INT, @revisar INT, @huerfanos INT;

    IF @fecha_desde IS NULL
        SET @fecha_desde = DATEADD(MONTH, DATEDIFF(MONTH, 0, GETDATE()) - 1, 0);

    BEGIN TRY
        PRINT '>> gold.load_fact_pagos_sin_aplicacion';

        -- Ver "ATOMICIDAD" en la cabecera. Todo lo que sigue va junto o no va.
        BEGIN TRANSACTION;

        SET @lote = 1;
        WHILE @lote > 0
        BEGIN
            DELETE TOP (50000) FROM gold.fact_pagos_sin_aplicacion
            WHERE fecha_compensacion >= @fecha_desde
              AND (@fecha_hasta IS NULL OR fecha_compensacion < @fecha_hasta);
            SET @lote = @@ROWCOUNT;
        END

        IF OBJECT_ID('tempdb..#salto2') IS NOT NULL DROP TABLE #salto2;
        SELECT DISTINCT h.documento_id AS hijo, h.documento_compensacion AS grupo_final,
               h.ejercicio_compensacion AS ejercicio_final
        INTO   #salto2
        FROM   silver.sap_bsad h
        WHERE  h.mandante = '400' AND h.clase_documento = 'DZ'
          AND  h.clave_contabilizacion = '15'
          AND  h.documento_compensacion IS NOT NULL;
        CREATE UNIQUE CLUSTERED INDEX ix_s2 ON #salto2(hijo, grupo_final, ejercicio_final);

        -- Misma guarda que usa el puente: cuantos documentos de pago alimentan al
        -- intermedio. Se necesita aqui para poder ETIQUETAR lo que el puente excluyo.
        IF OBJECT_ID('tempdb..#guarda2') IS NOT NULL DROP TABLE #guarda2;
        SELECT   documento_compensacion AS intermedio,
                 COUNT(DISTINCT documento_id) AS n_pagos
        INTO     #guarda2
        FROM     silver.sap_bsad
        WHERE    mandante = '400' AND clase_documento = 'DZ' AND debe_haber = 'H'
          AND    clave_contabilizacion IN ('11','15')
          AND    documento_compensacion IS NOT NULL
        GROUP BY documento_compensacion;
        CREATE UNIQUE CLUSTERED INDEX ix_g2 ON #guarda2(intermedio);

        INSERT INTO gold.fact_pagos_sin_aplicacion (
            sociedad, cliente_id, ejercicio, documento_id, posicion,
            documento_compensacion, fecha_compensacion, motivo)
        SELECT x.sociedad, x.cliente_id, x.ejercicio, x.documento_id, x.posicion,
               x.documento_compensacion, x.fecha_compensacion,
               -- EL ORDEN DE ESTAS RAMAS ES LA DEFINICION DE CADA ETIQUETA.
               -- CADENA_AMBIGUA va AL FINAL, no antes de las del salto: solo aplica
               -- cuando el salto SI llegaba a facturas y la guarda lo excluyo. Un pago
               -- sin salto es SIN_APLICACION aunque su intermedio sea multi-pago - ahi
               -- la ambiguedad no es la razon por la que no se ligo.
               -- (2026-09-07: se puso segunda por error y CADENA_AMBIGUA paso de 62 a
               --  3,025 pagos. Las invariantes NO lo detectaron: verifican que todo este
               --  clasificado, no que este bien clasificado.)
               CASE WHEN x.clave_contabilizacion NOT IN ('11','15') THEN 'LINEA_TECNICA'
                    WHEN x.tiene_salto      = 0        THEN 'SIN_APLICACION'
                    WHEN x.salto_a_facturas = 0        THEN 'LIQUIDA_NO_FACTURA'
                    WHEN x.n_pagos_intermedio > 1      THEN 'CADENA_AMBIGUA'
                    -- Rama final a proposito: un ELSE que dice 'OTRO' y se olvida es la
                    -- forma habitual de esconder casos nuevos. Debe dar 0.
                    ELSE 'REVISAR' END
        FROM (
            SELECT p.sociedad, p.cliente_id, p.ejercicio, p.documento_id, p.posicion,
                   p.documento_compensacion, p.fecha_compensacion, p.clave_contabilizacion,
                   MAX(CASE WHEN s.grupo_final IS NOT NULL THEN 1 ELSE 0 END) AS tiene_salto,
                   MAX(CASE WHEN f.documento_compensacion IS NOT NULL THEN 1 ELSE 0 END) AS salto_a_facturas,
                   MAX(ISNULL(g.n_pagos, 1)) AS n_pagos_intermedio
            FROM   gold.fact_pagos p
            LEFT JOIN #guarda2 g ON g.intermedio = p.documento_compensacion
            -- LEFT JOIN: el pago debe sobrevivir aunque no tenga salto - justamente eso
            -- es lo que lo clasifica como SIN_APLICACION.
            LEFT JOIN #salto2 s ON s.hijo = p.documento_compensacion
            LEFT JOIN (SELECT DISTINCT documento_compensacion, ejercicio_compensacion
                       FROM gold.fact_facturas WHERE documento_compensacion IS NOT NULL) f
                   ON f.documento_compensacion = s.grupo_final
                  AND f.ejercicio_compensacion = s.ejercicio_final
            WHERE  p.fecha_compensacion >= @fecha_desde
              AND (@fecha_hasta IS NULL OR p.fecha_compensacion < @fecha_hasta)
              AND  NOT EXISTS (SELECT 1 FROM gold.fact_aplicacion_pagos a
                               WHERE a.sociedad       = p.sociedad
                                 AND a.ejercicio_pago = p.ejercicio
                                 AND a.pago_id        = p.documento_id
                                 AND a.posicion_pago  = p.posicion)
            GROUP BY p.sociedad, p.cliente_id, p.ejercicio, p.documento_id, p.posicion,
                     p.documento_compensacion, p.fecha_compensacion, p.clave_contabilizacion
        ) x;
        SET @n = @@ROWCOUNT;

        COMMIT TRANSACTION;

        -- Las invariantes van FUERA de la transaccion, a proposito: solo leen, y si algo
        -- salio mal se quiere ver el estado ya confirmado, no el de adentro.
        SELECT @revisar = COUNT(*) FROM gold.fact_pagos_sin_aplicacion
        WHERE motivo = 'REVISAR'
          AND fecha_compensacion >= @fecha_desde
          AND (@fecha_hasta IS NULL OR fecha_compensacion < @fecha_hasta);

        -- INVARIANTE DEL MODELO: todo pago esta en el puente O aqui, nunca en ninguno.
        SELECT @huerfanos = COUNT(*)
        FROM   gold.fact_pagos p
        WHERE  p.fecha_compensacion >= @fecha_desde
          AND (@fecha_hasta IS NULL OR p.fecha_compensacion < @fecha_hasta)
          AND  NOT EXISTS (SELECT 1 FROM gold.fact_aplicacion_pagos a
                           WHERE a.sociedad=p.sociedad AND a.ejercicio_pago=p.ejercicio
                             AND a.pago_id=p.documento_id AND a.posicion_pago=p.posicion)
          AND  NOT EXISTS (SELECT 1 FROM gold.fact_pagos_sin_aplicacion s
                           WHERE s.sociedad=p.sociedad AND s.ejercicio=p.ejercicio
                             AND s.documento_id=p.documento_id AND s.posicion=p.posicion);

        PRINT '   Filas: ' + CAST(@n AS VARCHAR(12))
            + ' | Duracion: ' + CAST(DATEDIFF(SECOND, @t0, GETDATE()) AS VARCHAR(10)) + ' s';
        PRINT '   INVARIANTES (las dos deben ser 0) -> etiqueta REVISAR: ' + CAST(@revisar AS VARCHAR(12))
            + ' | pagos sin clasificar: ' + CAST(@huerfanos AS VARCHAR(12));
    END TRY
    BEGIN CATCH
        -- Sin esto la ventana queda con el hueco del DELETE y el proc muere
        -- "limpio": el reporte del dia sale con menos dinero y nada avisa.
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        PRINT 'ERROR en gold.load_fact_pagos_sin_aplicacion: ' + ERROR_MESSAGE();
        THROW;
    END CATCH;
END;
GO
PRINT 'Procedure gold.load_fact_pagos_sin_aplicacion created successfully.';
GO
