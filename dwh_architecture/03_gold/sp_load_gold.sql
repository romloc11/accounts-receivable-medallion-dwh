/* ============================================================================
   Gold load procedures
   Objects : gold.load_dim_fecha, load_dim_cliente, load_dim_cliente_comercial,
             load_dim_cliente_credito, load_fact_saldo_cartera,
             load_fact_pagos_compensados, load_fact_facturas_compensadas,
             load_dim_empleado, load_fact_pagos, load_fact_facturas,
             load_fact_aplicacion_pagos, load_fact_facturas_pago_efectivo,
             load_fact_pagos_sin_aplicacion, load_gold
   Run     : EXEC gold.load_gold;   after silver.load_silver
   Notes   : Every procedure can also run alone. Running this whole file is
             safe: it only drops and creates procedures.
   ============================================================================ */
USE ANALISIS_DATOS;
GO

-- ----------------------------------------------------------------------------
-- gold.load_dim_fecha: appends days up to today + 1 year (from 2022-01-01 on an
-- empty table) and recalculates the business-day columns for every row.
-- ----------------------------------------------------------------------------
IF OBJECT_ID('gold.load_dim_fecha', 'P') IS NOT NULL
    DROP PROCEDURE gold.load_dim_fecha;
GO

CREATE PROCEDURE gold.load_dim_fecha
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @proc VARCHAR(128) = 'gold.load_dim_fecha',
            @step VARCHAR(128) = 'start',
            @t0   DATETIME2(0) = SYSDATETIME(),
            @t    DATETIME2(0) = SYSDATETIME(),
            @rows INT = 0,
            @err  VARCHAR(4000),
            @line INT;
    DECLARE @fecha_max_actual DATE, @fecha_max_objetivo DATE, @fecha_cursor DATE;

    BEGIN TRY
        SET @step = 'gold.dim_fecha new days'; SET @t = SYSDATETIME();

        SET DATEFIRST 7;  -- Sunday = 1, whatever the server setting

        SELECT @fecha_max_actual = MAX(fecha) FROM gold.dim_fecha;
        SET @fecha_max_objetivo = DATEADD(YEAR, 1, CAST(GETDATE() AS DATE));

        IF @fecha_max_actual IS NULL
            SET @fecha_cursor = '20220101';
        ELSE
            SET @fecha_cursor = DATEADD(DAY, 1, @fecha_max_actual);

        WHILE @fecha_cursor <= @fecha_max_objetivo
        BEGIN
            INSERT INTO gold.dim_fecha (
                fecha, anio, mes, nombre_mes, trimestre, dia,
                dia_semana, nombre_dia_semana, es_fin_de_semana, semana_anio
            )
            VALUES (
                @fecha_cursor,
                YEAR(@fecha_cursor),
                MONTH(@fecha_cursor),
                CASE MONTH(@fecha_cursor)
                    WHEN 1 THEN 'Enero' WHEN 2 THEN 'Febrero' WHEN 3 THEN 'Marzo' WHEN 4 THEN 'Abril'
                    WHEN 5 THEN 'Mayo' WHEN 6 THEN 'Junio' WHEN 7 THEN 'Julio' WHEN 8 THEN 'Agosto'
                    WHEN 9 THEN 'Septiembre' WHEN 10 THEN 'Octubre' WHEN 11 THEN 'Noviembre' WHEN 12 THEN 'Diciembre'
                END,
                DATEPART(QUARTER, @fecha_cursor),
                DAY(@fecha_cursor),
                DATEPART(WEEKDAY, @fecha_cursor),
                CASE DATEPART(WEEKDAY, @fecha_cursor)
                    WHEN 1 THEN 'Domingo' WHEN 2 THEN 'Lunes' WHEN 3 THEN 'Martes' WHEN 4 THEN 'Miercoles'
                    WHEN 5 THEN 'Jueves' WHEN 6 THEN 'Viernes' WHEN 7 THEN 'Sabado'
                END,
                CASE WHEN DATEPART(WEEKDAY, @fecha_cursor) IN (1, 7) THEN 1 ELSE 0 END,
                DATEPART(ISO_WEEK, @fecha_cursor)
            );
            SET @rows = @rows + 1;
            SET @fecha_cursor = DATEADD(DAY, 1, @fecha_cursor);
        END
        EXEC control.log_step @proc, @step, @t, @rows;

        -- Recalculated for the whole table, not only the new days: they depend on the
        -- whole month and on gold.dim_festivo, which can grow later.
        SET @step = 'gold.dim_fecha business days'; SET @t = SYSDATETIME();

        UPDATE d
        SET    d.es_festivo     = CASE WHEN f.fecha IS NULL THEN 0 ELSE 1 END,
               d.nombre_festivo = f.nombre
        FROM   gold.dim_fecha d
        LEFT JOIN gold.dim_festivo f ON f.fecha = d.fecha;

        UPDATE gold.dim_fecha
        SET    es_dia_habil = CASE WHEN es_fin_de_semana = 0 AND es_festivo = 0 THEN 1 ELSE 0 END;

        UPDATE gold.dim_fecha SET dia_habil_del_mes = NULL;

        WITH h AS (
            SELECT fecha, ROW_NUMBER() OVER (PARTITION BY anio, mes ORDER BY fecha) AS n
            FROM   gold.dim_fecha WHERE es_dia_habil = 1)
        UPDATE d SET d.dia_habil_del_mes = h.n
        FROM   gold.dim_fecha d JOIN h ON h.fecha = d.fecha;

        WITH t AS (
            SELECT anio, mes, COUNT(*) AS n
            FROM   gold.dim_fecha WHERE es_dia_habil = 1 GROUP BY anio, mes)
        UPDATE d SET d.dias_habiles_mes = t.n
        FROM   gold.dim_fecha d JOIN t ON t.anio = d.anio AND t.mes = d.mes;

        -- A predicted payment date on a Sunday or a holiday moves to the next business day.
        UPDATE d
        SET    d.siguiente_dia_habil = (SELECT MIN(h.fecha) FROM gold.dim_fecha h
                                        WHERE h.fecha >= d.fecha AND h.es_dia_habil = 1)
        FROM   gold.dim_fecha d;
        EXEC control.log_step @proc, @step, @t;

        EXEC control.log_step @proc, 'total', @t0;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        SELECT @err = ERROR_MESSAGE(), @line = ERROR_LINE();
        EXEC control.log_step @proc, @step, @t, NULL, @err, @line;
        THROW;
    END CATCH
END;
GO

-- ----------------------------------------------------------------------------
-- gold.load_dim_cliente: SCD1 by UPDATE + INSERT, never TRUNCATE (the table has
-- incoming foreign keys). Customers gone from SAP are kept.
-- ----------------------------------------------------------------------------
IF OBJECT_ID('gold.load_dim_cliente', 'P') IS NOT NULL
    DROP PROCEDURE gold.load_dim_cliente;
GO

CREATE PROCEDURE gold.load_dim_cliente
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @proc VARCHAR(128) = 'gold.load_dim_cliente',
            @step VARCHAR(128) = 'start',
            @t0   DATETIME2(0) = SYSDATETIME(),
            @t    DATETIME2(0) = SYSDATETIME(),
            @err  VARCHAR(4000),
            @line INT;
    DECLARE @rows_updated INT, @rows_inserted INT;

    BEGIN TRY
        SET @step = 'gold.dim_cliente source'; SET @t = SYSDATETIME();

        IF OBJECT_ID('tempdb..#fuente_cliente') IS NOT NULL
            DROP TABLE #fuente_cliente;

        SELECT
            k.cliente_id,
            k.rfc,
            CASE
                -- Payment-gateway clearing accounts that move money: first.
                WHEN k.nombre LIKE 'KUSHKY%' OR k.nombre LIKE 'CONEKTA%'
                    THEN 'TRANSITORIA'
                -- Before the RFC rules: these accounts span every RFC case. OPENPAY is an
                -- exact match because a real customer is named OPENPAY SAPI DE CV.
                WHEN k.nombre = 'OPENPAY INGRESOS TRANSITORIA'
                     OR k.nombre LIKE 'MERCADO LIBRE%' OR k.nombre LIKE 'MERCADO PAGO%'
                     OR k.nombre LIKE '%AMAZON%' OR k.nombre LIKE 'CLAROSHOP%'
                    THEN 'MARKETPLACE'
                WHEN kk.etiqueta_credito = 'FILIAL' THEN 'FILIAL'
                WHEN k.rfc IS NULL THEN 'SIN_RFC'
                WHEN k.rfc IN ('XAXX010101000', 'XEXX010101000') THEN 'GENERICO'
                ELSE 'PADRE'
            END AS tipo_cliente,
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

        SET @step = 'gold.dim_cliente update'; SET @t = SYSDATETIME();
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
        EXEC control.log_step @proc, @step, @t, @rows_updated;

        SET @step = 'gold.dim_cliente insert'; SET @t = SYSDATETIME();
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
        EXEC control.log_step @proc, @step, @t, @rows_inserted;

        DROP TABLE #fuente_cliente;

        EXEC control.log_step @proc, 'total', @t0;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        SELECT @err = ERROR_MESSAGE(), @line = ERROR_LINE();
        EXEC control.log_step @proc, @step, @t, NULL, @err, @line;
        THROW;
    END CATCH
END;
GO

-- ----------------------------------------------------------------------------
-- gold.load_dim_cliente_comercial: SCD2 in explicit steps
-- ----------------------------------------------------------------------------
IF OBJECT_ID('gold.load_dim_cliente_comercial', 'P') IS NOT NULL
    DROP PROCEDURE gold.load_dim_cliente_comercial;
GO

