USE ANALISIS_DATOS;
GO

/*
===============================================================================
PROJECT: Enterprise Data Warehouse (dwh-ciosa)
LAYER: Gold - load procedures for the star schema.

STYLE: one stored procedure per dimension/fact for now (not a single combined
gold.load_gold like silver's), so each piece can be built and tested in
isolation before combining - same reasoning as the rest of this project given
how many unexplained compilation issues this SQL Server 2012 instance has
produced when things got batched together. May consolidate later once every
piece is proven.

gold.dim_fecha is NOT loaded here - it's static, populated once via
populate_dim_fecha.sql, not part of the regular refresh cycle.
===============================================================================
*/

-- ==========================================================
-- gold.load_dim_cliente (SCD Tipo 1)
-- 2026-08-17: rediseñado de TRUNCATE+INSERT a UPDATE+INSERT explicito (sin
-- DELETE) - TRUNCATE dejo de ser viable en cuanto gold.fact_aplicacion_pagos
-- agrego su FK hacia esta tabla (SQL Server no permite TRUNCATE sobre una
-- tabla referenciada por FK, sin importar si la tabla hija esta vacia o no).
-- No se borran clientes que ya no aparecen en kna1 (nunca se ha visto un
-- hard-delete real de un cliente en SAP, y borrar aqui arriesgaria romper
-- las FK de las facts si algun dia si pasa) - solo se actualizan los
-- existentes y se insertan los nuevos, mismo principio "explicito, no MERGE"
-- ya establecido para las SCD2 de este archivo.
-- ==========================================================
IF OBJECT_ID('gold.load_dim_cliente', 'P') IS NOT NULL
    DROP PROCEDURE gold.load_dim_cliente;
GO

CREATE PROCEDURE gold.load_dim_cliente
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @start_time DATETIME, @end_time DATETIME, @rows_updated INT, @rows_inserted INT;

    BEGIN TRY
        SET @start_time = GETDATE();
        PRINT '>> Cargando gold.dim_cliente...';

        IF OBJECT_ID('tempdb..#fuente_cliente') IS NOT NULL
            DROP TABLE #fuente_cliente;

        SELECT
            k.cliente_id,
            k.rfc,
            CASE
                WHEN kk.etiqueta_credito = 'FILIAL' THEN 'FILIAL'
                WHEN k.rfc IS NULL THEN 'DIRECCION_ALTERNA'
                WHEN k.rfc IN ('XAXX010101000', 'XEXX010101000') THEN 'GENERICO'
                ELSE 'PADRE'
            END AS tipo_cliente,  -- confirmado 2026-08-07: KRAUS='FILIAL' manda, luego RFC nulo/generico
            k.nombre, k.nombre2, k.pais, k.estado, k.poblacion, k.codigo_postal, k.calle,
            k.bloqueo_pedido, k.regimen_fiscal, k.telefono, k.telefono_extra, k.whatsapp,
            k.fecha_creacion, k.grupo_cuentas, k.proveedor_vinculado, k.flag_bloqueado,
            k.flag_cliente_ocasional, k.flag_persona_fisica, k.flag_sujeto_iva,
            k.tipo_servicio_paq1, k.tipo_servicio_paq2, k.tipo_servicio_paq3,
            k.tiempo_entrega_paq1, k.tiempo_entrega_paq2, k.tiempo_entrega_paq3
        INTO #fuente_cliente
        FROM silver.sap_kna1 k
        LEFT JOIN silver.sap_knkk kk
            ON kk.cliente_id = k.cliente_id;

        -- Paso 1: actualizar clientes ya existentes (sin importar si algo
        -- cambio realmente - SCD1 siempre sobreescribe, no hay version que cuidar)
        UPDATE d
        SET d.rfc = f.rfc, d.tipo_cliente = f.tipo_cliente, d.nombre = f.nombre, d.nombre2 = f.nombre2,
            d.pais = f.pais, d.estado = f.estado, d.poblacion = f.poblacion, d.codigo_postal = f.codigo_postal,
            d.calle = f.calle, d.bloqueo_pedido = f.bloqueo_pedido, d.regimen_fiscal = f.regimen_fiscal,
            d.telefono = f.telefono, d.telefono_extra = f.telefono_extra, d.whatsapp = f.whatsapp,
            d.fecha_creacion = f.fecha_creacion, d.grupo_cuentas = f.grupo_cuentas,
            d.proveedor_vinculado = f.proveedor_vinculado, d.flag_bloqueado = f.flag_bloqueado,
            d.flag_cliente_ocasional = f.flag_cliente_ocasional, d.flag_persona_fisica = f.flag_persona_fisica,
            d.flag_sujeto_iva = f.flag_sujeto_iva, d.tipo_servicio_paq1 = f.tipo_servicio_paq1,
            d.tipo_servicio_paq2 = f.tipo_servicio_paq2, d.tipo_servicio_paq3 = f.tipo_servicio_paq3,
            d.tiempo_entrega_paq1 = f.tiempo_entrega_paq1, d.tiempo_entrega_paq2 = f.tiempo_entrega_paq2,
            d.tiempo_entrega_paq3 = f.tiempo_entrega_paq3, d.fecha_actualizacion = GETDATE()
        FROM gold.dim_cliente d
        JOIN #fuente_cliente f ON f.cliente_id = d.cliente_id;
        SET @rows_updated = @@ROWCOUNT;

        -- Paso 2: insertar clientes nuevos (no existian antes en dim_cliente)
        INSERT INTO gold.dim_cliente (
            cliente_id, rfc, tipo_cliente, nombre, nombre2, pais, estado,
            poblacion, codigo_postal, calle, bloqueo_pedido, regimen_fiscal,
            telefono, telefono_extra, whatsapp, fecha_creacion, grupo_cuentas,
            proveedor_vinculado, flag_bloqueado, flag_cliente_ocasional,
            flag_persona_fisica, flag_sujeto_iva,
            tipo_servicio_paq1, tipo_servicio_paq2, tipo_servicio_paq3,
            tiempo_entrega_paq1, tiempo_entrega_paq2, tiempo_entrega_paq3
        )
        SELECT
            f.cliente_id, f.rfc, f.tipo_cliente, f.nombre, f.nombre2, f.pais, f.estado,
            f.poblacion, f.codigo_postal, f.calle, f.bloqueo_pedido, f.regimen_fiscal,
            f.telefono, f.telefono_extra, f.whatsapp, f.fecha_creacion, f.grupo_cuentas,
            f.proveedor_vinculado, f.flag_bloqueado, f.flag_cliente_ocasional,
            f.flag_persona_fisica, f.flag_sujeto_iva,
            f.tipo_servicio_paq1, f.tipo_servicio_paq2, f.tipo_servicio_paq3,
            f.tiempo_entrega_paq1, f.tiempo_entrega_paq2, f.tiempo_entrega_paq3
        FROM #fuente_cliente f
        WHERE NOT EXISTS (
            SELECT 1 FROM gold.dim_cliente d WHERE d.cliente_id = f.cliente_id
        );
        SET @rows_inserted = @@ROWCOUNT;

        DROP TABLE #fuente_cliente;

        SET @end_time = GETDATE();
        PRINT 'Filas actualizadas: ' + CAST(@rows_updated AS NVARCHAR) + ' | Filas nuevas: ' + CAST(@rows_inserted AS NVARCHAR) + ' | Duration: ' + CAST(DATEDIFF(SECOND, @start_time, @end_time) AS NVARCHAR) + ' s';
    END TRY
    BEGIN CATCH
        PRINT 'ERROR en gold.dim_cliente: ' + ERROR_MESSAGE();
        THROW;
    END CATCH;
