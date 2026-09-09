/* =====================================================================================
   gold.load_presupuesto_cobranza
   dwh_architecture/04_pronostico/sp_load_presupuesto.sql            (2026-09-09)
   =====================================================================================

   Calcula el presupuesto de cobranza de un mes y lo deja en
   gold.fact_presupuesto_cobranza (diario) y gold.fact_presupuesto_cartera (segmento).
   El modelo y su validacion estan en modelo_presupuesto.sql; aqui solo se ejecuta.

   NO VA DENTRO DE gold.load_gold - Y ES DELIBERADO
   ------------------------------------------------
   load_gold corre todos los dias. Este proc NO. El presupuesto se fija EL DIA DEL CORTE
   y a partir de ahi es un compromiso: si se recalculara cada noche, el numero se
   perseguiria a si mismo hacia la realidad y para el dia 30 siempre habria "acertado".
   Un pronostico que se reescribe no es un pronostico.
   Se corre UNA VEZ al mes, el 4o dia habil, DESPUES de gold.load_dim_presupuesto.

   LAS REGLAS DE ALCANCE DEL PROYECTO, QUE AQUI TAMBIEN APLICAN
   ------------------------------------------------------------
   Se resuelven A LA FECHA DEL CORTE contra la SCD2, no con la vigencia de hoy:

     1. canal_distribucion IN (10, 40, 60)   -- mayoreo; el alcance de este reporte
     2. estatus_comercial <> 'FUERA_DE_ALCANCE'

   La regla 2 NO es redundante con el filtro que ya trae gold.fact_facturas. Ese filtro
   es `cliente_id IN (SELECT ... WHERE estatus <> 'FUERA_DE_ALCANCE')`, que se cumple si
   el cliente estuvo en alcance en CUALQUIER version de su historia SCD2. Un cliente que
   salio de alcance sigue teniendo sus facturas en el hecho.
   Caso real: un cliente que entra por `cliente_id LIKE '9%'` en
   vw_cliente_canal_estatus - o sea, no es cliente real - aun asi aportaba $14.2M de
   cartera al corte de septiembre. No movia el TOTAL, porque cae 100% en el bucket G y ese vale
   0%, pero inflaba la cartera reportada: de los $17.7M de papel muerto, $14.2M eran el.
   Con la regla aplicada, el papel muerto real son $3.5M.

   La regla del RFC vive DENTRO de estatus_comercial: sin RFC, o con los genericos
   XAXX010101000 / XEXX010101000, un cliente no llega a ACTIVO y cae en REVISAR.
   REVISAR e INACTIVO SI entran al presupuesto - solo FUERA_DE_ALCANCE queda afuera -
   igual que en el resto del modelo. Ver gold.vw_cliente_canal_estatus en ddl_gold.sql,
   que es la definicion canonica y la unica que debe editarse si las reglas cambian.

   PARAMETROS
   ----------
   @mes          dia 1 del mes a presupuestar. NULL = mes en curso.
   @fecha_corte  dia del calculo. NULL = 4o dia habil de @mes.
   @forzar       0 (default) protege un presupuesto ya emitido: si ya existe uno para
                 @mes con OTRA fecha de corte, el proc se niega. Rehacerlo en silencio
                 borraria el numero contra el que se esta midiendo el equipo.
                 Volver a correr con el MISMO corte si se permite.

   CALIBRACION
   -----------
   Ventana movil de 24 meses cerrados antes de @mes. El modelo se mantiene solo y no hay
   tabla de parametros que se quede vieja. Se probo que el resultado no depende de la
   ventana (2024, 2025 o ambos: 3.53 / 3.51 / 3.53 % de error), asi que moverla no
   introduce inestabilidad.

   TASAS POR BUCKET x TIPO_GESTION, NO SOLO POR BUCKET
   ---------------------------------------------------
   Medido sobre 24 meses, la antiguedad no explica todo - el tipo de gestion tambien:

       bucket            gestionable   juridico   extrajudicial
       vence este mes       71.5%        37.8%       39.3%
       vence despues        15.5%         1.6%        1.7%
       vencida 1-30         67.7%        41.1%       47.8%

   Juridico y extrajudicial pagan a la MITAD en el bucket grande y a una DECIMA PARTE
   en anticipos. Con una tasa global se les acreditaria el doble de lo que entregan, y
   el sesgo seria invisible porque el total del mes casi no se mueve (son ~$5.7M de
   $222M). Importa para el numero POR SEGMENTO, que es justo para lo que existe la
   tabla de cartera.

   Cuando una celda (bucket, tipo_gestion) tiene menos de @min_hist facturas de
   historia, se cae a la tasa general del bucket y se marca tasa_origen = 'BUCKET'.
   Una tasa de respaldo tiene que ser distinguible de una medida.
   ===================================================================================== */