CREATE PROCEDURE gold.load_dim_cliente_comercial
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @proc VARCHAR(128) = 'gold.load_dim_cliente_comercial',
            @step VARCHAR(128) = 'start',
            @t0   DATETIME2(0) = SYSDATETIME(),
            @t    DATETIME2(0) = SYSDATETIME(),
            @rows INT,
            @err  VARCHAR(4000),
            @line INT;
    DECLARE @hoy DATE = CAST(GETDATE() AS DATE);

    BEGIN TRY
        -- 1. Representative channel per customer: status priority, then lowest channel.
        SET @step = 'gold.dim_cliente_comercial representative'; SET @t = SYSDATETIME();

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

        -- 2. Close the current version where the attribute hash changed.
        SET @step = 'gold.dim_cliente_comercial close changed'; SET @t = SYSDATETIME();
        UPDATE d
        SET d.es_vigente = 0,
            d.fecha_fin_vigencia = DATEADD(DAY, -1, @hoy)
        FROM gold.dim_cliente_comercial d
        JOIN #representante r ON r.cliente_id = d.cliente_id
        WHERE d.es_vigente = 1
          AND d.hash_atributos <> r.hash_atributos;
        SET @rows = @@ROWCOUNT;
        EXEC control.log_step @proc, @step, @t, @rows;

        -- 3. New version for new customers and for the ones closed in step 2.
        SET @step = 'gold.dim_cliente_comercial insert versions'; SET @t = SYSDATETIME();
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

        SET @rows = @@ROWCOUNT;
        EXEC control.log_step @proc, @step, @t, @rows;

        DROP TABLE #representante;

        EXEC control.log_step @proc, 'total', @t0;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        SELECT @err = ERROR_MESSAGE(), @line = ERROR_LINE();
        EXEC control.log_step @proc, @step, @t, NULL, @err, @line;
        THROW;
    END CATCH
END;
GO

-- ----------------------------------------------------------------------------
-- gold.load_dim_cliente_credito: SCD2. Needs gold.dim_cliente_comercial loaded
-- first: the analyst and collector are taken on the channel it chose.
-- ----------------------------------------------------------------------------
IF OBJECT_ID('gold.load_dim_cliente_credito', 'P') IS NOT NULL
    DROP PROCEDURE gold.load_dim_cliente_credito;
GO

CREATE PROCEDURE gold.load_dim_cliente_credito
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @proc VARCHAR(128) = 'gold.load_dim_cliente_credito',
            @step VARCHAR(128) = 'start',
            @t0   DATETIME2(0) = SYSDATETIME(),
            @t    DATETIME2(0) = SYSDATETIME(),
            @rows INT,
            @err  VARCHAR(4000),
            @line INT;
    DECLARE @hoy DATE = CAST(GETDATE() AS DATE);

    BEGIN TRY
        -- 1. Credit analyst (E1) and collector (CC) on the representative channel,
        --    lowest PARZA when a role is assigned twice.
        SET @step = 'gold.dim_cliente_credito source'; SET @t = SYSDATETIME();

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

        -- 2. Close the current version where the attribute hash changed.
        SET @step = 'gold.dim_cliente_credito close changed'; SET @t = SYSDATETIME();
        UPDATE d
        SET d.es_vigente = 0,
            d.fecha_fin_vigencia = DATEADD(DAY, -1, @hoy)
        FROM gold.dim_cliente_credito d
        JOIN #representante_credito r ON r.cliente_id = d.cliente_id
        WHERE d.es_vigente = 1
          AND d.hash_atributos <> r.hash_atributos;
        SET @rows = @@ROWCOUNT;
        EXEC control.log_step @proc, @step, @t, @rows;

        -- 3. New version for new customers and for the ones closed in step 2.
        SET @step = 'gold.dim_cliente_credito insert versions'; SET @t = SYSDATETIME();
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

        SET @rows = @@ROWCOUNT;
        EXEC control.log_step @proc, @step, @t, @rows;

        DROP TABLE #representante_credito;

        EXEC control.log_step @proc, 'total', @t0;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        SELECT @err = ERROR_MESSAGE(), @line = ERROR_LINE();
        EXEC control.log_step @proc, @step, @t, NULL, @err, @line;
        THROW;
    END CATCH
END;
GO

-- ----------------------------------------------------------------------------
-- gold.load_fact_saldo_cartera: today's snapshot of each customer's open balance.
-- Re-runnable the same day: today's snapshot is replaced.
-- ----------------------------------------------------------------------------
IF OBJECT_ID('gold.load_fact_saldo_cartera', 'P') IS NOT NULL
    DROP PROCEDURE gold.load_fact_saldo_cartera;
GO

CREATE PROCEDURE gold.load_fact_saldo_cartera
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @proc VARCHAR(128) = 'gold.load_fact_saldo_cartera',
            @step VARCHAR(128) = 'start',
            @t0   DATETIME2(0) = SYSDATETIME(),
            @t    DATETIME2(0) = SYSDATETIME(),
            @rows INT,
            @err  VARCHAR(4000),
            @line INT;
    DECLARE @hoy DATE = CAST(GETDATE() AS DATE);

    BEGIN TRY
        SET @step = 'gold.fact_saldo_cartera delete today'; SET @t = SYSDATETIME();
        DELETE FROM gold.fact_saldo_cartera WHERE fecha_snapshot = @hoy;
        SET @rows = @@ROWCOUNT;
        EXEC control.log_step @proc, @step, @t, @rows;

        -- Amounts signed by debe_haber; SA documents are not customer documents.
        -- 1-16 days overdue is a grace period; overdue buckets are 17-31 / 32-180 / 181+.
        SET @step = 'gold.fact_saldo_cartera aggregate'; SET @t = SYSDATETIME();

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

        SET @step = 'gold.fact_saldo_cartera insert'; SET @t = SYSDATETIME();
        INSERT INTO gold.fact_saldo_cartera (
            cliente_id, fecha_snapshot,
            saldo_total, saldo_no_vencido, saldo_1_16, saldo_vencido, num_documentos_abiertos, dias_vencido_max,
            saldo_17_31, saldo_32_180, saldo_181_mas,
            documentos_con_reclamacion, nivel_reclamacion_max,
            id_cliente_comercial, id_cliente_credito
        )
        SELECT
            s.cliente_id, @hoy,
            s.saldo_total, s.saldo_no_vencido, s.saldo_1_16, s.saldo_vencido, s.num_documentos_abiertos, s.dias_vencido_max,
            s.saldo_17_31, s.saldo_32_180, s.saldo_181_mas,
            s.documentos_con_reclamacion, s.nivel_reclamacion_max,
            dc.id_surrogate, dcr.id_surrogate
        FROM #saldo_cliente s
        LEFT JOIN gold.dim_cliente_comercial dc
            ON dc.cliente_id = s.cliente_id
            AND @hoy BETWEEN dc.fecha_inicio_vigencia AND ISNULL(dc.fecha_fin_vigencia, '99991231')
        LEFT JOIN gold.dim_cliente_credito dcr
            ON dcr.cliente_id = s.cliente_id
            AND @hoy BETWEEN dcr.fecha_inicio_vigencia AND ISNULL(dcr.fecha_fin_vigencia, '99991231');
        SET @rows = @@ROWCOUNT;
        EXEC control.log_step @proc, @step, @t, @rows;

        DROP TABLE #saldo_cliente;

        EXEC control.log_step @proc, 'total', @t0;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        SELECT @err = ERROR_MESSAGE(), @line = ERROR_LINE();
        EXEC control.log_step @proc, @step, @t, NULL, @err, @line;
        THROW;
    END CATCH
END;
GO

-- ----------------------------------------------------------------------------
-- gold.load_fact_pagos_compensados: legacy raw deposits, merge by clearing date
-- ----------------------------------------------------------------------------
IF OBJECT_ID('gold.load_fact_pagos_compensados', 'P') IS NOT NULL
    DROP PROCEDURE gold.load_fact_pagos_compensados;
GO