END;
GO

PRINT 'Procedure gold.load_dim_cliente created successfully.';
GO

-- ==========================================================
-- gold.load_dim_cliente_comercial (SCD Tipo 2)
-- Primera SCD2 real del proyecto - construida en pasos explicitos (temp
-- table + UPDATE + INSERT) en vez de un solo MERGE, dado el historial de
-- errores de compilacion dificiles de rastrear de esta instancia de SQL
-- Server 2012 cuando se agrupa demasiado en un solo batch.
-- ==========================================================
IF OBJECT_ID('gold.load_dim_cliente_comercial', 'P') IS NOT NULL
    DROP PROCEDURE gold.load_dim_cliente_comercial;
GO

CREATE PROCEDURE gold.load_dim_cliente_comercial
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @start_time DATETIME, @end_time DATETIME, @rows_count INT;
    DECLARE @hoy DATE = CAST(GETDATE() AS DATE);

    BEGIN TRY
        SET @start_time = GETDATE();
        PRINT '>> Cargando gold.dim_cliente_comercial...';

        -- Paso 1: elegir el canal representante por cliente (prioridad de
        -- estatus, luego canal_distribucion mas bajo como desempate final)
        IF OBJECT_ID('tempdb..#representante') IS NOT NULL
            DROP TABLE #representante;

        ;WITH prioridad AS (
            SELECT
                cliente_id, organizacion_ventas, canal_distribucion, sector,
                region, ruta, ruta_nombre, condicion_pago,
                vendedor_id, vendedor_nombre, gerente_id, gerente_nombre, estatus_comercial,
                CASE estatus_comercial
                    WHEN 'ACTIVO' THEN 1
                    WHEN 'LEGAL' THEN 2
                    WHEN 'REVISAR' THEN 3
                    WHEN 'INACTIVO' THEN 4
                    WHEN 'FUERA_DE_ALCANCE' THEN 5
                END AS prioridad_estatus
            FROM gold.vw_cliente_canal_estatus
        )
        SELECT
            cliente_id, organizacion_ventas, canal_distribucion, sector,
            region, ruta, ruta_nombre, condicion_pago,
            vendedor_id, vendedor_nombre, gerente_id, gerente_nombre, estatus_comercial,
            HASHBYTES('SHA2_256',
                ISNULL(region, '') + '|' + ISNULL(ruta, '') + '|' + ISNULL(ruta_nombre, '') + '|' +
                ISNULL(condicion_pago, '') + '|' + ISNULL(vendedor_id, '') + '|' + ISNULL(vendedor_nombre, '') + '|' +
                ISNULL(gerente_id, '') + '|' + ISNULL(gerente_nombre, '') + '|' + estatus_comercial
            ) AS hash_atributos,
            ROW_NUMBER() OVER (PARTITION BY cliente_id ORDER BY prioridad_estatus, canal_distribucion) AS rn
        INTO #representante
        FROM prioridad;

        DELETE FROM #representante WHERE rn <> 1;

        -- Paso 2: cerrar versiones vigentes cuyo hash de atributos cambio
        UPDATE d
        SET d.es_vigente = 0,
            d.fecha_fin_vigencia = DATEADD(DAY, -1, @hoy)
        FROM gold.dim_cliente_comercial d
        JOIN #representante r ON r.cliente_id = d.cliente_id
        WHERE d.es_vigente = 1
          AND d.hash_atributos <> r.hash_atributos;

        -- Paso 3: insertar version nueva para clientes nuevos o con hash distinto
        -- (paso 2 ya cerro la version vigente anterior de los que cambiaron,
        -- asi que "sin version vigente" cubre ambos casos: nuevo Y cambiado)
        INSERT INTO gold.dim_cliente_comercial (
            cliente_id, organizacion_ventas, canal_distribucion, sector,
            region, ruta, ruta_nombre, condicion_pago,
            vendedor_id, vendedor_nombre, gerente_id, gerente_nombre, estatus_comercial,
            hash_atributos, fecha_inicio_vigencia, fecha_fin_vigencia, es_vigente
        )
        SELECT
            r.cliente_id, r.organizacion_ventas, r.canal_distribucion, r.sector,
            r.region, r.ruta, r.ruta_nombre, r.condicion_pago,
            r.vendedor_id, r.vendedor_nombre, r.gerente_id, r.gerente_nombre, r.estatus_comercial,
            r.hash_atributos, @hoy, NULL, 1
        FROM #representante r
        WHERE NOT EXISTS (
            SELECT 1 FROM gold.dim_cliente_comercial d
            WHERE d.cliente_id = r.cliente_id AND d.es_vigente = 1
        );

        SET @rows_count = @@ROWCOUNT;

        DROP TABLE #representante;

        SET @end_time = GETDATE();
        PRINT 'Filas nuevas/versionadas: ' + CAST(@rows_count AS NVARCHAR) + ' | Duration: ' + CAST(DATEDIFF(SECOND, @start_time, @end_time) AS NVARCHAR) + ' s';
    END TRY
    BEGIN CATCH
        PRINT 'ERROR en gold.dim_cliente_comercial: ' + ERROR_MESSAGE();
        THROW;
    END CATCH;
