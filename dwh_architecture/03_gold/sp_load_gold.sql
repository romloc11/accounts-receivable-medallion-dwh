USE ANALISIS_DATOS;
GO

/*
===============================================================================
PROJECT: Enterprise Data Warehouse (dwh-ciosa)
LAYER: Gold - load procedures for the star schema.

STYLE: one stored procedure per dimension/fact, kept separate for isolated
testing/debugging - same reasoning as the rest of this project given how many
unexplained compilation issues this SQL Server 2012 instance has produced
when things got batched together.

CONSOLIDATED 2026-08-20 via gold.load_gold at the bottom of this file - an
orchestrator that just EXECs the individual procedures below in the correct
dependency order, so a full refresh is one EXEC instead of remembering 6.
The individual procedures still exist and can still be run standalone for
debugging - gold.load_gold adds no logic of its own, only sequencing. This
EXEC-calling-proc pattern has NOT been tested before on this server (the
only confirmed-broken proc-calling-proc pattern is control.sp_log_load, a
different and more complex case with named params - see
dwh-ciosa-sqlserver-constraints in memory) - if gold.load_gold ever fails to
compile or run with a hard-to-trace error, this pattern is the first suspect.

gold.dim_fecha IS loaded here (gold.load_dim_fecha, first procedure below) -
2026-08-20: changed from a static one-time-populated calendar to a growing
one, extended by this procedure on every gold.load_gold run. Retires the old
populate_dim_fecha.sql (its bootstrap logic - what to do when the table is
empty - is now just the NULL case inside this procedure).
===============================================================================
*/

-- ==========================================================
-- gold.load_dim_fecha (Calendar, no SCD)
-- REDESIGNED 2026-08-20: gold.dim_fecha went from static (2020-01-01 to
-- 2035-12-31, populated once) to growing - fixed lower bound at 2022-01-01
-- (bronze.sap_bsad's real start date), upper bound = today + 1 year (a
-- cushion for future due dates like NET-90 terms), automatically extended
-- on every run. Reason: the static range offered years with no real
-- transactions at all (e.g. the Power BI report's Year filter showed the
-- full 2020-2035 even though real data only existed since 2022) - see
-- dwh-ciosa-project-status in memory for the full detail.
--
-- Idempotent and safe to run every day: if it's already up to date
-- (MAX(fecha) >= today+1 year), the WHILE doesn't iterate at all. If the
-- table is empty (first time, new database), it starts from the fixed
-- lower bound - this replaces the bootstrap that populate_dim_fecha.sql
-- (now retired) used to do. NEVER deletes existing rows - only appends new
-- days at the end, never uses TRUNCATE (gold.fact_saldo_cartera already
-- has a real FK to this table with data - TRUNCATE would fail, the same
-- reason that already forced gold.load_dim_cliente to be redesigned).
-- ==========================================================
IF OBJECT_ID('gold.load_dim_fecha', 'P') IS NOT NULL
    DROP PROCEDURE gold.load_dim_fecha;
GO

CREATE PROCEDURE gold.load_dim_fecha
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @start_time DATETIME, @end_time DATETIME, @rows_count INT = 0;
    DECLARE @fecha_max_actual DATE, @fecha_max_objetivo DATE, @fecha_cursor DATE;

    BEGIN TRY
        SET @start_time = GETDATE();
        PRINT '>> Loading gold.dim_fecha...';

        SET DATEFIRST 7;  -- Sunday = 1, explicit so it doesn't depend on server configuration

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
            SET @rows_count = @rows_count + 1;
            SET @fecha_cursor = DATEADD(DAY, 1, @fecha_cursor);
        END

        SET @end_time = GETDATE();
        PRINT 'New days added: ' + CAST(@rows_count AS NVARCHAR) + ' | Duration: ' + CAST(DATEDIFF(SECOND, @start_time, @end_time) AS NVARCHAR) + ' s';
    END TRY
    BEGIN CATCH
        PRINT 'ERROR in gold.dim_fecha: ' + ERROR_MESSAGE();
        THROW;
    END CATCH;
END;
GO

PRINT 'Procedure gold.load_dim_fecha created successfully.';
GO