CREATE PROCEDURE gold.load_fact_pagos_compensados
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @proc VARCHAR(128) = 'gold.load_fact_pagos_compensados',
            @step VARCHAR(128) = 'start',
            @t0   DATETIME2(0) = SYSDATETIME(),
            @t    DATETIME2(0) = SYSDATETIME(),
            @rows INT,
            @err  VARCHAR(4000),
            @line INT;

    BEGIN TRY
        SET @step = 'gold.fact_pagos_compensados merge'; SET @t = SYSDATETIME();

        DECLARE @mes_anterior_inicio DATE = DATEADD(MONTH, DATEDIFF(MONTH, 0, GETDATE()) - 1, 0);

        MERGE gold.fact_pagos_compensados AS tgt
        USING (
            SELECT
                b.sociedad, b.cliente_id, b.ejercicio, b.documento_id, b.posicion,
                b.fecha_documento, b.fecha_contabilizacion, b.fecha_compensacion, b.monto_moneda_local,
                b.documento_compensacion, b.ejercicio_compensacion
            FROM silver.sap_bsad b
            WHERE b.clase_documento = 'DZ'
              -- Text 'Asignación Aut. Deposito' or bank references BB%; every other text
              -- (bounced checks, unreviewed references) stays out.
              AND (b.sgtxt = 'Asignación Aut. Deposito' OR b.sgtxt LIKE 'BB%')
              AND b.debe_haber <> 'S'          -- not the child document's mirror line
              AND b.monto_moneda_local > 0     -- not a $0 residual
              AND b.fecha_compensacion >= @mes_anterior_inicio
              -- Not a self-canceling internal pair: an H line of a document cleared
              -- against an S line of the same document and amount.
              AND NOT (
                  b.documento_compensacion = b.documento_id
                  AND EXISTS (
                      SELECT 1 FROM silver.sap_bsad b2
                      WHERE b2.sociedad = b.sociedad AND b2.cliente_id = b.cliente_id
                        AND b2.ejercicio = b.ejercicio AND b2.documento_id = b.documento_id
                        AND b2.posicion <> b.posicion
                        AND b2.clase_documento = 'DZ' AND b2.debe_haber = 'S'
                        AND b2.monto_moneda_local = b.monto_moneda_local
                  )
              )
        ) AS src
        ON  tgt.sociedad = src.sociedad
        AND tgt.cliente_id = src.cliente_id
        AND tgt.ejercicio = src.ejercicio
        AND tgt.documento_id = src.documento_id
        AND tgt.posicion = src.posicion

        WHEN MATCHED THEN UPDATE SET
            tgt.fecha_contabilizacion = src.fecha_contabilizacion,
            tgt.fecha_compensacion = src.fecha_compensacion,
            tgt.monto_moneda_local = src.monto_moneda_local,
            tgt.documento_compensacion = src.documento_compensacion,
            tgt.ejercicio_compensacion = src.ejercicio_compensacion,
            tgt.fecha_carga = GETDATE()

        WHEN NOT MATCHED THEN
        INSERT (sociedad, cliente_id, ejercicio, documento_id, posicion,
                fecha_documento, fecha_contabilizacion, fecha_compensacion, monto_moneda_local,
                documento_compensacion, ejercicio_compensacion)
        VALUES (src.sociedad, src.cliente_id, src.ejercicio, src.documento_id, src.posicion,
                src.fecha_documento, src.fecha_contabilizacion, src.fecha_compensacion, src.monto_moneda_local,
                src.documento_compensacion, src.ejercicio_compensacion);

        SET @rows = @@ROWCOUNT;
        EXEC control.log_step @proc, @step, @t, @rows;

        EXEC control.log_step @proc, 'total', @t0;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        SELECT @err = ERROR_MESSAGE(), @line = ERROR_LINE();
        EXEC control.log_step @proc, @step, @t, NULL, @err, @line;
        THROW;
    END CATCH
END;
GO

-- ----------------------------------------------------------------------------
-- gold.load_fact_facturas_compensadas: legacy cleared invoices, merge by clearing date
-- ----------------------------------------------------------------------------
IF OBJECT_ID('gold.load_fact_facturas_compensadas', 'P') IS NOT NULL
    DROP PROCEDURE gold.load_fact_facturas_compensadas;
GO

CREATE PROCEDURE gold.load_fact_facturas_compensadas
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @proc VARCHAR(128) = 'gold.load_fact_facturas_compensadas',
            @step VARCHAR(128) = 'start',
            @t0   DATETIME2(0) = SYSDATETIME(),
            @t    DATETIME2(0) = SYSDATETIME(),
            @rows INT,
            @err  VARCHAR(4000),
            @line INT;

    BEGIN TRY
        SET @step = 'gold.fact_facturas_compensadas merge'; SET @t = SYSDATETIME();

        DECLARE @mes_anterior_inicio DATE = DATEADD(MONTH, DATEDIFF(MONTH, 0, GETDATE()) - 1, 0);

        MERGE gold.fact_facturas_compensadas AS tgt
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

        SET @rows = @@ROWCOUNT;
        EXEC control.log_step @proc, @step, @t, @rows;

        EXEC control.log_step @proc, 'total', @t0;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        SELECT @err = ERROR_MESSAGE(), @line = ERROR_LINE();
        EXEC control.log_step @proc, @step, @t, NULL, @err, @line;
        THROW;
    END CATCH
END;
GO

-- ----------------------------------------------------------------------------
-- gold.load_dim_empleado: SCD1 by UPDATE + INSERT. Employees who left are kept.
-- ----------------------------------------------------------------------------
IF OBJECT_ID('gold.load_dim_empleado', 'P') IS NOT NULL
    DROP PROCEDURE gold.load_dim_empleado;
GO

CREATE PROCEDURE gold.load_dim_empleado
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @proc VARCHAR(128) = 'gold.load_dim_empleado',
            @step VARCHAR(128) = 'start',
            @t0   DATETIME2(0) = SYSDATETIME(),
            @t    DATETIME2(0) = SYSDATETIME(),
            @err  VARCHAR(4000),
            @line INT;
    DECLARE @rows_updated INT, @rows_inserted INT;

    BEGIN TRY
        SET @step = 'gold.dim_empleado update'; SET @t = SYSDATETIME();
        UPDATE d
        SET d.nombre = f.nombre, d.fecha_actualizacion = GETDATE()
        FROM gold.dim_empleado d
        JOIN silver.sap_pa0001 f ON f.id_empleado = d.id_empleado;
        SET @rows_updated = @@ROWCOUNT;
        EXEC control.log_step @proc, @step, @t, @rows_updated;

        SET @step = 'gold.dim_empleado insert'; SET @t = SYSDATETIME();
        INSERT INTO gold.dim_empleado (id_empleado, nombre)
        SELECT f.id_empleado, f.nombre
        FROM silver.sap_pa0001 f
        WHERE NOT EXISTS (
            SELECT 1 FROM gold.dim_empleado d WHERE d.id_empleado = f.id_empleado
        );
        SET @rows_inserted = @@ROWCOUNT;
        EXEC control.log_step @proc, @step, @t, @rows_inserted;

        EXEC control.log_step @proc, 'total', @t0;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        SELECT @err = ERROR_MESSAGE(), @line = ERROR_LINE();
        EXEC control.log_step @proc, @step, @t, NULL, @err, @line;
        THROW;
    END CATCH
END;
GO

-- ============================================================================
-- Payment application model
-- Order (gold.load_gold keeps it): load_fact_pagos -> load_fact_facturas ->
-- load_fact_aplicacion_pagos -> load_fact_facturas_pago_efectivo ->
-- load_fact_pagos_sin_aplicacion.
-- @fecha_desde NULL = first day of the previous month; @fecha_hasta NULL = no
-- upper bound. The window is on the payment's clearing date.
-- OPTION (RECOMPILE) on windowed statements: the procedure compiles with the
-- value it receives, and a NULL @fecha_desde plans for one row.
-- Delete and insert run in one transaction (XACT_ABORT ON, ROLLBACK in CATCH),
-- so a failure never leaves the window empty and queryable.
-- Open items (bsid) are a snapshot, reloaded whole on every run.
-- Load history with backfill_fact_aplicacion_pagos.sql: one window from 2022
-- fills the 2 GB log.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- gold.load_fact_pagos
-- ----------------------------------------------------------------------------
IF OBJECT_ID('gold.load_fact_pagos', 'P') IS NOT NULL
    DROP PROCEDURE gold.load_fact_pagos;
GO