END;
GO

PRINT 'Procedure gold.load_dim_cliente_comercial created successfully.';
GO

-- ==========================================================
-- gold.load_dim_cliente_credito (SCD Tipo 2)
-- Requiere que gold.dim_cliente_comercial ya este cargada (se apoya en su
-- version vigente para saber "cual canal" usar al buscar analista/cobrador).
-- No se llama automaticamente - el orden de ejecucion (comercial antes que
-- credito) es responsabilidad de quien ejecute los procedimientos, no de un
-- wrapper que llame uno desde el otro (mismo motivo que dq, ver nota en
-- sp_load_dq.sql).
-- ==========================================================
IF OBJECT_ID('gold.load_dim_cliente_credito', 'P') IS NOT NULL
    DROP PROCEDURE gold.load_dim_cliente_credito;
GO

CREATE PROCEDURE gold.load_dim_cliente_credito
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @start_time DATETIME, @end_time DATETIME, @rows_count INT;
    DECLARE @hoy DATE = CAST(GETDATE() AS DATE);

    BEGIN TRY
        SET @start_time = GETDATE();
        PRINT '>> Cargando gold.dim_cliente_credito...';

        -- Paso 1: analista de credito (E1) y cobrador (CC), resueltos en el
        -- canal que gold.dim_cliente_comercial ya eligio como representante
        -- (mismo desempate de 'contador' mas bajo usado en
        -- gold.vw_cliente_canal_estatus, por si hay mas de una asignacion
        -- del mismo rol en ese canal)
        IF OBJECT_ID('tempdb..#representante_credito') IS NOT NULL
            DROP TABLE #representante_credito;

        ;WITH analista AS (
            SELECT
                p.cliente_id, p.organizacion_ventas, p.canal_distribucion, p.sector,
                p.id_interlocutor AS analista_id, p.nombre_interlocutor AS analista_nombre,
                ROW_NUMBER() OVER (
                    PARTITION BY p.cliente_id, p.organizacion_ventas, p.canal_distribucion, p.sector
                    ORDER BY p.contador
                ) AS rn
            FROM silver.sap_knvp p
            WHERE p.funcion_interlocutor = 'E1'
        ),
        cobrador AS (
            SELECT
                p.cliente_id, p.organizacion_ventas, p.canal_distribucion, p.sector,
                p.id_interlocutor AS cobrador_id, p.nombre_interlocutor AS cobrador_nombre,
                ROW_NUMBER() OVER (
                    PARTITION BY p.cliente_id, p.organizacion_ventas, p.canal_distribucion, p.sector
                    ORDER BY p.contador
                ) AS rn
            FROM silver.sap_knvp p
            WHERE p.funcion_interlocutor = 'CC'
        )
        SELECT
            k.cliente_id,
            k.limite_credito,
            k.bloqueo_credito,
            k.clasificacion_riesgo,
            k.etiqueta_credito,
            k.grupo_credito,
            an.analista_id,
            an.analista_nombre,
            co.cobrador_id,
            co.cobrador_nombre,
            HASHBYTES('SHA2_256',
                ISNULL(CAST(k.limite_credito AS VARCHAR(20)), '') + '|' + ISNULL(k.bloqueo_credito, '') + '|' +
                ISNULL(k.clasificacion_riesgo, '') + '|' + ISNULL(k.etiqueta_credito, '') + '|' + ISNULL(k.grupo_credito, '') + '|' +
                ISNULL(an.analista_id, '') + '|' + ISNULL(an.analista_nombre, '') + '|' +
                ISNULL(co.cobrador_id, '') + '|' + ISNULL(co.cobrador_nombre, '')
            ) AS hash_atributos
        INTO #representante_credito
        FROM silver.sap_knkk k
        LEFT JOIN gold.dim_cliente_comercial dc
            ON dc.cliente_id = k.cliente_id AND dc.es_vigente = 1
        LEFT JOIN analista an
            ON an.cliente_id = k.cliente_id AND an.organizacion_ventas = dc.organizacion_ventas
            AND an.canal_distribucion = dc.canal_distribucion AND an.sector = dc.sector AND an.rn = 1
        LEFT JOIN cobrador co
            ON co.cliente_id = k.cliente_id AND co.organizacion_ventas = dc.organizacion_ventas
            AND co.canal_distribucion = dc.canal_distribucion AND co.sector = dc.sector AND co.rn = 1;

        -- Paso 2: cerrar versiones vigentes cuyo hash de atributos cambio
        UPDATE d
        SET d.es_vigente = 0,
            d.fecha_fin_vigencia = DATEADD(DAY, -1, @hoy)
        FROM gold.dim_cliente_credito d
        JOIN #representante_credito r ON r.cliente_id = d.cliente_id
        WHERE d.es_vigente = 1
          AND d.hash_atributos <> r.hash_atributos;

        -- Paso 3: insertar version nueva para clientes nuevos o con hash distinto
        INSERT INTO gold.dim_cliente_credito (
            cliente_id, limite_credito, bloqueo_credito, clasificacion_riesgo,
            etiqueta_credito, grupo_credito, analista_credito_id, analista_credito_nombre,
            cobrador_id, cobrador_nombre, hash_atributos, fecha_inicio_vigencia, fecha_fin_vigencia, es_vigente
        )
        SELECT
            r.cliente_id, r.limite_credito, r.bloqueo_credito, r.clasificacion_riesgo,
            r.etiqueta_credito, r.grupo_credito, r.analista_id, r.analista_nombre,
            r.cobrador_id, r.cobrador_nombre, r.hash_atributos, @hoy, NULL, 1
        FROM #representante_credito r
        WHERE NOT EXISTS (
            SELECT 1 FROM gold.dim_cliente_credito d
            WHERE d.cliente_id = r.cliente_id AND d.es_vigente = 1
        );

        SET @rows_count = @@ROWCOUNT;

        DROP TABLE #representante_credito;

        SET @end_time = GETDATE();
        PRINT 'Filas nuevas/versionadas: ' + CAST(@rows_count AS NVARCHAR) + ' | Duration: ' + CAST(DATEDIFF(SECOND, @start_time, @end_time) AS NVARCHAR) + ' s';
    END TRY
    BEGIN CATCH
        PRINT 'ERROR en gold.dim_cliente_credito: ' + ERROR_MESSAGE();
        THROW;
    END CATCH;