-- ==========================================================
-- gold.load_dim_cliente (SCD Type 1)
-- 2026-08-17: redesigned from TRUNCATE+INSERT to explicit UPDATE+INSERT (no
-- DELETE) - TRUNCATE stopped being viable as soon as gold.fact_aplicacion_pagos
-- added its FK to this table (SQL Server doesn't allow TRUNCATE on a table
-- referenced by an FK, regardless of whether the child table is empty).
-- Customers that no longer appear in kna1 are not deleted (a real hard
-- delete of a customer has never been observed in SAP, and deleting here
-- would risk breaking the facts' FKs if it ever does happen) - existing
-- ones are only updated and new ones inserted, the same "explicit, not
-- MERGE" principle already established for this file's SCD2 tables.
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
        PRINT '>> Loading gold.dim_cliente...';

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
            END AS tipo_cliente,  -- confirmed 2026-08-07: KRAUS='FILIAL' takes priority, then null/generic RFC
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

        -- Step 1: update customers that already exist (regardless of
        -- whether anything actually changed - SCD1 always overwrites,
        -- there's no version to protect)
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

        -- Step 2: insert new customers (didn't previously exist in dim_cliente)
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
        PRINT 'Rows updated: ' + CAST(@rows_updated AS NVARCHAR) + ' | New rows: ' + CAST(@rows_inserted AS NVARCHAR) + ' | Duration: ' + CAST(DATEDIFF(SECOND, @start_time, @end_time) AS NVARCHAR) + ' s';
    END TRY
    BEGIN CATCH
        PRINT 'ERROR in gold.dim_cliente: ' + ERROR_MESSAGE();
        THROW;
    END CATCH;
END;
GO

PRINT 'Procedure gold.load_dim_cliente created successfully.';
GO

-- ==========================================================
-- gold.load_dim_cliente_comercial (SCD Type 2)
-- The project's first real SCD2 - built in explicit steps (temp table +
-- UPDATE + INSERT) instead of a single MERGE, given this SQL Server 2012
-- instance's history of hard-to-trace compilation errors when too much
-- gets grouped into a single batch.
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
        PRINT '>> Loading gold.dim_cliente_comercial...';

        -- Step 1: pick the representative channel per customer (status
        -- priority, then lowest canal_distribucion as the final tiebreak)
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

        -- Step 2: close active versions whose attribute hash changed
        UPDATE d
        SET d.es_vigente = 0,
            d.fecha_fin_vigencia = DATEADD(DAY, -1, @hoy)
        FROM gold.dim_cliente_comercial d
        JOIN #representante r ON r.cliente_id = d.cliente_id
        WHERE d.es_vigente = 1
          AND d.hash_atributos <> r.hash_atributos;

        -- Step 3: insert a new version for customers that are new or have a
        -- different hash (step 2 already closed the previous active
        -- version for the ones that changed, so "no active version" covers
        -- both cases: new AND changed)
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
        PRINT 'New/versioned rows: ' + CAST(@rows_count AS NVARCHAR) + ' | Duration: ' + CAST(DATEDIFF(SECOND, @start_time, @end_time) AS NVARCHAR) + ' s';
    END TRY
    BEGIN CATCH
        PRINT 'ERROR in gold.dim_cliente_comercial: ' + ERROR_MESSAGE();
        THROW;
    END CATCH;
END;
GO

PRINT 'Procedure gold.load_dim_cliente_comercial created successfully.';
GO

-- ==========================================================
-- gold.load_dim_cliente_credito (SCD Type 2)
-- Requires gold.dim_cliente_comercial to already be loaded (it relies on
-- its active version to know "which channel" to use when looking up the
-- analyst/collector). Not called automatically - execution order
-- (comercial before credito) is the responsibility of whoever runs the
-- procedures, not a wrapper that calls one from the other (same reasoning
-- as dq, see the note in sp_load_dq.sql).
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
        PRINT '>> Loading gold.dim_cliente_credito...';

        -- Step 1: credit analyst (E1) and collector (CC), resolved on the
        -- channel gold.dim_cliente_comercial already chose as the
        -- representative (same lowest-'contador' tiebreak used in
        -- gold.vw_cliente_canal_estatus, in case there's more than one
        -- assignment of the same role in that channel)
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

        -- Step 2: close active versions whose attribute hash changed
        UPDATE d
        SET d.es_vigente = 0,
            d.fecha_fin_vigencia = DATEADD(DAY, -1, @hoy)
        FROM gold.dim_cliente_credito d
        JOIN #representante_credito r ON r.cliente_id = d.cliente_id
        WHERE d.es_vigente = 1
          AND d.hash_atributos <> r.hash_atributos;

        -- Step 3: insert a new version for customers that are new or have a different hash
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
        PRINT 'New/versioned rows: ' + CAST(@rows_count AS NVARCHAR) + ' | Duration: ' + CAST(DATEDIFF(SECOND, @start_time, @end_time) AS NVARCHAR) + ' s';
    END TRY
    BEGIN CATCH
        PRINT 'ERROR in gold.dim_cliente_credito: ' + ERROR_MESSAGE();
        THROW;
    END CATCH;
END;
GO

PRINT 'Procedure gold.load_dim_cliente_credito created successfully.';
GO

-- ==========================================================
-- gold.load_fact_saldo_cartera
-- Daily snapshot of each customer's open balance (silver.sap_bsid,
-- aggregated at the customer level) + historical payment behavior (DPP and
-- % on-time/late, from gold.fact_aplicacion_pagos WHERE
-- tipo_aplicacion='PAGO' - see Step 2 below). Fixed and validated
-- 2026-08-17 (first successful run: 4,571 customers with a balance). NEVER
-- deletes previous days' snapshots - only appends today's (with a DELETE
-- of today's date first, so it's safe to re-run it the same day without
-- duplicating).
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
        PRINT '>> Loading gold.fact_saldo_cartera (snapshot ' + CONVERT(VARCHAR, @hoy, 23) + ')...';

        -- Idempotent: if it already ran today, that snapshot gets replaced (not duplicated)
        DELETE FROM gold.fact_saldo_cartera WHERE fecha_snapshot = @hoy;

        -- Step 1: aggregate silver.sap_bsid at the customer level.
        -- REDESIGNED 2026-08-18 after reconciling against an external
        -- portfolio report (see ddl_gold.sql for the full detail of the 3
        -- causes found):
        --   1. monto_moneda_local NEVER carries a sign (same as bsad) -
        --      debe_haber='H' (payments/credit notes/returns/adjustments
        --      sitting as an unapplied open item) is signed as NEGATIVE
        --      before aggregating (#bsid_firmado) - without this it was
        --      added as debt instead of subtracted ($143.2M wrongly added
        --      across ALL of bsid, unfiltered).
        --   2. clase_documento='SA' (GL journal entries) excluded entirely
        --      - these aren't real customer documents.
        --   3. 16-day grace period: 1-16 days overdue = "healthy balance"
        --      (saldo_1_16, does NOT count in saldo_vencido), only 17+
        --      days is truly overdue. Aging buckets re-cut to
        --      17-31/32-180/181+ to be comparable with the external report.
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

        -- Step 2 (DPP / % on-time-late) REMOVED 2026-08-27 - now a Power BI
        -- DAX time-intelligence measure over gold.vw_pago_factura_simple,
        -- not a SQL object. See this table's own header comment in
        -- ddl_gold.sql for the full reasoning.

        -- Step 2 (was Step 3): combine balance + SCD2 dimensions (temporal join to @hoy) and insert
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
        SET @rows_count = @@ROWCOUNT;

        DROP TABLE #saldo_cliente;

        SET @end_time = GETDATE();
        PRINT 'Rows (customers with a balance): ' + CAST(@rows_count AS NVARCHAR) + ' | Duration: ' + CAST(DATEDIFF(SECOND, @start_time, @end_time) AS NVARCHAR) + ' s';
    END TRY
    BEGIN CATCH
        PRINT 'ERROR in gold.fact_saldo_cartera: ' + ERROR_MESSAGE();
        THROW;
    END CATCH;
END;
GO

PRINT 'Procedure gold.load_fact_saldo_cartera created successfully.';
GO

-- ==========================================================
-- gold.load_fact_aplicacion_pagos was REMOVED 2026-08-19 along with the
-- gold.fact_aplicacion_pagos table - see the note in ddl_gold.sql (real
-- over-attribution bugs in the 3-tier matching). Replaced by
-- gold.load_fact_pagos_compensados / gold.load_fact_facturas_compensadas
-- below, plus gold.vw_pago_factura_simple for the relationship.
-- ==========================================================

-- ==========================================================
-- gold.load_fact_pagos_compensados
-- ==========================================================
IF OBJECT_ID('gold.load_fact_pagos_compensados', 'P') IS NOT NULL
    DROP PROCEDURE gold.load_fact_pagos_compensados;
GO

CREATE PROCEDURE gold.load_fact_pagos_compensados
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @start_time DATETIME, @end_time DATETIME, @rows_count INT;

    BEGIN TRY
        SET @start_time = GETDATE();
        PRINT '>> Loading gold.fact_pagos_compensados (Incremental Merge)...';

        DECLARE @mes_anterior_inicio DATE = DATEADD(MONTH, DATEDIFF(MONTH, 0, GETDATE()) - 1, 0);

        MERGE gold.fact_pagos_compensados AS tgt
        USING (
            SELECT
                sociedad, cliente_id, ejercicio, documento_id, posicion,
                fecha_documento, fecha_compensacion, monto_moneda_local,
                documento_compensacion, ejercicio_compensacion
            FROM silver.sap_bsad
            WHERE clase_documento = 'DZ'
              AND sgtxt = 'Asignación Aut. Deposito'
              AND debe_haber <> 'S' -- excludes the "child" document's mirror/offsetting line (fix 2026-08-19, see ddl_gold.sql)
              AND monto_moneda_local > 0 -- excludes $0.00 technical residuals (fix 2026-08-19, see ddl_gold.sql)
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
        PRINT 'Rows: ' + CAST(@rows_count AS NVARCHAR) + ' | Duration: ' + CAST(DATEDIFF(SECOND, @start_time, @end_time) AS NVARCHAR) + ' s';
    END TRY
    BEGIN CATCH
        PRINT 'ERROR in gold.fact_pagos_compensados: ' + ERROR_MESSAGE();
        THROW;
    END CATCH;
END;
GO

PRINT 'Procedure gold.load_fact_pagos_compensados created successfully.';
GO

-- ==========================================================
-- gold.load_fact_facturas_compensadas
-- ==========================================================
IF OBJECT_ID('gold.load_fact_facturas_compensadas', 'P') IS NOT NULL
    DROP PROCEDURE gold.load_fact_facturas_compensadas;
GO

CREATE PROCEDURE gold.load_fact_facturas_compensadas
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @start_time DATETIME, @end_time DATETIME, @rows_count INT;

    BEGIN TRY
        SET @start_time = GETDATE();
        PRINT '>> Loading gold.fact_facturas_compensadas (Incremental Merge)...';

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

        SET @rows_count = @@ROWCOUNT;
        SET @end_time = GETDATE();
        PRINT 'Rows: ' + CAST(@rows_count AS NVARCHAR) + ' | Duration: ' + CAST(DATEDIFF(SECOND, @start_time, @end_time) AS NVARCHAR) + ' s';
    END TRY
    BEGIN CATCH
        PRINT 'ERROR in gold.fact_facturas_compensadas: ' + ERROR_MESSAGE();
        THROW;
    END CATCH;
END;
GO

PRINT 'Procedure gold.load_fact_facturas_compensadas created successfully.';
GO

-- ==========================================================
-- gold.load_dim_empleado (SCD Type 1)
-- Same explicit UPDATE+INSERT pattern as gold.load_dim_cliente (no
-- TRUNCATE, no MERGE - see ddl_gold.sql for why). Employees who no longer
-- have a current (ENDDA='99991231') row in silver.sap_pa0001 (left the
-- company) are not deleted here, same reasoning as dim_cliente not deleting
-- customers gone from kna1 - a historical vendedor_id/cobrador_id already
-- captured on an SCD2 dimension should keep resolving to the name that was
-- true at the time, not silently go orphaned.
-- ==========================================================
IF OBJECT_ID('gold.load_dim_empleado', 'P') IS NOT NULL
    DROP PROCEDURE gold.load_dim_empleado;
GO

CREATE PROCEDURE gold.load_dim_empleado
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @start_time DATETIME, @end_time DATETIME, @rows_updated INT, @rows_inserted INT;

    BEGIN TRY
        SET @start_time = GETDATE();
        PRINT '>> Loading gold.dim_empleado...';

        -- Step 1: update employees that already exist (SCD1 always
        -- overwrites, there's no version to protect)
        UPDATE d
        SET d.nombre = f.nombre, d.fecha_actualizacion = GETDATE()
        FROM gold.dim_empleado d
        JOIN silver.sap_pa0001 f ON f.id_empleado = d.id_empleado;
        SET @rows_updated = @@ROWCOUNT;

        -- Step 2: insert new employees (didn't previously exist in dim_empleado)
        INSERT INTO gold.dim_empleado (id_empleado, nombre)
        SELECT f.id_empleado, f.nombre
        FROM silver.sap_pa0001 f
        WHERE NOT EXISTS (
            SELECT 1 FROM gold.dim_empleado d WHERE d.id_empleado = f.id_empleado
        );
        SET @rows_inserted = @@ROWCOUNT;

        SET @end_time = GETDATE();
        PRINT 'Rows updated: ' + CAST(@rows_updated AS NVARCHAR) + ' | New rows: ' + CAST(@rows_inserted AS NVARCHAR) + ' | Duration: ' + CAST(DATEDIFF(SECOND, @start_time, @end_time) AS NVARCHAR) + ' s';
    END TRY
    BEGIN CATCH
        PRINT 'ERROR in gold.dim_empleado: ' + ERROR_MESSAGE();
        THROW;
    END CATCH;
END;
GO

PRINT 'Procedure gold.load_dim_empleado created successfully.';
GO

-- ==========================================================
-- gold.load_gold (orchestrator)
-- A single EXEC to run the whole gold refresh, in the correct order. Has
-- no logic of its own, just chains the procedures above via EXEC - each
-- one still exists and can still be run standalone for isolated
-- debugging/testing.
--
-- ORDER (fixed, don't change without understanding the dependencies):
--   1. gold.load_dim_fecha             - growing, no dependencies. Goes
--      first because gold.fact_saldo_cartera (step 8) has a real FK to
--      this table - it must be up to date before inserting there.
--   2. gold.load_dim_empleado          - SCD1, no dependencies. No FK from
--      any other gold object (see ddl_gold.sql), so its position here is
--      not load-bearing - kept next to dim_cliente since both are simple
--      SCD1 identity dimensions with no dependents.
--   3. gold.load_dim_cliente           - SCD1, no dependencies.
--   4. gold.load_dim_cliente_comercial - SCD2, no dependencies.
--   5. gold.load_dim_cliente_credito   - SCD2, requires (4) to have
--      already run in this refresh (uses its active version to resolve
--      analyst/collector on the same channel (4) chose).
--   6. gold.load_fact_pagos_compensados            - incremental MERGE, no dependencies.
--   7. gold.load_fact_facturas_compensadas         - incremental MERGE, no dependencies.
--   8. gold.load_fact_saldo_cartera    - requires (1)-(7) to have already
--      run: the per-customer balance has an FK to dim_cliente (if a bsid
--      customer isn't in dim_cliente yet, the snapshot's full INSERT
--      fails), and the DPP reads from
--      fact_pagos_compensados/fact_facturas_compensadas - if they weren't
--      refreshed earlier in this same run, the DPP ends up computed with
--      stale data, with no visible error.
--
-- NOT PREVIOUSLY TESTED on this SQL Server 2012 instance: a gold/dq
-- procedure had never been called from INSIDE another one before. The
-- only proc-calls-proc pattern confirmed broken on this server is
-- control.sp_log_load (see dwh-ciosa-sqlserver-constraints in memory),
-- which takes ~8 named parameters - a simple parameterless EXEC like the
-- ones below is a much simpler pattern, but it's untested. If this
-- procedure fails to compile or run with a hard-to-trace error, this
-- pattern is the first suspect - test it in isolation (a single EXEC to a
-- single empty test procedure) before investigating any other cause.
-- ==========================================================
IF OBJECT_ID('gold.load_gold', 'P') IS NOT NULL
    DROP PROCEDURE gold.load_gold;
GO

CREATE PROCEDURE gold.load_gold
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @start_time DATETIME, @end_time DATETIME;

    BEGIN TRY
        SET @start_time = GETDATE();
        PRINT '===================================================';
        PRINT '>> Starting full gold refresh...';
        PRINT '===================================================';

        EXEC gold.load_dim_fecha;
        EXEC gold.load_dim_empleado;
        EXEC gold.load_dim_cliente;
        EXEC gold.load_dim_cliente_comercial;
        EXEC gold.load_dim_cliente_credito;
        EXEC gold.load_fact_pagos_compensados;
        EXEC gold.load_fact_facturas_compensadas;
        EXEC gold.load_fact_saldo_cartera;

        SET @end_time = GETDATE();
        PRINT '===================================================';
        PRINT '>> Full gold refresh finished. Total duration: ' + CAST(DATEDIFF(SECOND, @start_time, @end_time) AS NVARCHAR) + ' s';
        PRINT '===================================================';
    END TRY
    BEGIN CATCH
        PRINT 'ERROR in gold.load_gold: ' + ERROR_MESSAGE();
        THROW;
    END CATCH;
END;
GO

PRINT 'Procedure gold.load_gold created successfully.';
GO