CREATE PROCEDURE gold.load_fact_pagos
    @fecha_desde DATE = NULL,
    @fecha_hasta DATE = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @proc VARCHAR(128) = 'gold.load_fact_pagos',
            @step VARCHAR(128) = 'start',
            @t0   DATETIME2(0) = SYSDATETIME(),
            @t    DATETIME2(0) = SYSDATETIME(),
            @rows INT,
            @err  VARCHAR(4000),
            @line INT;
    DECLARE @n INT, @lote INT, @recomp INT, @n_abie INT, @descomp INT, @n_rev INT, @n_rev_fuera INT;

    IF @fecha_desde IS NULL
        SET @fecha_desde = DATEADD(MONTH, DATEDIFF(MONTH, 0, GETDATE()) - 1, 0);

    BEGIN TRY
        SET @step = 'window from ' + CONVERT(VARCHAR(10), @fecha_desde, 120)
                  + COALESCE(' to ' + CONVERT(VARCHAR(10), @fecha_hasta, 120), ', no upper bound');
        EXEC control.log_step @proc, @step, @t0;

        BEGIN TRANSACTION;

        -- The incoming set is materialized first: it decides what to delete and what to insert.
        SET @step = 'read cleared payments'; SET @t = SYSDATETIME();
        IF OBJECT_ID('tempdb..#pag') IS NOT NULL DROP TABLE #pag;
        SELECT
            b.sociedad, b.cliente_id, b.ejercicio, b.documento_id, b.posicion,
            b.documento_compensacion, b.ejercicio_compensacion,
            b.fecha_documento, b.fecha_contabilizacion, b.fecha_compensacion,
            -- bsad amounts are unsigned
            CASE WHEN b.debe_haber = 'H' THEN b.monto_moneda_local
                 ELSE -1 * b.monto_moneda_local END AS monto,
            b.sgtxt AS texto, b.clave_contabilizacion,
            cta.cuenta_mayor,
            dcc.id_surrogate AS cliente_comercial_sk, dck.id_surrogate AS cliente_credito_sk
        INTO #pag
        FROM silver.sap_bsad b
        -- Cash account of the same document. One per document: MIN() only unpacks it.
        LEFT JOIN (SELECT documento_id, ejercicio, MIN(cuenta_mayor) AS cuenta_mayor
                   FROM (SELECT documento_id, ejercicio, cuenta_mayor FROM silver.sap_bsas WHERE clase_documento = 'DZ'
                         UNION ALL
                         SELECT documento_id, ejercicio, cuenta_mayor FROM silver.sap_bsis WHERE clase_documento = 'DZ') e
                   GROUP BY documento_id, ejercicio) cta
               ON cta.documento_id = b.documento_id AND cta.ejercicio = b.ejercicio
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
          -- No N'' prefix: sgtxt is VARCHAR with a binary collation and a Unicode literal
          -- converts the column (the plan went from 2 s to 150 s).
          -- Key 11 (automatic deposit) counts with empty text only; with another text it
          -- was a bounced check. Other keys still need the text, or keys 08/07/17 and
          -- re-applied 15s get in.
          AND (b.sgtxt = 'Asignación Aut. Deposito' OR (b.clave_contabilizacion = '11' AND b.sgtxt IS NULL))
          AND b.fecha_compensacion >= @fecha_desde
          AND (@fecha_hasta IS NULL OR b.fecha_compensacion < @fecha_hasta)
          AND b.cliente_id IN (
                SELECT c1.cliente_id FROM gold.dim_cliente_comercial c1
                WHERE c1.estatus_comercial <> 'FUERA_DE_ALCANCE'
                  AND c1.canal_distribucion IN (10, 40, 60))
          -- Not a line of a child document: its key 15 re-applies money already counted in
          -- the key 11. Keep the alias b.: unqualified, the column binds to the inner table
          -- and the condition is always true.
          AND NOT EXISTS (
                SELECT 1 FROM silver.sap_bsad h
                WHERE h.mandante = '400' AND h.clase_documento = 'DZ'
                  AND h.clave_contabilizacion = '11'
                  AND h.documento_compensacion = b.documento_id)
          -- Clearing reset: the line is back in bsid, bsid wins.
          AND NOT EXISTS (
                SELECT 1 FROM silver.sap_bsid i
                WHERE i.mandante = b.mandante AND i.sociedad = b.sociedad
                  AND i.cliente_id = b.cliente_id AND i.ejercicio = b.ejercicio
                  AND i.documento_id = b.documento_id AND i.posicion = b.posicion)
        OPTION (RECOMPILE);
        SET @rows = @@ROWCOUNT;
        CREATE UNIQUE CLUSTERED INDEX ix_pag ON #pag(sociedad, cliente_id, ejercicio, documento_id, posicion);
        EXEC control.log_step @proc, @step, @t, @rows;

        -- Reversals (FB08) of a counted line are subtracted, line by line: the mirror of a
        -- counted line (same customer and position, opposite amount) not already in #pag.
        -- By line because a reversal mirrors every line of the original, counted or not.
        -- indicador_reversa = '2' is the reversal side. The join starts from #pag because
        -- bkpf has no index on documento_reversa.
        SET @step = 'add reversals of counted lines'; SET @t = SYSDATETIME();
        INSERT INTO #pag (
            sociedad, cliente_id, ejercicio, documento_id, posicion,
            documento_compensacion, ejercicio_compensacion,
            fecha_documento, fecha_contabilizacion, fecha_compensacion,
            monto, texto, clave_contabilizacion, cuenta_mayor,
            cliente_comercial_sk, cliente_credito_sk)
        SELECT
            b.sociedad, b.cliente_id, b.ejercicio, b.documento_id, b.posicion,
            b.documento_compensacion, b.ejercicio_compensacion,
            b.fecha_documento, b.fecha_contabilizacion, b.fecha_compensacion,
            CASE WHEN b.debe_haber = 'H' THEN b.monto_moneda_local
                 ELSE -1 * b.monto_moneda_local END,
            b.sgtxt, b.clave_contabilizacion,
            cta.cuenta_mayor,
            dcc.id_surrogate, dck.id_surrogate
        FROM #pag o
        JOIN silver.sap_bkpf k
               ON  k.mandante = '400' AND k.sociedad = o.sociedad
               AND k.ejercicio_reversa = o.ejercicio AND k.documento_reversa = o.documento_id
               AND k.indicador_reversa = '2'
        JOIN silver.sap_bsad b
               ON  b.mandante = '400' AND b.sociedad = o.sociedad AND b.cliente_id = o.cliente_id
               AND b.ejercicio = k.ejercicio AND b.documento_id = k.documento_id
               AND b.posicion = o.posicion
               AND b.clase_documento = 'DZ'
               AND o.monto = CASE WHEN b.debe_haber = 'H' THEN -1 * b.monto_moneda_local
                                  ELSE b.monto_moneda_local END
        LEFT JOIN (SELECT documento_id, ejercicio, MIN(cuenta_mayor) AS cuenta_mayor
                   FROM (SELECT documento_id, ejercicio, cuenta_mayor FROM silver.sap_bsas WHERE clase_documento = 'DZ'
                         UNION ALL
                         SELECT documento_id, ejercicio, cuenta_mayor FROM silver.sap_bsis WHERE clase_documento = 'DZ') e
                   GROUP BY documento_id, ejercicio) cta
               ON cta.documento_id = b.documento_id AND cta.ejercicio = b.ejercicio
        LEFT JOIN gold.dim_cliente_comercial dcc
               ON dcc.cliente_id = b.cliente_id
              AND b.fecha_contabilizacion >= dcc.fecha_inicio_vigencia
              AND (dcc.fecha_fin_vigencia IS NULL OR b.fecha_contabilizacion <= dcc.fecha_fin_vigencia)
        LEFT JOIN gold.dim_cliente_credito dck
               ON dck.cliente_id = b.cliente_id
              AND b.fecha_contabilizacion >= dck.fecha_inicio_vigencia
              AND (dck.fecha_fin_vigencia IS NULL OR b.fecha_contabilizacion <= dck.fecha_fin_vigencia)
        WHERE NOT EXISTS (SELECT 1 FROM #pag x
                          WHERE x.sociedad = b.sociedad AND x.cliente_id = b.cliente_id
                            AND x.ejercicio = b.ejercicio AND x.documento_id = b.documento_id
                            AND x.posicion = b.posicion)
          AND NOT EXISTS (SELECT 1 FROM silver.sap_bsid i
                          WHERE i.mandante = b.mandante AND i.sociedad = b.sociedad
                            AND i.cliente_id = b.cliente_id AND i.ejercicio = b.ejercicio
                            AND i.documento_id = b.documento_id AND i.posicion = b.posicion)
        OPTION (RECOMPILE);
        SET @n_rev = @@ROWCOUNT;
        EXEC control.log_step @proc, @step, @t, @n_rev;

        -- A reversal already in #pag by its text, whose original line was not counted,
        -- subtracts money never added: it leaves. Original and reversal share the
        -- clearing date, so both fall in the same window.
        SET @step = 'remove reversals of uncounted lines'; SET @t = SYSDATETIME();
        DELETE x
        FROM   #pag x
        JOIN   silver.sap_bkpf k
               ON  k.mandante = '400' AND k.sociedad = x.sociedad
               AND k.ejercicio = x.ejercicio AND k.documento_id = x.documento_id
               AND k.indicador_reversa = '2'
        WHERE  NOT EXISTS (SELECT 1 FROM #pag o
                           WHERE o.sociedad = x.sociedad AND o.cliente_id = x.cliente_id
                             AND o.ejercicio = k.ejercicio_reversa AND o.documento_id = k.documento_reversa
                             AND o.posicion = x.posicion AND o.monto = -1 * x.monto)
        OPTION (RECOMPILE);
        SET @n_rev_fuera = @@ROWCOUNT;
        EXEC control.log_step @proc, @step, @t, @n_rev_fuera;

        -- Open payments (bsid): same rule, a snapshot of today. fecha_compensacion is
        -- written as NULL because the open-payment delete filters on IS NULL.
        SET @step = 'read open payments'; SET @t = SYSDATETIME();
        IF OBJECT_ID('tempdb..#abi') IS NOT NULL DROP TABLE #abi;
        SELECT
            b.sociedad, b.cliente_id, b.ejercicio, b.documento_id, b.posicion,
            CAST(NULL AS VARCHAR(10)) AS documento_compensacion, CAST(NULL AS INT) AS ejercicio_compensacion,
            b.fecha_documento, b.fecha_contabilizacion, CAST(NULL AS DATE) AS fecha_compensacion,
            CASE WHEN b.debe_haber = 'H' THEN b.monto_moneda_local
                 ELSE -1 * b.monto_moneda_local END AS monto,
            b.sgtxt AS texto, b.clave_contabilizacion,
            cta.cuenta_mayor,
            dcc.id_surrogate AS cliente_comercial_sk, dck.id_surrogate AS cliente_credito_sk
        INTO #abi
        FROM silver.sap_bsid b
        LEFT JOIN (SELECT documento_id, ejercicio, MIN(cuenta_mayor) AS cuenta_mayor
                   FROM (SELECT documento_id, ejercicio, cuenta_mayor FROM silver.sap_bsas WHERE clase_documento = 'DZ'
                         UNION ALL
                         SELECT documento_id, ejercicio, cuenta_mayor FROM silver.sap_bsis WHERE clase_documento = 'DZ') e
                   GROUP BY documento_id, ejercicio) cta
               ON cta.documento_id = b.documento_id AND cta.ejercicio = b.ejercicio
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
          AND (b.sgtxt = 'Asignación Aut. Deposito' OR (b.clave_contabilizacion = '11' AND b.sgtxt IS NULL))
          AND b.cliente_id IN (
                SELECT c1.cliente_id FROM gold.dim_cliente_comercial c1
                WHERE c1.estatus_comercial <> 'FUERA_DE_ALCANCE'
                  AND c1.canal_distribucion IN (10, 40, 60))
          -- Open lines of a child document stay out too.
          AND NOT EXISTS (
                SELECT 1 FROM silver.sap_bsad h
                WHERE h.mandante = '400' AND h.clase_documento = 'DZ'
                  AND h.clave_contabilizacion = '11'
                  AND h.documento_compensacion = b.documento_id)
        OPTION (RECOMPILE);
        SET @rows = @@ROWCOUNT;
        CREATE UNIQUE CLUSTERED INDEX ix_abi ON #abi(sociedad, cliente_id, ejercicio, documento_id, posicion);
        EXEC control.log_step @proc, @step, @t, @rows;

        SET @step = 'delete window'; SET @t = SYSDATETIME(); SET @rows = 0;
        SET @lote = 1;
        WHILE @lote > 0
        BEGIN
            DELETE TOP (50000) FROM gold.fact_pagos
            WHERE fecha_compensacion >= @fecha_desde
              AND (@fecha_hasta IS NULL OR fecha_compensacion < @fecha_hasta)
              OPTION (RECOMPILE);
            SET @lote = @@ROWCOUNT;
            SET @rows = @rows + @lote;
        END
        EXEC control.log_step @proc, @step, @t, @rows;

        SET @step = 'delete open payments'; SET @t = SYSDATETIME();
        DELETE FROM gold.fact_pagos WHERE fecha_compensacion IS NULL;
        SET @rows = @@ROWCOUNT;
        EXEC control.log_step @proc, @step, @t, @rows;

        -- A re-cleared payment keeps its old stored date, outside the window: delete by
        -- key against what comes in.
        SET @step = 'delete re-cleared by key'; SET @t = SYSDATETIME();
        DELETE g
        FROM   gold.fact_pagos g
        JOIN   #pag c ON c.sociedad = g.sociedad AND c.cliente_id = g.cliente_id
                     AND c.ejercicio = g.ejercicio AND c.documento_id = g.documento_id
                     AND c.posicion = g.posicion
        OPTION (RECOMPILE);
        SET @recomp = @@ROWCOUNT;
        EXEC control.log_step @proc, @step, @t, @recomp;

        -- The opposite: stored as cleared, open today.
        SET @step = 'delete no longer cleared by key'; SET @t = SYSDATETIME();
        DELETE g
        FROM   gold.fact_pagos g
        JOIN   #abi c ON c.sociedad = g.sociedad AND c.cliente_id = g.cliente_id
                     AND c.ejercicio = g.ejercicio AND c.documento_id = g.documento_id
                     AND c.posicion = g.posicion;
        SET @descomp = @@ROWCOUNT;
        EXEC control.log_step @proc, @step, @t, @descomp;

        SET @step = 'insert cleared'; SET @t = SYSDATETIME();
        INSERT INTO gold.fact_pagos (
            sociedad, cliente_id, ejercicio, documento_id, posicion,
            documento_compensacion, ejercicio_compensacion,
            fecha_documento, fecha_contabilizacion, fecha_compensacion,
            monto, texto, clave_contabilizacion, cuenta_mayor,
            cliente_comercial_sk, cliente_credito_sk)
        SELECT sociedad, cliente_id, ejercicio, documento_id, posicion,
               documento_compensacion, ejercicio_compensacion,
               fecha_documento, fecha_contabilizacion, fecha_compensacion,
               monto, texto, clave_contabilizacion, cuenta_mayor,
               cliente_comercial_sk, cliente_credito_sk
        FROM #pag;
        SET @n = @@ROWCOUNT;
        EXEC control.log_step @proc, @step, @t, @n;

        SET @step = 'insert open'; SET @t = SYSDATETIME();
        INSERT INTO gold.fact_pagos (
            sociedad, cliente_id, ejercicio, documento_id, posicion,
            documento_compensacion, ejercicio_compensacion,
            fecha_documento, fecha_contabilizacion, fecha_compensacion,
            monto, texto, clave_contabilizacion, cuenta_mayor,
            cliente_comercial_sk, cliente_credito_sk)
        SELECT sociedad, cliente_id, ejercicio, documento_id, posicion,
               documento_compensacion, ejercicio_compensacion,
               fecha_documento, fecha_contabilizacion, fecha_compensacion,
               monto, texto, clave_contabilizacion, cuenta_mayor,
               cliente_comercial_sk, cliente_credito_sk
        FROM #abi;
        SET @n_abie = @@ROWCOUNT;
        EXEC control.log_step @proc, @step, @t, @n_abie;

        COMMIT TRANSACTION;

        EXEC control.log_step @proc, 'total', @t0;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        SELECT @err = ERROR_MESSAGE(), @line = ERROR_LINE();
        EXEC control.log_step @proc, @step, @t, NULL, @err, @line;
        THROW;
    END CATCH