END;
GO

PRINT 'Procedure gold.load_dim_cliente_credito created successfully.';
GO

-- ==========================================================
-- gold.load_fact_saldo_cartera
-- Foto diaria del saldo abierto por cliente (silver.sap_bsid, agregado a
-- nivel cliente) + comportamiento historico de pago (DPP y % a tiempo/tarde,
-- desde gold.fact_aplicacion_pagos WHERE tipo_aplicacion='PAGO' - ver Paso 2
-- abajo). Corregido y validado 2026-08-17 (primera corrida exitosa: 4,571
-- clientes con saldo). NUNCA borra fotos de dias anteriores - solo agrega la
-- de hoy (con un DELETE de la fecha de hoy primero, para que sea seguro
-- volver a correrlo el mismo dia sin duplicar).
-- ==========================================================
IF OBJECT_ID('gold.load_fact_saldo_cartera', 'P') IS NOT NULL
    DROP PROCEDURE gold.load_fact_saldo_cartera;
GO

CREATE PROCEDURE gold.load_fact_saldo_cartera
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @start_time DATETIME, @end_time DATETIME, @rows_count INT;
    DECLARE @hoy DATE = CAST(GETDATE() AS DATE);

    BEGIN TRY
        SET @start_time = GETDATE();
        PRINT '>> Cargando gold.fact_saldo_cartera (snapshot ' + CONVERT(VARCHAR, @hoy, 23) + ')...';

        -- Idempotente: si ya se corrio hoy, se reemplaza esa foto (no se duplica)
        DELETE FROM gold.fact_saldo_cartera WHERE fecha_snapshot = @hoy;

        -- Paso 1: agregar silver.sap_bsid a nivel cliente.
        -- REDISEÑADO 2026-08-18 tras reconciliar contra un reporte externo de
        -- cartera (ver ddl_gold.sql para el detalle completo de las 3 causas
        -- encontradas):
        --   1. monto_moneda_local NUNCA trae signo (igual que bsad) -
        --      debe_haber='H' (pagos/notas de credito/devoluciones/ajustes
        --      sentados como partida abierta sin aplicar) se firma como
        --      NEGATIVO antes de agregar (#bsid_firmado) - sin esto se sumaba
        --      como deuda en vez de restar ($143.2M mal sumados en TODO bsid,
        --      sin filtrar).
        --   2. clase_documento='SA' (asientos de mayor/GL) excluido por
        --      completo - no son documentos de cliente reales.
        --   3. Periodo de gracia de 16 dias: 1-16 dias vencido = "saldo sano"
        --      (saldo_1_16, NO cuenta en saldo_vencido), solo 17+ dias es
        --      vencido real. Buckets de antiguedad re-cortados a 17-31/
        --      32-180/181+ para ser comparables con el reporte externo.
        IF OBJECT_ID('tempdb..#bsid_firmado') IS NOT NULL
            DROP TABLE #bsid_firmado;

        SELECT *,
            CASE WHEN debe_haber = 'H' THEN -monto_moneda_local ELSE monto_moneda_local END AS monto_firmado,
            CASE WHEN fecha_vencimiento IS NOT NULL AND fecha_vencimiento < @hoy
                 THEN DATEDIFF(DAY, fecha_vencimiento, @hoy) END AS dias_vencido
        INTO #bsid_firmado
        FROM silver.sap_bsid
        WHERE clase_documento <> 'SA';

        IF OBJECT_ID('tempdb..#saldo_cliente') IS NOT NULL
            DROP TABLE #saldo_cliente;

        SELECT
            cliente_id,
            SUM(monto_firmado) AS saldo_total,
            SUM(CASE WHEN dias_vencido IS NULL THEN monto_firmado ELSE 0 END) AS saldo_no_vencido,
            SUM(CASE WHEN dias_vencido BETWEEN 1 AND 16 THEN monto_firmado ELSE 0 END) AS saldo_1_16,
            SUM(CASE WHEN dias_vencido >= 17 THEN monto_firmado ELSE 0 END) AS saldo_vencido,
            COUNT(*) AS num_documentos_abiertos,
            MAX(dias_vencido) AS dias_vencido_max,
            SUM(CASE WHEN dias_vencido BETWEEN 17 AND 31 THEN monto_firmado ELSE 0 END) AS saldo_17_31,
            SUM(CASE WHEN dias_vencido BETWEEN 32 AND 180 THEN monto_firmado ELSE 0 END) AS saldo_32_180,
            SUM(CASE WHEN dias_vencido > 180 THEN monto_firmado ELSE 0 END) AS saldo_181_mas,
            SUM(CASE WHEN nivel_reclamacion IS NOT NULL THEN 1 ELSE 0 END) AS documentos_con_reclamacion,
            MAX(nivel_reclamacion) AS nivel_reclamacion_max
        INTO #saldo_cliente
        FROM #bsid_firmado
        GROUP BY cliente_id;

        DROP TABLE #bsid_firmado;

        -- Paso 2: DPP / DPP ponderado / % a tiempo-tarde, ventanas de 3 y 12
        -- meses hacia atras desde @hoy.
        -- MIGRADO 2026-08-19 de gold.fact_aplicacion_pagos a gold.fact_pagos/
        -- gold.fact_facturas - la logica de matching de fact_aplicacion_pagos
        -- (3 niveles: REBZG/GRUPO_INAMBIGUO/sin match) resulto tener bugs
        -- reales de sobre-atribucion (un candidato podia "explicar" facturas
        -- por mucho mas de lo que realmente vale - ej. un documento de $137
        -- atribuido a $2.5M en facturas), asi que se reemplazo por el diseño
        -- simple: solo relaciona grupos de compensacion con EXACTAMENTE 1
        -- pago virgen candidato (misma logica que gold.vw_pago_factura_simple,
        -- pero SIN su filtro de canal/tipo_cliente - aqui se preserva el
        -- mismo alcance amplio que ya tiene el Paso 1 de saldo arriba, para no
        -- introducir una asimetria de alcance entre saldo y DPP dentro de la
        -- misma fila de fact_saldo_cartera. Si en el futuro se quiere un DPP
        -- acotado a mayoreo/clientes reales, agregar esa version por separado,
        -- no reemplazar esta).
        -- fecha_pago = fecha_documento del deposito virgen (fecha real del
        -- deposito, no la del documento que aplico). Sin filas "sin match":
        -- a diferencia de fact_aplicacion_pagos, aqui solo existen pares ya
        -- resueltos, por construccion (INNER JOIN en toda la cadena).
        IF OBJECT_ID('tempdb..#dpp_cliente') IS NOT NULL
            DROP TABLE #dpp_cliente;

        ;WITH pagos_por_grupo AS (
            SELECT documento_compensacion, ejercicio_compensacion, COUNT(*) AS num_pagos_candidatos
            FROM gold.fact_pagos
            GROUP BY documento_compensacion, ejercicio_compensacion
        ),
        pago_factura AS (
            SELECT
                p.cliente_id,
                p.fecha_documento AS fecha_pago,
                f.monto_moneda_local AS monto_factura,
                DATEDIFF(DAY, f.fecha_vencimiento, p.fecha_documento) AS dias_pago
            FROM gold.fact_pagos p
            INNER JOIN pagos_por_grupo g
                ON g.documento_compensacion = p.documento_compensacion
               AND g.ejercicio_compensacion = p.ejercicio_compensacion
               AND g.num_pagos_candidatos = 1
            INNER JOIN gold.fact_facturas f
                ON f.documento_compensacion = p.documento_compensacion
               AND f.ejercicio_compensacion = p.ejercicio_compensacion
        )
        SELECT
            cliente_id,
            AVG(CASE WHEN fecha_pago >= DATEADD(MONTH, -3, @hoy) THEN dias_pago END) AS dpp_3m,
            SUM(CASE WHEN fecha_pago >= DATEADD(MONTH, -3, @hoy) THEN dias_pago * monto_factura END)
                / NULLIF(SUM(CASE WHEN fecha_pago >= DATEADD(MONTH, -3, @hoy) THEN monto_factura END), 0) AS dpp_ponderado_3m,
            AVG(dias_pago) AS dpp_12m,
            SUM(dias_pago * monto_factura) / NULLIF(SUM(monto_factura), 0) AS dpp_ponderado_12m,
            SUM(CASE WHEN fecha_pago >= DATEADD(MONTH, -3, @hoy) AND dias_pago <= 0 THEN monto_factura ELSE 0 END)
                / NULLIF(SUM(CASE WHEN fecha_pago >= DATEADD(MONTH, -3, @hoy) THEN monto_factura END), 0) * 100 AS pct_pagos_a_tiempo_3m,
            SUM(CASE WHEN fecha_pago >= DATEADD(MONTH, -3, @hoy) AND dias_pago > 0 THEN monto_factura ELSE 0 END)
                / NULLIF(SUM(CASE WHEN fecha_pago >= DATEADD(MONTH, -3, @hoy) THEN monto_factura END), 0) * 100 AS pct_pagos_tarde_3m,
            SUM(CASE WHEN dias_pago <= 0 THEN monto_factura ELSE 0 END)
                / NULLIF(SUM(monto_factura), 0) * 100 AS pct_pagos_a_tiempo_12m,
            SUM(CASE WHEN dias_pago > 0 THEN monto_factura ELSE 0 END)
                / NULLIF(SUM(monto_factura), 0) * 100 AS pct_pagos_tarde_12m
        INTO #dpp_cliente
        FROM pago_factura
        WHERE fecha_pago >= DATEADD(MONTH, -12, @hoy)
        GROUP BY cliente_id;

        -- Paso 3: combinar saldo + DPP + dimensiones SCD2 (join temporal a @hoy) e insertar
        INSERT INTO gold.fact_saldo_cartera (
            cliente_id, fecha_snapshot,
            saldo_total, saldo_no_vencido, saldo_1_16, saldo_vencido, num_documentos_abiertos, dias_vencido_max,
            saldo_17_31, saldo_32_180, saldo_181_mas,
            documentos_con_reclamacion, nivel_reclamacion_max,
            dpp_3m, dpp_ponderado_3m, dpp_12m, dpp_ponderado_12m,
            pct_pagos_a_tiempo_3m, pct_pagos_tarde_3m, pct_pagos_a_tiempo_12m, pct_pagos_tarde_12m,
            id_cliente_comercial, id_cliente_credito
        )
        SELECT
            s.cliente_id, @hoy,
            s.saldo_total, s.saldo_no_vencido, s.saldo_1_16, s.saldo_vencido, s.num_documentos_abiertos, s.dias_vencido_max,
            s.saldo_17_31, s.saldo_32_180, s.saldo_181_mas,
            s.documentos_con_reclamacion, s.nivel_reclamacion_max,
            d.dpp_3m, d.dpp_ponderado_3m, d.dpp_12m, d.dpp_ponderado_12m,
            d.pct_pagos_a_tiempo_3m, d.pct_pagos_tarde_3m, d.pct_pagos_a_tiempo_12m, d.pct_pagos_tarde_12m,
            dc.id_surrogate, dcr.id_surrogate
        FROM #saldo_cliente s
        LEFT JOIN #dpp_cliente d
            ON d.cliente_id = s.cliente_id
        LEFT JOIN gold.dim_cliente_comercial dc
            ON dc.cliente_id = s.cliente_id
            AND @hoy BETWEEN dc.fecha_inicio_vigencia AND ISNULL(dc.fecha_fin_vigencia, '99991231')
        LEFT JOIN gold.dim_cliente_credito dcr
            ON dcr.cliente_id = s.cliente_id
            AND @hoy BETWEEN dcr.fecha_inicio_vigencia AND ISNULL(dcr.fecha_fin_vigencia, '99991231');
        SET @rows_count = @@ROWCOUNT;

        DROP TABLE #saldo_cliente;
        DROP TABLE #dpp_cliente;

        SET @end_time = GETDATE();
        PRINT 'Filas (clientes con saldo): ' + CAST(@rows_count AS NVARCHAR) + ' | Duration: ' + CAST(DATEDIFF(SECOND, @start_time, @end_time) AS NVARCHAR) + ' s';
    END TRY
    BEGIN CATCH
        PRINT 'ERROR en gold.fact_saldo_cartera: ' + ERROR_MESSAGE();
        THROW;
    END CATCH;
END;
GO

PRINT 'Procedure gold.load_fact_saldo_cartera created successfully.';
GO

-- ==========================================================
-- gold.load_fact_aplicacion_pagos fue ELIMINADO 2026-08-19 junto con la
-- tabla gold.fact_aplicacion_pagos - ver nota en ddl_gold.sql (bugs reales
-- de sobre-atribucion en el matching de 3 niveles). Reemplazado por
-- gold.load_fact_pagos / gold.load_fact_facturas de abajo, mas
-- gold.vw_pago_factura_simple para la relacion.
-- ==========================================================

-- ==========================================================
-- gold.load_fact_pagos
-- ==========================================================
IF OBJECT_ID('gold.load_fact_pagos', 'P') IS NOT NULL
    DROP PROCEDURE gold.load_fact_pagos;
GO

CREATE PROCEDURE gold.load_fact_pagos
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @start_time DATETIME, @end_time DATETIME, @rows_count INT;

    BEGIN TRY
        SET @start_time = GETDATE();
        PRINT '>> Cargando gold.fact_pagos (Merge Incremental)...';

        DECLARE @mes_anterior_inicio DATE = DATEADD(MONTH, DATEDIFF(MONTH, 0, GETDATE()) - 1, 0);

        MERGE gold.fact_pagos AS tgt
        USING (
            SELECT
                sociedad, cliente_id, ejercicio, documento_id, posicion,
                fecha_documento, fecha_compensacion, monto_moneda_local,
                documento_compensacion, ejercicio_compensacion
            FROM silver.sap_bsad
            WHERE clase_documento = 'DZ'
              AND sgtxt = 'Asignación Aut. Deposito'
              AND debe_haber <> 'S' -- excluye la linea espejo/contrapartida del documento "hijo" (fix 2026-08-19, ver ddl_gold.sql)
              AND monto_moneda_local > 0 -- excluye residuos tecnicos en $0.00 (fix 2026-08-19, ver ddl_gold.sql)
              AND fecha_compensacion >= @mes_anterior_inicio
        ) AS src
        ON  tgt.sociedad = src.sociedad
        AND tgt.cliente_id = src.cliente_id
        AND tgt.ejercicio = src.ejercicio
        AND tgt.documento_id = src.documento_id
        AND tgt.posicion = src.posicion

        WHEN MATCHED THEN UPDATE SET
            tgt.fecha_compensacion = src.fecha_compensacion,
            tgt.monto_moneda_local = src.monto_moneda_local,
            tgt.documento_compensacion = src.documento_compensacion,
            tgt.ejercicio_compensacion = src.ejercicio_compensacion,
            tgt.fecha_carga = GETDATE()

        WHEN NOT MATCHED THEN
        INSERT (sociedad, cliente_id, ejercicio, documento_id, posicion,
                fecha_documento, fecha_compensacion, monto_moneda_local,
                documento_compensacion, ejercicio_compensacion)
        VALUES (src.sociedad, src.cliente_id, src.ejercicio, src.documento_id, src.posicion,
                src.fecha_documento, src.fecha_compensacion, src.monto_moneda_local,
                src.documento_compensacion, src.ejercicio_compensacion);

        SET @rows_count = @@ROWCOUNT;
        SET @end_time = GETDATE();
        PRINT 'Filas: ' + CAST(@rows_count AS NVARCHAR) + ' | Duration: ' + CAST(DATEDIFF(SECOND, @start_time, @end_time) AS NVARCHAR) + ' s';
    END TRY
    BEGIN CATCH
        PRINT 'ERROR en gold.fact_pagos: ' + ERROR_MESSAGE();
        THROW;
    END CATCH;
END;
GO

PRINT 'Procedure gold.load_fact_pagos created successfully.';
GO

-- ==========================================================
-- gold.load_fact_facturas
-- ==========================================================
IF OBJECT_ID('gold.load_fact_facturas', 'P') IS NOT NULL
    DROP PROCEDURE gold.load_fact_facturas;
GO

CREATE PROCEDURE gold.load_fact_facturas
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @start_time DATETIME, @end_time DATETIME, @rows_count INT;

    BEGIN TRY
        SET @start_time = GETDATE();
        PRINT '>> Cargando gold.fact_facturas (Merge Incremental)...';

        DECLARE @mes_anterior_inicio DATE = DATEADD(MONTH, DATEDIFF(MONTH, 0, GETDATE()) - 1, 0);

        MERGE gold.fact_facturas AS tgt
        USING (
            SELECT
                sociedad, cliente_id, ejercicio, documento_id, posicion,
                fecha_documento, fecha_vencimiento, fecha_compensacion, monto_moneda_local,
                documento_compensacion, ejercicio_compensacion
            FROM silver.sap_bsad
            WHERE clase_documento IN ('F1', 'F2', 'F3', 'F4', 'F5', 'F6')
              AND fecha_compensacion >= @mes_anterior_inicio
        ) AS src
        ON  tgt.sociedad = src.sociedad
        AND tgt.cliente_id = src.cliente_id
        AND tgt.ejercicio = src.ejercicio
        AND tgt.documento_id = src.documento_id
        AND tgt.posicion = src.posicion

        WHEN MATCHED THEN UPDATE SET
            tgt.fecha_vencimiento = src.fecha_vencimiento,
            tgt.fecha_compensacion = src.fecha_compensacion,
            tgt.monto_moneda_local = src.monto_moneda_local,
            tgt.documento_compensacion = src.documento_compensacion,
            tgt.ejercicio_compensacion = src.ejercicio_compensacion,
            tgt.fecha_carga = GETDATE()

        WHEN NOT MATCHED THEN
        INSERT (sociedad, cliente_id, ejercicio, documento_id, posicion,
                fecha_documento, fecha_vencimiento, fecha_compensacion, monto_moneda_local,
                documento_compensacion, ejercicio_compensacion)
        VALUES (src.sociedad, src.cliente_id, src.ejercicio, src.documento_id, src.posicion,
                src.fecha_documento, src.fecha_vencimiento, src.fecha_compensacion, src.monto_moneda_local,
                src.documento_compensacion, src.ejercicio_compensacion);

        SET @rows_count = @@ROWCOUNT;
        SET @end_time = GETDATE();
        PRINT 'Filas: ' + CAST(@rows_count AS NVARCHAR) + ' | Duration: ' + CAST(DATEDIFF(SECOND, @start_time, @end_time) AS NVARCHAR) + ' s';
    END TRY
    BEGIN CATCH
        PRINT 'ERROR en gold.fact_facturas: ' + ERROR_MESSAGE();
        THROW;
    END CATCH;
END;
GO

PRINT 'Procedure gold.load_fact_facturas created successfully.';
GO