IF OBJECT_ID('gold.load_presupuesto_cobranza') IS NOT NULL
    DROP PROCEDURE gold.load_presupuesto_cobranza;
GO

CREATE PROCEDURE gold.load_presupuesto_cobranza
    @mes         DATE = NULL,
    @fecha_corte DATE = NULL,
    @forzar      BIT  = 0
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @t0 DATETIME = GETDATE();
    DECLARE @min_hist INT = 500;   -- facturas minimas para creerle a una celda segmentada

    ------------------------------------------------------------------ parametros
    IF @mes IS NULL
        SET @mes = DATEADD(MONTH, DATEDIFF(MONTH, 0, GETDATE()), 0);
    SET @mes = DATEFROMPARTS(YEAR(@mes), MONTH(@mes), 1);

    DECLARE @fin DATE = EOMONTH(@mes);

    IF @fecha_corte IS NULL
        SET @fecha_corte = (SELECT MIN(fecha) FROM gold.dim_fecha
                            WHERE fecha >= @mes AND fecha <= @fin AND dia_habil_del_mes = 4);

    DECLARE @msg VARCHAR(400);

    IF @fecha_corte IS NULL
    BEGIN
        SET @msg = 'No se pudo resolver el 4o dia habil de ' + CONVERT(VARCHAR(10), @mes, 120)
                 + '. Revisar que gold.dim_fecha cubra el mes y traiga dia_habil_del_mes.';
        THROW 50001, @msg, 1;
    END

    IF @fecha_corte < @mes OR @fecha_corte > @fin
    BEGIN
        SET @msg = 'La fecha de corte ' + CONVERT(VARCHAR(10), @fecha_corte, 120)
                 + ' cae fuera del mes ' + CONVERT(VARCHAR(10), @mes, 120) + '.';
        THROW 50002, @msg, 1;
    END

    /* Las dimensiones se refrescan AQUI en vez de exigir que alguien las corra antes.
       Un orden obligatorio entre dos procs es una trampa: el dia que se olvide, el
       presupuesto sale con un ejecutivo nuevo sin clasificar y nadie lo nota.
       load_dim_presupuesto solo inserta lo que falta, asi que llamarlo de mas no
       cuesta ni pisa la clasificacion manual. */
    IF OBJECT_ID('gold.load_dim_presupuesto') IS NOT NULL
        EXEC gold.load_dim_presupuesto;

    IF NOT EXISTS (SELECT 1 FROM gold.dim_ejecutivo)
    BEGIN
        SET @msg = 'gold.dim_ejecutivo esta vacia y no se pudo poblar. Revisar que exista'
                 + ' gold.load_dim_presupuesto (03_gold/ddl_dim_presupuesto.sql): sin'
                 + ' tipo_gestion las tasas no se pueden segmentar.';
        THROW 50004, @msg, 1;
    END

    /* Proteccion del numero ya emitido. Ver @forzar en la cabecera. */
    DECLARE @corte_previo DATE =
        (SELECT TOP 1 fecha_corte FROM gold.fact_presupuesto_cobranza WHERE mes_presupuesto = @mes);

    IF @corte_previo IS NOT NULL AND @corte_previo <> @fecha_corte AND @forzar = 0
    BEGIN
        SET @msg = 'Ya hay presupuesto de ' + CONVERT(VARCHAR(10), @mes, 120)
                 + ' con corte ' + CONVERT(VARCHAR(10), @corte_previo, 120)
                 + ' y se esta pidiendo con corte ' + CONVERT(VARCHAR(10), @fecha_corte, 120)
                 + '. Ese numero puede ser contra el que se mide el equipo. Si de verdad'
                 + ' se quiere reemplazar, correr con @forzar = 1.';
        THROW 50003, @msg, 1;
    END

    IF @fecha_corte > CAST(GETDATE() AS DATE)
        PRINT '   AVISO: la fecha de corte es futura. T2 (cobrado antes del corte) va incompleto.';

    DECLARE @cal_ini DATE = DATEADD(MONTH, -24, @mes);

    BEGIN TRY
        PRINT '>> gold.load_presupuesto_cobranza | mes ' + CONVERT(VARCHAR(10), @mes, 120)
            + ' | corte ' + CONVERT(VARCHAR(10), @fecha_corte, 120)
            + ' | calibra desde ' + CONVERT(VARCHAR(10), @cal_ini, 120);

        /* ---------------------------------------- 1. meses de calibracion + su corte */
        IF OBJECT_ID('tempdb..#cal') IS NOT NULL DROP TABLE #cal;
        SELECT DATEFROMPARTS(anio, mes, 1) AS ini,
               EOMONTH(DATEFROMPARTS(anio, mes, 1)) AS fin,
               MIN(CASE WHEN dia_habil_del_mes = 4 THEN fecha END) AS corte
        INTO   #cal
        FROM   gold.dim_fecha
        WHERE  fecha >= @cal_ini AND fecha < @mes
        GROUP BY anio, mes
        OPTION (RECOMPILE);

        /* CAJA, UNA SOLA VEZ Y UNA SOLA DEFINICION.
           gold.vw_cobranza_diaria trae la regla de alcance adentro. Se materializa
           aqui porque se usa en cuatro lugares -T2, el factor T3, el perfil de
           calendario y los dias observados- y en cada uno se pagaria el join SCD2
           sobre 614 mil pagos. Peor que el costo: cuatro agregaciones sueltas de
           fact_pagos se desincronizan en cuanto alguien toca una sola. */
        IF OBJECT_ID('tempdb..#caja') IS NOT NULL DROP TABLE #caja;
        SELECT c.fecha, c.monto_real AS monto
        INTO   #caja
        FROM   gold.vw_cobranza_diaria c
        WHERE  c.fecha >= @cal_ini AND c.fecha <= @fin
        OPTION (RECOMPILE);
        CREATE UNIQUE CLUSTERED INDEX ix_caja ON #caja(fecha);

        /* ------------------------------- 2. cartera historica al corte, con su tipo
           Mismas reglas de alcance que el mes objetivo: si se entrenara sobre una
           poblacion distinta a la que se predice, las tasas no aplicarian. */
        IF OBJECT_ID('tempdb..#hist') IS NOT NULL DROP TABLE #hist;
        SELECT c.ini, f.monto, e.tipo_gestion,
               CASE
                 WHEN DATEDIFF(DAY, f.fecha_vencimiento, c.corte) <  0
                      AND f.fecha_vencimiento <= c.fin                  THEN 'A1'
                 WHEN DATEDIFF(DAY, f.fecha_vencimiento, c.corte) <  0   THEN 'A2'
                 WHEN DATEDIFF(DAY, f.fecha_vencimiento, c.corte) <=  30 THEN 'B'
                 WHEN DATEDIFF(DAY, f.fecha_vencimiento, c.corte) <=  60 THEN 'C'
                 WHEN DATEDIFF(DAY, f.fecha_vencimiento, c.corte) <=  90 THEN 'D'
                 WHEN DATEDIFF(DAY, f.fecha_vencimiento, c.corte) <= 180 THEN 'E'
                 WHEN DATEDIFF(DAY, f.fecha_vencimiento, c.corte) <= 365 THEN 'F'
                 ELSE 'G'
               END AS bucket,
               CASE WHEN f.fecha_pago_efectiva BETWEEN c.corte AND c.fin
                    THEN f.monto ELSE 0 END AS cobrado
        INTO   #hist
        FROM   #cal c
        JOIN   gold.fact_facturas f
               ON  f.fecha_documento < c.ini
               AND (f.fecha_compensacion IS NULL OR f.fecha_compensacion >= c.corte)
               AND f.fecha_vencimiento IS NOT NULL
        JOIN   gold.dim_cliente_comercial d
               ON  d.cliente_id = f.cliente_id
               AND c.corte >= d.fecha_inicio_vigencia
               AND (d.fecha_fin_vigencia IS NULL OR c.corte <= d.fecha_fin_vigencia)
               AND d.canal_distribucion IN (10, 40, 60)
               AND d.estatus_comercial <> 'FUERA_DE_ALCANCE'
        LEFT JOIN gold.dim_cliente_credito k
               ON  k.cliente_id = f.cliente_id
               AND c.corte >= k.fecha_inicio_vigencia
               AND (k.fecha_fin_vigencia IS NULL OR c.corte <= k.fecha_fin_vigencia)
        JOIN   gold.dim_ejecutivo e
               ON  e.ejecutivo_key =
                   UPPER(ISNULL(NULLIF(LTRIM(RTRIM(k.analista_credito_nombre)),''),'(SIN ASIGNAR)'))
        OPTION (RECOMPILE);

        /* ---------------------------- 3. tasas: segmentada, general, y la elegida
           Ponderadas por monto: lo que se predice es dinero, y un mes chico no debe
           pesar igual que uno grande. */
        IF OBJECT_ID('tempdb..#t_seg') IS NOT NULL DROP TABLE #t_seg;
        SELECT bucket, tipo_gestion, COUNT(*) AS n,
               SUM(cobrado) / NULLIF(SUM(monto), 0) AS tasa
        INTO   #t_seg FROM #hist GROUP BY bucket, tipo_gestion;

        IF OBJECT_ID('tempdb..#t_bk') IS NOT NULL DROP TABLE #t_bk;
        SELECT bucket, SUM(cobrado) / NULLIF(SUM(monto), 0) AS tasa
        INTO   #t_bk FROM #hist GROUP BY bucket;

        /* CROSS JOIN para que NINGUNA combinacion se quede sin tasa: si un tipo de
           gestion no tuvo cartera en un bucket durante la calibracion pero si la tiene
           hoy, sin esto su renglon se perderia en el JOIN y el total saldria corto. */
        IF OBJECT_ID('tempdb..#tasa') IS NOT NULL DROP TABLE #tasa;
        SELECT b.bucket, g.tipo_gestion,
               CASE WHEN s.n >= @min_hist THEN s.tasa ELSE b.tasa END AS tasa,
               CASE WHEN s.n >= @min_hist THEN 'SEGMENTO' ELSE 'BUCKET' END AS tasa_origen
        INTO   #tasa
        FROM   #t_bk b
        CROSS JOIN (SELECT DISTINCT tipo_gestion FROM gold.dim_ejecutivo) g
        LEFT JOIN  #t_seg s ON s.bucket = b.bucket AND s.tipo_gestion = g.tipo_gestion;

        /* -------------------------------------------- 4. factor T3, misma ventana */
        IF OBJECT_ID('tempdb..#hm') IS NOT NULL DROP TABLE #hm;
        SELECT c.ini, t1.v AS t1, t2.v AS t2, caja.v AS real_caja
        INTO   #hm
        FROM   #cal c
        CROSS APPLY (SELECT SUM(h.monto * t.tasa) v FROM #hist h
                     JOIN #tasa t ON t.bucket = h.bucket AND t.tipo_gestion = h.tipo_gestion
                     WHERE h.ini = c.ini) t1
        CROSS APPLY (SELECT SUM(k.monto) v FROM #caja k
                     WHERE k.fecha >= c.ini AND k.fecha < c.corte) t2
        CROSS APPLY (SELECT SUM(k.monto) v FROM #caja k
                     WHERE k.fecha >= c.ini AND k.fecha <= c.fin) caja
        OPTION (RECOMPILE);

        DECLARE @k DECIMAL(12,6) = (SELECT SUM(real_caja - t1 - t2) / NULLIF(SUM(t1), 0) FROM #hm);

        /* ------------------------------------------------- 5. slots de calendario
           El slot se calcula UNA sola vez, para la calibracion y para el mes objetivo.
           Tenerlo en un solo lugar no es estetica: si la expresion que ESTIMA el perfil
           y la que lo APLICA llegaran a separarse, el reparto diario se desalinearia en
           silencio y el total seguiria cuadrando.

           El dia de la semana sale de DATEDIFF contra un lunes conocido (1900-01-01) y
           NO de DATEPART(WEEKDAY), que depende de SET DATEFIRST y cambiaria de
           significado segun la sesion que corra el proc. */
        IF OBJECT_ID('tempdb..#slot') IS NOT NULL DROP TABLE #slot;
        SELECT d.fecha, d.es_dia_habil,
               CASE
                 WHEN d.es_dia_habil = 0 THEN NULL
                 WHEN d.dia_habil_del_mes <= 3
                      THEN 'I' + RIGHT('0' + CAST(d.dia_habil_del_mes AS VARCHAR(2)), 2)
                 WHEN d.dias_habiles_mes - d.dia_habil_del_mes + 1 <= 8
                      THEN 'F' + RIGHT('0' + CAST(d.dias_habiles_mes - d.dia_habil_del_mes + 1 AS VARCHAR(2)), 2)
                 ELSE 'M' + CASE DATEDIFF(DAY, '19000101', d.fecha) % 7
                              WHEN 0 THEN 'LU' WHEN 1 THEN 'MA' WHEN 2 THEN 'MI'
                              WHEN 3 THEN 'JU' WHEN 4 THEN 'VI' ELSE 'XX' END
               END AS slot
        INTO   #slot
        FROM   gold.dim_fecha d
        WHERE  d.fecha >= @cal_ini AND d.fecha <= @fin;
        CREATE UNIQUE CLUSTERED INDEX ix_slot ON #slot(fecha);

        /* -------------- 6. perfil: share de cada dia dentro de la caja habil de SU mes */
        IF OBJECT_ID('tempdb..#perfil') IS NOT NULL DROP TABLE #perfil;
        SELECT s.slot, AVG(ISNULL(dia.v, 0) / NULLIF(mesc.v, 0)) AS peso
        INTO   #perfil
        FROM   #cal c
        JOIN   #slot s ON s.fecha >= c.ini AND s.fecha <= c.fin AND s.es_dia_habil = 1
        OUTER APPLY (SELECT k.monto v FROM #caja k WHERE k.fecha = s.fecha) dia
        CROSS APPLY (SELECT SUM(k.monto) v FROM #caja k
                     JOIN gold.dim_fecha d2 ON d2.fecha = k.fecha AND d2.es_dia_habil = 1
                     WHERE k.fecha >= c.ini AND k.fecha <= c.fin) mesc
        GROUP BY s.slot;

        /* ---------------- 7. cartera de HOY al corte, ya a grano de SEGMENTO
           Los atributos se resuelven AL CORTE y se guardan resueltos. Ver la nota de
           grano en ddl_presupuesto.sql. */
        IF OBJECT_ID('tempdb..#hoy') IS NOT NULL DROP TABLE #hoy;
        SELECT bk.bucket, bk.ejecutivo_key, bk.tipo_gestion,
               bk.region_key, bk.canal_key, bk.estatus_comercial,
               SUM(bk.monto) AS monto_cartera
        INTO   #hoy
        FROM (
            SELECT f.monto,
                   e.ejecutivo_key, e.tipo_gestion,
                   UPPER(ISNULL(NULLIF(LTRIM(RTRIM(d.region)),''),'(SIN REGION)')) AS region_key,
                   LTRIM(RTRIM(d.canal_distribucion))                              AS canal_key,
                   d.estatus_comercial,
                   CASE
                     WHEN DATEDIFF(DAY, f.fecha_vencimiento, @fecha_corte) <  0
                          AND f.fecha_vencimiento <= @fin                        THEN 'A1'
                     WHEN DATEDIFF(DAY, f.fecha_vencimiento, @fecha_corte) <  0   THEN 'A2'
                     WHEN DATEDIFF(DAY, f.fecha_vencimiento, @fecha_corte) <=  30 THEN 'B'
                     WHEN DATEDIFF(DAY, f.fecha_vencimiento, @fecha_corte) <=  60 THEN 'C'
                     WHEN DATEDIFF(DAY, f.fecha_vencimiento, @fecha_corte) <=  90 THEN 'D'
                     WHEN DATEDIFF(DAY, f.fecha_vencimiento, @fecha_corte) <= 180 THEN 'E'
                     WHEN DATEDIFF(DAY, f.fecha_vencimiento, @fecha_corte) <= 365 THEN 'F'
                     ELSE 'G'
                   END AS bucket
            FROM   gold.fact_facturas f
            JOIN   gold.dim_cliente_comercial d
                   ON  d.cliente_id = f.cliente_id
                   AND @fecha_corte >= d.fecha_inicio_vigencia
                   AND (d.fecha_fin_vigencia IS NULL OR @fecha_corte <= d.fecha_fin_vigencia)
                   AND d.canal_distribucion IN (10, 40, 60)
                   AND d.estatus_comercial <> 'FUERA_DE_ALCANCE'
            LEFT JOIN gold.dim_cliente_credito k
                   ON  k.cliente_id = f.cliente_id
                   AND @fecha_corte >= k.fecha_inicio_vigencia
                   AND (k.fecha_fin_vigencia IS NULL OR @fecha_corte <= k.fecha_fin_vigencia)
            JOIN   gold.dim_ejecutivo e
                   ON  e.ejecutivo_key =
                       UPPER(ISNULL(NULLIF(LTRIM(RTRIM(k.analista_credito_nombre)),''),'(SIN ASIGNAR)'))
            WHERE  f.fecha_documento < @mes
              AND (f.fecha_compensacion IS NULL OR f.fecha_compensacion >= @fecha_corte)
              AND  f.fecha_vencimiento IS NOT NULL
        ) bk
        GROUP BY bk.bucket, bk.ejecutivo_key, bk.tipo_gestion,
                 bk.region_key, bk.canal_key, bk.estatus_comercial
        OPTION (RECOMPILE);

        ------------------------------------------------------------ los tres terminos
        DECLARE @T1 DECIMAL(19,2) =
            (SELECT SUM(h.monto_cartera * t.tasa) FROM #hoy h
             JOIN #tasa t ON t.bucket = h.bucket AND t.tipo_gestion = h.tipo_gestion);
        DECLARE @T2 DECIMAL(19,2) =
            (SELECT ISNULL(SUM(monto), 0) FROM #caja
             WHERE fecha >= @mes AND fecha < @fecha_corte);
        DECLARE @T3 DECIMAL(19,2) = @T1 * @k;

        /* Peso renormalizado SOLO sobre los dias habiles del corte en adelante: los
           anteriores ya no se pronostican, asi que su peso no debe repartirse. */
        DECLARE @peso_restante DECIMAL(19,10) =
            (SELECT SUM(p.peso) FROM #slot s JOIN #perfil p ON p.slot = s.slot
             WHERE s.fecha >= @fecha_corte AND s.fecha <= @fin AND s.es_dia_habil = 1);

        ------------------------------------------------------------------- escritura
        BEGIN TRANSACTION;

        DELETE FROM gold.fact_presupuesto_cobranza WHERE mes_presupuesto = @mes;
        DELETE FROM gold.fact_presupuesto_cartera  WHERE mes_presupuesto = @mes;

        INSERT INTO gold.fact_presupuesto_cartera
            (mes_presupuesto, fecha_corte, bucket_key, ejecutivo_key, region_key, canal_key,
             estatus_comercial, monto_cartera, tasa_recuperacion, tasa_origen, monto_esperado, monto_real)
        SELECT @mes, @fecha_corte, h.bucket, h.ejecutivo_key, h.region_key, h.canal_key,
               h.estatus_comercial, h.monto_cartera, t.tasa, t.tasa_origen,
               h.monto_cartera * t.tasa, NULL
        FROM   #hoy h
        JOIN   #tasa t ON t.bucket = h.bucket AND t.tipo_gestion = h.tipo_gestion;

        /* Solo el PRONOSTICO. Lo real no se guarda aqui: vive en
           gold.vw_cobranza_diaria y se une por fecha en el reporte. Ver la nota en
           ddl_presupuesto.sql sobre por que esa columna se quito. */
        INSERT INTO gold.fact_presupuesto_cobranza
            (mes_presupuesto, fecha, fecha_corte, es_dia_habil, slot_calendario,
             origen, monto_presupuesto)
        SELECT @mes, s.fecha, @fecha_corte, s.es_dia_habil, s.slot,
               CASE WHEN s.fecha < @fecha_corte THEN 'OBSERVADO' ELSE 'PRONOSTICO' END,
               CASE
                 /* Antes del corte el dinero YA estaba en el banco, asi que no se
                    pronostica: se copia la caja de ese dia. Es el unico lugar donde
                    esta tabla toca dato real, y no la desactualiza porque esos dias
                    ya estan cerrados cuando se emite el presupuesto. */
                 WHEN s.fecha < @fecha_corte THEN ISNULL(caja.v, 0)
                 -- dia no habil: 0.23% historico, se presupuesta en cero
                 WHEN s.es_dia_habil = 0     THEN 0
                 ELSE (@T1 + @T3) * p.peso / NULLIF(@peso_restante, 0)
               END
        FROM   #slot s
        LEFT JOIN #perfil p ON p.slot = s.slot
        OUTER APPLY (SELECT k.monto v FROM #caja k WHERE k.fecha = s.fecha) caja
        WHERE  s.fecha >= @mes AND s.fecha <= @fin
        OPTION (RECOMPILE);

        COMMIT TRANSACTION;

        DECLARE @tot   DECIMAL(19,2) = @T1 + @T2 + @T3;
        DECLARE @cob   DECIMAL(19,2) =
            (SELECT SUM(c.monto_esperado) FROM gold.fact_presupuesto_cartera c
             JOIN gold.dim_ejecutivo e ON e.ejecutivo_key = c.ejecutivo_key
             WHERE c.mes_presupuesto = @mes AND e.es_cobrable = 1);
        DECLARE @seg   INT = (SELECT COUNT(*) FROM gold.fact_presupuesto_cartera WHERE mes_presupuesto = @mes);
        DECLARE @resp  INT = (SELECT COUNT(*) FROM gold.fact_presupuesto_cartera
                              WHERE mes_presupuesto = @mes AND tasa_origen = 'BUCKET');

        PRINT '   T1 cartera x tasa : ' + CONVERT(VARCHAR(20), CAST(@T1/1000000.0 AS DECIMAL(12,1))) + ' MM';
        PRINT '   T2 ya en el banco : ' + CONVERT(VARCHAR(20), CAST(@T2/1000000.0 AS DECIMAL(12,1))) + ' MM';
        PRINT '   T3 del mes (k=' + CONVERT(VARCHAR(10), CAST(@k AS DECIMAL(6,3))) + ') : '
                                  + CONVERT(VARCHAR(20), CAST(@T3/1000000.0 AS DECIMAL(12,1))) + ' MM';
        PRINT '   PRESUPUESTO TOTAL : ' + CONVERT(VARCHAR(20), CAST(@tot/1000000.0 AS DECIMAL(12,1))) + ' MM';
        PRINT '   de eso, T1 cobrable: ' + CONVERT(VARCHAR(20), CAST(@cob/1000000.0 AS DECIMAL(12,1))) + ' MM';
        PRINT '   Segmentos: ' + CAST(@seg AS VARCHAR(8))
            + ' | con tasa de respaldo: ' + CAST(@resp AS VARCHAR(8))
            + ' | Duracion: ' + CAST(DATEDIFF(SECOND, @t0, GETDATE()) AS VARCHAR(10)) + ' s';
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        PRINT 'ERROR en gold.load_presupuesto_cobranza: ' + ERROR_MESSAGE();
        THROW;
    END CATCH;
END;
GO
PRINT 'Procedure gold.load_presupuesto_cobranza created.';
GO