END;
GO

-- ----------------------------------------------------------------------------
-- gold.load_fact_facturas: cleared invoices by window, open invoices whole
-- ----------------------------------------------------------------------------
IF OBJECT_ID('gold.load_fact_facturas', 'P') IS NOT NULL
    DROP PROCEDURE gold.load_fact_facturas;
GO

CREATE PROCEDURE gold.load_fact_facturas
    @fecha_desde DATE = NULL,
    @fecha_hasta DATE = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @proc VARCHAR(128) = 'gold.load_fact_facturas',
            @step VARCHAR(128) = 'start',
            @t0   DATETIME2(0) = SYSDATETIME(),
            @t    DATETIME2(0) = SYSDATETIME(),
            @rows INT,
            @err  VARCHAR(4000),
            @line INT;
    DECLARE @n_comp INT, @n_abie INT, @lote INT, @recomp INT;

    IF @fecha_desde IS NULL
        SET @fecha_desde = DATEADD(MONTH, DATEDIFF(MONTH, 0, GETDATE()) - 1, 0);

    -- @fecha_hasta is ignored for cleared invoices: a payment of the window can reach,
    -- through the second hop, an invoice cleared later, and a ceiling cuts those chains.
    BEGIN TRY
        BEGIN TRANSACTION;

        SET @step = 'read cleared invoices'; SET @t = SYSDATETIME();
        IF OBJECT_ID('tempdb..#comp') IS NOT NULL DROP TABLE #comp;
        SELECT b.sociedad, b.cliente_id, b.ejercicio, b.documento_id, b.posicion,
               b.documento_compensacion, b.ejercicio_compensacion, b.clase_documento,
               b.fecha_documento, b.fecha_vencimiento, b.fecha_contabilizacion, b.fecha_compensacion,
               b.monto_moneda_local AS monto, b.clave_contabilizacion,
               dcc.id_surrogate AS cliente_comercial_sk, dck.id_surrogate AS cliente_credito_sk
        INTO   #comp
        FROM   silver.sap_bsad b
        LEFT JOIN gold.dim_cliente_comercial dcc
               ON dcc.cliente_id = b.cliente_id
              AND b.fecha_contabilizacion >= dcc.fecha_inicio_vigencia
              AND (dcc.fecha_fin_vigencia IS NULL OR b.fecha_contabilizacion <= dcc.fecha_fin_vigencia)
        LEFT JOIN gold.dim_cliente_credito dck
               ON dck.cliente_id = b.cliente_id
              AND b.fecha_contabilizacion >= dck.fecha_inicio_vigencia
              AND (dck.fecha_fin_vigencia IS NULL OR b.fecha_contabilizacion <= dck.fecha_fin_vigencia)
        WHERE  b.mandante = '400'
          AND  b.debe_haber = 'S'
          AND (b.clase_documento LIKE 'F%' OR b.clase_documento = 'D1')
          AND  b.fecha_compensacion >= @fecha_desde
          AND  b.cliente_id IN (
                SELECT c1.cliente_id FROM gold.dim_cliente_comercial c1
                WHERE c1.estatus_comercial <> 'FUERA_DE_ALCANCE'
                  AND c1.canal_distribucion IN (10, 40, 60))
          -- Clearing reset: bsid wins, or the key duplicates and a paid invoice shows open.
          AND  NOT EXISTS (
                SELECT 1 FROM silver.sap_bsid i
                WHERE i.mandante = b.mandante AND i.sociedad = b.sociedad
                  AND i.cliente_id = b.cliente_id AND i.ejercicio = b.ejercicio
                  AND i.documento_id = b.documento_id AND i.posicion = b.posicion)
        OPTION (RECOMPILE);
        SET @rows = @@ROWCOUNT;
        CREATE UNIQUE CLUSTERED INDEX ix_comp ON #comp(sociedad, cliente_id, ejercicio, documento_id, posicion);
        EXEC control.log_step @proc, @step, @t, @rows;

        -- All deletes run before the inserts: the key has no flag_compensada, so an
        -- invoice that went from open to cleared would collide with its old row.
        SET @step = 'delete cleared window'; SET @t = SYSDATETIME(); SET @rows = 0;
        SET @lote = 1;
        WHILE @lote > 0
        BEGIN
            DELETE TOP (50000) FROM gold.fact_facturas
            WHERE flag_compensada = 1
              AND fecha_compensacion >= @fecha_desde
              OPTION (RECOMPILE);
            SET @lote = @@ROWCOUNT;
            SET @rows = @rows + @lote;
        END
        EXEC control.log_step @proc, @step, @t, @rows;

        -- A re-cleared invoice keeps its old stored date: delete by key.
        SET @step = 'delete re-cleared by key'; SET @t = SYSDATETIME();
        DELETE g
        FROM   gold.fact_facturas g
        JOIN   #comp c ON c.sociedad = g.sociedad AND c.cliente_id = g.cliente_id
                      AND c.ejercicio = g.ejercicio AND c.documento_id = g.documento_id
                      AND c.posicion = g.posicion
        WHERE  g.flag_compensada = 1
        OPTION (RECOMPILE);
        SET @recomp = @@ROWCOUNT;
        EXEC control.log_step @proc, @step, @t, @recomp;

        SET @step = 'delete open'; SET @t = SYSDATETIME(); SET @rows = 0;
        SET @lote = 1;
        WHILE @lote > 0
        BEGIN
            DELETE TOP (50000) FROM gold.fact_facturas WHERE flag_compensada = 0;
            SET @lote = @@ROWCOUNT;
            SET @rows = @rows + @lote;
        END
        EXEC control.log_step @proc, @step, @t, @rows;

        SET @step = 'insert cleared'; SET @t = SYSDATETIME();
        INSERT INTO gold.fact_facturas (
            sociedad, cliente_id, ejercicio, documento_id, posicion,
            documento_compensacion, ejercicio_compensacion, clase_documento,
            fecha_documento, fecha_vencimiento, fecha_contabilizacion, fecha_compensacion,
            monto, clave_contabilizacion, flag_compensada,
            cliente_comercial_sk, cliente_credito_sk)
        SELECT sociedad, cliente_id, ejercicio, documento_id, posicion,
               documento_compensacion, ejercicio_compensacion, clase_documento,
               fecha_documento, fecha_vencimiento, fecha_contabilizacion, fecha_compensacion,
               monto, clave_contabilizacion, 1,
               cliente_comercial_sk, cliente_credito_sk
        FROM   #comp;
        SET @n_comp = @@ROWCOUNT;
        EXEC control.log_step @proc, @step, @t, @n_comp;

        SET @step = 'insert open'; SET @t = SYSDATETIME();
        INSERT INTO gold.fact_facturas (
            sociedad, cliente_id, ejercicio, documento_id, posicion,
            documento_compensacion, ejercicio_compensacion, clase_documento,
            fecha_documento, fecha_vencimiento, fecha_contabilizacion, fecha_compensacion,
            monto, clave_contabilizacion, flag_compensada,
            cliente_comercial_sk, cliente_credito_sk)
        SELECT b.sociedad, b.cliente_id, b.ejercicio, b.documento_id, b.posicion,
               NULL, NULL, b.clase_documento,
               b.fecha_documento, b.fecha_vencimiento, b.fecha_contabilizacion, NULL,
               b.monto_moneda_local, b.clave_contabilizacion, 0,
               dcc.id_surrogate, dck.id_surrogate
        FROM   silver.sap_bsid b
        LEFT JOIN gold.dim_cliente_comercial dcc
               ON dcc.cliente_id = b.cliente_id
              AND b.fecha_contabilizacion >= dcc.fecha_inicio_vigencia
              AND (dcc.fecha_fin_vigencia IS NULL OR b.fecha_contabilizacion <= dcc.fecha_fin_vigencia)
        LEFT JOIN gold.dim_cliente_credito dck
               ON dck.cliente_id = b.cliente_id
              AND b.fecha_contabilizacion >= dck.fecha_inicio_vigencia
              AND (dck.fecha_fin_vigencia IS NULL OR b.fecha_contabilizacion <= dck.fecha_fin_vigencia)
        WHERE  b.mandante = '400' AND b.debe_haber = 'S'
          AND (b.clase_documento LIKE 'F%' OR b.clase_documento = 'D1')
          AND  b.cliente_id IN (
                SELECT c1.cliente_id FROM gold.dim_cliente_comercial c1
                WHERE c1.estatus_comercial <> 'FUERA_DE_ALCANCE'
                  AND c1.canal_distribucion IN (10, 40, 60));
        SET @n_abie = @@ROWCOUNT;
        EXEC control.log_step @proc, @step, @t, @n_abie;

        COMMIT TRANSACTION;

        EXEC control.log_step @proc, 'total', @t0;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        SELECT @err = ERROR_MESSAGE(), @line = ERROR_LINE();
        EXEC control.log_step @proc, @step, @t, NULL, @err, @line;
        THROW;
    END CATCH
END;
GO

-- ----------------------------------------------------------------------------
-- gold.load_fact_aplicacion_pagos: the bridge, three rules
-- ----------------------------------------------------------------------------
IF OBJECT_ID('gold.load_fact_aplicacion_pagos', 'P') IS NOT NULL
    DROP PROCEDURE gold.load_fact_aplicacion_pagos;
GO

CREATE PROCEDURE gold.load_fact_aplicacion_pagos
    @fecha_desde DATE = NULL,
    @fecha_hasta DATE = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @proc VARCHAR(128) = 'gold.load_fact_aplicacion_pagos',
            @step VARCHAR(128) = 'start',
            @t0   DATETIME2(0) = SYSDATETIME(),
            @t    DATETIME2(0) = SYSDATETIME(),
            @rows INT,
            @err  VARCHAR(4000),
            @line INT;
    DECLARE @n1 INT, @n2 INT, @n3 INT, @lote INT, @multi INT;

    IF @fecha_desde IS NULL
        SET @fecha_desde = DATEADD(MONTH, DATEDIFF(MONTH, 0, GETDATE()) - 1, 0);

    BEGIN TRY
        BEGIN TRANSACTION;

        SET @step = 'delete window'; SET @t = SYSDATETIME(); SET @rows = 0;
        SET @lote = 1;
        WHILE @lote > 0
        BEGIN
            DELETE TOP (50000) FROM gold.fact_aplicacion_pagos
            WHERE fecha_compensacion >= @fecha_desde
              AND (@fecha_hasta IS NULL OR fecha_compensacion < @fecha_hasta)
              OPTION (RECOMPILE);
            SET @lote = @@ROWCOUNT;
            SET @rows = @rows + @lote;
        END
        EXEC control.log_step @proc, @step, @t, @rows;

        -- A rebuilt payment may carry an old stored date: delete by payment key as well.
        SET @step = 'delete by payment key'; SET @t = SYSDATETIME();
        DELETE a
        FROM   gold.fact_aplicacion_pagos a
        JOIN   gold.fact_pagos p
               ON  p.sociedad = a.sociedad AND p.ejercicio = a.ejercicio_pago
               AND p.documento_id = a.pago_id AND p.posicion = a.posicion_pago
        WHERE  p.fecha_compensacion >= @fecha_desde
          AND (@fecha_hasta IS NULL OR p.fecha_compensacion < @fecha_hasta)
        OPTION (RECOMPILE);
        SET @rows = @@ROWCOUNT;
        EXEC control.log_step @proc, @step, @t, @rows;

        -- A payment open today (clearing reset) leaves its old bridge rows behind.
        SET @step = 'delete payments open today'; SET @t = SYSDATETIME();
        DELETE a
        FROM   gold.fact_aplicacion_pagos a
        JOIN   gold.fact_pagos p
               ON  p.sociedad = a.sociedad AND p.ejercicio = a.ejercicio_pago
               AND p.documento_id = a.pago_id AND p.posicion = a.posicion_pago
        WHERE  p.fecha_compensacion IS NULL;
        SET @rows = @@ROWCOUNT;
        EXEC control.log_step @proc, @step, @t, @rows;

        -- Rule 1 GRUPO: the payment's clearing group holds the invoices.
        SET @step = 'insert GRUPO'; SET @t = SYSDATETIME();
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
          AND (@fecha_hasta IS NULL OR p.fecha_compensacion < @fecha_hasta)
          OPTION (RECOMPILE);
        SET @n1 = @@ROWCOUNT;
        EXEC control.log_step @proc, @step, @t, @n1;

        -- Hops aggregated to (child, final group): by line, a child with three key-15
        -- lines to the same group would triple every invoice.
        SET @step = 'insert SEGUNDO_SALTO'; SET @t = SYSDATETIME();
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

        -- Guard: payment documents (keys 11 and 15) feeding each intermediate document.
        -- More than one and the money is mixed: no way to tell which one paid which line.
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

        -- Rule 2 SEGUNDO_SALTO: only where GRUPO found nothing. LEFT JOIN to the guard:
        -- it is a control value, not a filter. Key 08 mirror lines are left out on purpose.
        INSERT INTO gold.fact_aplicacion_pagos (
            sociedad, cliente_id, ejercicio_pago, pago_id, posicion_pago,
            ejercicio_factura, factura_id, posicion_factura,
            documento_compensacion, fecha_compensacion, regla)
        SELECT p.sociedad, p.cliente_id, p.ejercicio, p.documento_id, p.posicion,
               f.ejercicio, f.documento_id, f.posicion,
               s.grupo_final,
               p.fecha_compensacion, 'SEGUNDO_SALTO'
        FROM   gold.fact_pagos p
        JOIN   #salto s            ON s.hijo = p.documento_compensacion
        JOIN   gold.fact_facturas f ON f.documento_compensacion = s.grupo_final
                                   AND f.ejercicio_compensacion = s.ejercicio_final
        LEFT JOIN #guarda g        ON g.intermedio = p.documento_compensacion
        WHERE  p.fecha_compensacion >= @fecha_desde
          AND (@fecha_hasta IS NULL OR p.fecha_compensacion < @fecha_hasta)
          AND  p.clave_contabilizacion IN ('11','15')
          AND  ISNULL(g.n_pagos, 1) = 1
          AND  NOT EXISTS (SELECT 1 FROM gold.fact_facturas ff
                           WHERE ff.documento_compensacion = p.documento_compensacion
                             AND ff.ejercicio_compensacion = p.ejercicio_compensacion)
                             OPTION (RECOMPILE);
        SET @n2 = @@ROWCOUNT;
        EXEC control.log_step @proc, @step, @t, @n2;

        -- Rule 3 REFERENCIA: the child's open key-15 line points to an invoice that is
        -- still open (partial payment). Open invoices only: an invoice settled elsewhere
        -- is not a partial payment of this one.
        SET @step = 'insert REFERENCIA'; SET @t = SYSDATETIME();
        INSERT INTO gold.fact_aplicacion_pagos (
            sociedad, cliente_id, ejercicio_pago, pago_id, posicion_pago,
            ejercicio_factura, factura_id, posicion_factura,
            documento_compensacion, fecha_compensacion, regla)
        SELECT p.sociedad, p.cliente_id, p.ejercicio, p.documento_id, p.posicion,
               f.ejercicio, f.documento_id, f.posicion,
               p.documento_compensacion,
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
               AND f.flag_compensada = 0
        LEFT JOIN #guarda g ON g.intermedio = p.documento_compensacion
        WHERE  p.fecha_compensacion >= @fecha_desde
          AND (@fecha_hasta IS NULL OR p.fecha_compensacion < @fecha_hasta)
          AND  p.clave_contabilizacion IN ('11','15')
          AND  ISNULL(g.n_pagos, 1) = 1
          OPTION (RECOMPILE);
        SET @n3 = @@ROWCOUNT;
        EXEC control.log_step @proc, @step, @t, @n3;

        COMMIT TRANSACTION;

        -- Check: payments the guard really left out (they would have entered through
        -- the second hop and were not linked by GRUPO).
        SET @step = 'check: multi-payment intermediates excluded'; SET @t = SYSDATETIME();
        SELECT @multi = COUNT(DISTINCT p.documento_id)
        FROM   gold.fact_pagos p
        JOIN   #guarda g ON g.intermedio = p.documento_compensacion
        JOIN   #salto  s ON s.hijo       = p.documento_compensacion
        WHERE  g.n_pagos > 1
          AND  p.fecha_compensacion >= @fecha_desde
          AND (@fecha_hasta IS NULL OR p.fecha_compensacion < @fecha_hasta)
          AND  p.clave_contabilizacion IN ('11','15')
          AND  NOT EXISTS (SELECT 1 FROM gold.fact_facturas ff
                           WHERE ff.documento_compensacion = p.documento_compensacion
                             AND ff.ejercicio_compensacion = p.ejercicio_compensacion)
                             OPTION (RECOMPILE);
        EXEC control.log_step @proc, @step, @t, @multi;

        EXEC control.log_step @proc, 'total', @t0;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        SELECT @err = ERROR_MESSAGE(), @line = ERROR_LINE();
        EXEC control.log_step @proc, @step, @t, NULL, @err, @line;
        THROW;
    END CATCH
END;
GO

-- ----------------------------------------------------------------------------
-- gold.load_fact_facturas_pago_efectivo: effective payment date, days and
-- classification per invoice. Runs after the bridge, which it reads.
-- ----------------------------------------------------------------------------
IF OBJECT_ID('gold.load_fact_facturas_pago_efectivo', 'P') IS NOT NULL
    DROP PROCEDURE gold.load_fact_facturas_pago_efectivo;
GO

CREATE PROCEDURE gold.load_fact_facturas_pago_efectivo
    @fecha_desde DATE = NULL,
    @fecha_hasta DATE = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @proc VARCHAR(128) = 'gold.load_fact_facturas_pago_efectivo',
            @step VARCHAR(128) = 'start',
            @t0   DATETIME2(0) = SYSDATETIME(),
            @t    DATETIME2(0) = SYSDATETIME(),
            @rows INT,
            @err  VARCHAR(4000),
            @line INT;
    DECLARE @n_comp INT, @n_abie INT;

    IF @fecha_desde IS NULL
        SET @fecha_desde = DATEADD(MONTH, DATEDIFF(MONTH, 0, GETDATE()) - 1, 0);

    BEGIN TRY
        -- Last payment per invoice, precomputed once: a correlated subquery ran row by
        -- row over 3.27M invoices.
        SET @step = 'last payment per invoice'; SET @t = SYSDATETIME();
        IF OBJECT_ID('tempdb..#fpe') IS NOT NULL DROP TABLE #fpe;
        SELECT   a.sociedad, a.ejercicio_factura, a.factura_id, a.posicion_factura,
                 MAX(p.fecha_documento) AS fpe
        INTO     #fpe
        FROM     gold.fact_aplicacion_pagos a
        JOIN     gold.fact_pagos p
                 ON  p.sociedad = a.sociedad AND p.ejercicio = a.ejercicio_pago
                 AND p.documento_id = a.pago_id AND p.posicion = a.posicion_pago
        GROUP BY a.sociedad, a.ejercicio_factura, a.factura_id, a.posicion_factura;
        SET @rows = @@ROWCOUNT;
        CREATE UNIQUE CLUSTERED INDEX ix_fpe ON #fpe(sociedad, ejercicio_factura, factura_id, posicion_factura);
        EXEC control.log_step @proc, @step, @t, @rows;

        -- Two statements, not one with OR: the OR is not sargable.
        -- LEFT JOIN: an invoice that lost its payment goes back to NULL.
        SET @step = 'update cleared window'; SET @t = SYSDATETIME();
        UPDATE f
        SET    f.fecha_pago_efectiva = x.fpe,
               f.dias_pago = DATEDIFF(DAY, f.fecha_vencimiento, x.fpe),
               f.clasificacion_cobranza =
                   CASE WHEN x.fpe IS NULL THEN NULL
                        WHEN f.fecha_vencimiento < DATEFROMPARTS(YEAR(x.fpe), MONTH(x.fpe), 1)
                             THEN 'PAGO_A_VENCIMIENTO'
                        WHEN f.fecha_vencimiento <= EOMONTH(x.fpe) THEN 'PAGO_A_MES'
                        ELSE 'PAGO_ANTICIPADO' END
        FROM   gold.fact_facturas f
        LEFT JOIN #fpe x ON x.sociedad = f.sociedad AND x.ejercicio_factura = f.ejercicio
                        AND x.factura_id = f.documento_id AND x.posicion_factura = f.posicion
        WHERE  f.flag_compensada = 1
          AND  f.fecha_compensacion >= @fecha_desde
          AND (@fecha_hasta IS NULL OR f.fecha_compensacion < @fecha_hasta)
        OPTION (RECOMPILE);
        SET @n_comp = @@ROWCOUNT;
        EXEC control.log_step @proc, @step, @t, @n_comp;

        -- Open invoices: always all of them; a partial payment (REFERENCIA) can reach them.
        SET @step = 'update open'; SET @t = SYSDATETIME();
        UPDATE f
        SET    f.fecha_pago_efectiva = x.fpe,
               f.dias_pago = DATEDIFF(DAY, f.fecha_vencimiento, x.fpe),
               f.clasificacion_cobranza =
                   CASE WHEN x.fpe IS NULL THEN NULL
                        WHEN f.fecha_vencimiento < DATEFROMPARTS(YEAR(x.fpe), MONTH(x.fpe), 1)
                             THEN 'PAGO_A_VENCIMIENTO'
                        WHEN f.fecha_vencimiento <= EOMONTH(x.fpe) THEN 'PAGO_A_MES'
                        ELSE 'PAGO_ANTICIPADO' END
        FROM   gold.fact_facturas f
        LEFT JOIN #fpe x ON x.sociedad = f.sociedad AND x.ejercicio_factura = f.ejercicio
                        AND x.factura_id = f.documento_id AND x.posicion_factura = f.posicion
        WHERE  f.flag_compensada = 0
        OPTION (RECOMPILE);
        SET @n_abie = @@ROWCOUNT;
        EXEC control.log_step @proc, @step, @t, @n_abie;

        EXEC control.log_step @proc, 'total', @t0;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        SELECT @err = ERROR_MESSAGE(), @line = ERROR_LINE();
        EXEC control.log_step @proc, @step, @t, NULL, @err, @line;
        THROW;
    END CATCH
END;
GO

-- ----------------------------------------------------------------------------
-- gold.load_fact_pagos_sin_aplicacion: payments outside the bridge, with the reason
-- ----------------------------------------------------------------------------
IF OBJECT_ID('gold.load_fact_pagos_sin_aplicacion', 'P') IS NOT NULL
    DROP PROCEDURE gold.load_fact_pagos_sin_aplicacion;
GO

CREATE PROCEDURE gold.load_fact_pagos_sin_aplicacion
    @fecha_desde DATE = NULL,
    @fecha_hasta DATE = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @proc VARCHAR(128) = 'gold.load_fact_pagos_sin_aplicacion',
            @step VARCHAR(128) = 'start',
            @t0   DATETIME2(0) = SYSDATETIME(),
            @t    DATETIME2(0) = SYSDATETIME(),
            @rows INT,
            @err  VARCHAR(4000),
            @line INT;
    DECLARE @n INT, @lote INT, @revisar INT, @huerfanos INT, @n_abie INT;

    IF @fecha_desde IS NULL
        SET @fecha_desde = DATEADD(MONTH, DATEDIFF(MONTH, 0, GETDATE()) - 1, 0);

    BEGIN TRY
        BEGIN TRANSACTION;

        SET @step = 'delete window'; SET @t = SYSDATETIME(); SET @rows = 0;
        SET @lote = 1;
        WHILE @lote > 0
        BEGIN
            DELETE TOP (50000) FROM gold.fact_pagos_sin_aplicacion
            WHERE fecha_compensacion >= @fecha_desde
              AND (@fecha_hasta IS NULL OR fecha_compensacion < @fecha_hasta)
              OPTION (RECOMPILE);
            SET @lote = @@ROWCOUNT;
            SET @rows = @rows + @lote;
        END
        EXEC control.log_step @proc, @step, @t, @rows;

        -- A rebuilt payment may carry an old stored date: delete by payment key as well.
        SET @step = 'delete by payment key'; SET @t = SYSDATETIME();
        DELETE a
        FROM   gold.fact_pagos_sin_aplicacion a
        JOIN   gold.fact_pagos p
               ON  p.sociedad = a.sociedad AND p.ejercicio = a.ejercicio
               AND p.documento_id = a.documento_id AND p.posicion = a.posicion
        WHERE  p.fecha_compensacion >= @fecha_desde
          AND (@fecha_hasta IS NULL OR p.fecha_compensacion < @fecha_hasta)
        OPTION (RECOMPILE);
        SET @rows = @@ROWCOUNT;
        EXEC control.log_step @proc, @step, @t, @rows;

        -- Open payments are a snapshot: out go the rows stored as open and the rows of
        -- payments that are open today even if they were stored as cleared.
        SET @step = 'delete open payments'; SET @t = SYSDATETIME();
        DELETE FROM gold.fact_pagos_sin_aplicacion WHERE fecha_compensacion IS NULL;
        SET @rows = @@ROWCOUNT;
        DELETE a
        FROM   gold.fact_pagos_sin_aplicacion a
        JOIN   gold.fact_pagos p
               ON  p.sociedad = a.sociedad AND p.ejercicio = a.ejercicio
               AND p.documento_id = a.documento_id AND p.posicion = a.posicion
        WHERE  p.fecha_compensacion IS NULL;
        SET @rows = @rows + @@ROWCOUNT;
        EXEC control.log_step @proc, @step, @t, @rows;

        SET @step = 'insert cleared'; SET @t = SYSDATETIME();
        IF OBJECT_ID('tempdb..#salto2') IS NOT NULL DROP TABLE #salto2;
        SELECT DISTINCT h.documento_id AS hijo, h.documento_compensacion AS grupo_final,
               h.ejercicio_compensacion AS ejercicio_final
        INTO   #salto2
        FROM   silver.sap_bsad h
        WHERE  h.mandante = '400' AND h.clase_documento = 'DZ'
          AND  h.clave_contabilizacion = '15'
          AND  h.documento_compensacion IS NOT NULL;
        CREATE UNIQUE CLUSTERED INDEX ix_s2 ON #salto2(hijo, grupo_final, ejercicio_final);

        -- Same guard as the bridge, to label what the bridge excluded.
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
               -- The order of the branches defines the labels. CADENA_AMBIGUA goes last: it
               -- applies only when the hop did reach invoices and the guard excluded it.
               -- REVISAR is the unknown case and must be 0.
               CASE WHEN x.clave_contabilizacion NOT IN ('11','15') THEN 'LINEA_TECNICA'
                    WHEN x.tiene_salto      = 0        THEN 'SIN_APLICACION'
                    WHEN x.salto_a_facturas = 0        THEN 'LIQUIDA_NO_FACTURA'
                    WHEN x.n_pagos_intermedio > 1      THEN 'CADENA_AMBIGUA'
                    ELSE 'REVISAR' END
        FROM (
            SELECT p.sociedad, p.cliente_id, p.ejercicio, p.documento_id, p.posicion,
                   p.documento_compensacion, p.fecha_compensacion, p.clave_contabilizacion,
                   MAX(CASE WHEN s.grupo_final IS NOT NULL THEN 1 ELSE 0 END) AS tiene_salto,
                   MAX(CASE WHEN f.documento_compensacion IS NOT NULL THEN 1 ELSE 0 END) AS salto_a_facturas,
                   MAX(ISNULL(g.n_pagos, 1)) AS n_pagos_intermedio
            FROM   gold.fact_pagos p
            LEFT JOIN #guarda2 g ON g.intermedio = p.documento_compensacion
            -- LEFT JOIN: a payment with no hop must survive; that makes it SIN_APLICACION.
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
        ) x
        OPTION (RECOMPILE);
        SET @n = @@ROWCOUNT;
        EXEC control.log_step @proc, @step, @t, @n;

        -- PENDIENTE_DE_APLICAR: open payments. None can be in the bridge (no clearing
        -- group); a key other than 11/15 is still LINEA_TECNICA.
        SET @step = 'insert open'; SET @t = SYSDATETIME();
        INSERT INTO gold.fact_pagos_sin_aplicacion (
            sociedad, cliente_id, ejercicio, documento_id, posicion,
            documento_compensacion, fecha_compensacion, motivo)
        SELECT p.sociedad, p.cliente_id, p.ejercicio, p.documento_id, p.posicion,
               NULL, NULL,
               CASE WHEN p.clave_contabilizacion NOT IN ('11','15') THEN 'LINEA_TECNICA'
                    ELSE 'PENDIENTE_DE_APLICAR' END
        FROM   gold.fact_pagos p
        WHERE  p.fecha_compensacion IS NULL;
        SET @n_abie = @@ROWCOUNT;
        EXEC control.log_step @proc, @step, @t, @n_abie;

        COMMIT TRANSACTION;

        -- Checks run after COMMIT, on the committed state. Both must be 0.
        SET @step = 'check: REVISAR (must be 0)'; SET @t = SYSDATETIME();
        SELECT @revisar = COUNT(*) FROM gold.fact_pagos_sin_aplicacion
        WHERE motivo = 'REVISAR'
          AND fecha_compensacion >= @fecha_desde
          AND (@fecha_hasta IS NULL OR fecha_compensacion < @fecha_hasta)
          OPTION (RECOMPILE);
        EXEC control.log_step @proc, @step, @t, @revisar;

        -- Every payment is in the bridge or here.
        SET @step = 'check: unclassified payments (must be 0)'; SET @t = SYSDATETIME();
        SELECT @huerfanos = COUNT(*)
        FROM   gold.fact_pagos p
        WHERE  p.fecha_compensacion >= @fecha_desde
          AND (@fecha_hasta IS NULL OR p.fecha_compensacion < @fecha_hasta)
          AND  NOT EXISTS (SELECT 1 FROM gold.fact_aplicacion_pagos a
                           WHERE a.sociedad=p.sociedad AND a.ejercicio_pago=p.ejercicio
                             AND a.pago_id=p.documento_id AND a.posicion_pago=p.posicion)
          AND  NOT EXISTS (SELECT 1 FROM gold.fact_pagos_sin_aplicacion s
                           WHERE s.sociedad=p.sociedad AND s.ejercicio=p.ejercicio
                             AND s.documento_id=p.documento_id AND s.posicion=p.posicion)
                             OPTION (RECOMPILE);

        -- Open payments have no date: checked separately.
        SELECT @huerfanos = @huerfanos + COUNT(*)
        FROM   gold.fact_pagos p
        WHERE  p.fecha_compensacion IS NULL
          AND  NOT EXISTS (SELECT 1 FROM gold.fact_aplicacion_pagos a
                           WHERE a.sociedad=p.sociedad AND a.ejercicio_pago=p.ejercicio
                             AND a.pago_id=p.documento_id AND a.posicion_pago=p.posicion)
          AND  NOT EXISTS (SELECT 1 FROM gold.fact_pagos_sin_aplicacion s
                           WHERE s.sociedad=p.sociedad AND s.ejercicio=p.ejercicio
                             AND s.documento_id=p.documento_id AND s.posicion=p.posicion);
        EXEC control.log_step @proc, @step, @t, @huerfanos;

        EXEC control.log_step @proc, 'total', @t0;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        SELECT @err = ERROR_MESSAGE(), @line = ERROR_LINE();
        EXEC control.log_step @proc, @step, @t, NULL, @err, @line;
        THROW;
    END CATCH
END;
GO

-- ----------------------------------------------------------------------------
-- gold.load_gold: the daily gold refresh
-- Dimensions first (facts resolve SCD2 keys; fact_saldo_cartera has foreign keys
-- to them), then the payment application model in its fixed order. Changing the
-- order raises no error: it silently loses rows.
-- ----------------------------------------------------------------------------
IF OBJECT_ID('gold.load_gold', 'P') IS NOT NULL
    DROP PROCEDURE gold.load_gold;
GO

CREATE PROCEDURE gold.load_gold
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @proc VARCHAR(128) = 'gold.load_gold',
            @step VARCHAR(128) = 'start',
            @t0   DATETIME2(0) = SYSDATETIME(),
            @t    DATETIME2(0) = SYSDATETIME(),
            @err  VARCHAR(4000),
            @line INT;

    BEGIN TRY
        SET @step = 'gold.load_dim_fecha';
        EXEC gold.load_dim_fecha;
        SET @step = 'gold.load_dim_empleado';
        EXEC gold.load_dim_empleado;
        SET @step = 'gold.load_dim_cliente';
        EXEC gold.load_dim_cliente;
        SET @step = 'gold.load_dim_cliente_comercial';
        EXEC gold.load_dim_cliente_comercial;
        SET @step = 'gold.load_dim_cliente_credito';
        EXEC gold.load_dim_cliente_credito;
        SET @step = 'gold.load_fact_pagos_compensados';
        EXEC gold.load_fact_pagos_compensados;
        SET @step = 'gold.load_fact_facturas_compensadas';
        EXEC gold.load_fact_facturas_compensadas;
        SET @step = 'gold.load_fact_saldo_cartera';
        EXEC gold.load_fact_saldo_cartera;

        SET @step = 'gold.load_fact_pagos';
        EXEC gold.load_fact_pagos;
        SET @step = 'gold.load_fact_facturas';
        EXEC gold.load_fact_facturas;
        SET @step = 'gold.load_fact_aplicacion_pagos';
        EXEC gold.load_fact_aplicacion_pagos;
        SET @step = 'gold.load_fact_facturas_pago_efectivo';
        EXEC gold.load_fact_facturas_pago_efectivo;
        SET @step = 'gold.load_fact_pagos_sin_aplicacion';
        EXEC gold.load_fact_pagos_sin_aplicacion;

        EXEC control.log_step @proc, 'total', @t0;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        SELECT @err = ERROR_MESSAGE(), @line = ERROR_LINE();
        EXEC control.log_step @proc, @step, @t, NULL, @err, @line;
        THROW;
    END CATCH
END;
GO
