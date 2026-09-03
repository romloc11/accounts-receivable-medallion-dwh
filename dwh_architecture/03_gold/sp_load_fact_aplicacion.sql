USE ANALISIS_DATOS;
GO

/*
===============================================================================
LOAD PROCEDURES - fact_aplicacion v2 strategy (PROTOTYPE)
See ddl_fact_aplicacion.sql for the objects and DESIGN.md for the design.

Conventions (the ones that have proven reliable on this SQL Server 2012):
  - one procedure per object, none calling another;
  - explicit steps (stage into a temp table -> UPDATE -> INSERT), never MERGE;
  - no control.sp_log_load calls;
  - a semicolon before every THROW.

Window parameters: every fact procedure takes @fecha_desde / @fecha_hasta.
  - Daily run:  EXEC gold.load_fact_facturas;               (NULL -> current + previous month)
  - Prototype:  EXEC gold.load_fact_facturas '2026-07-01';   (July onwards)
  - Backfill:   EXEC gold.load_fact_facturas '2022-01-01', '2023-01-01';  (one fiscal year, oldest first,
                same 2GB-log discipline as silver's backfill: split in halves on Msg 9002)
The REVERTIDO step (a row that was ABIERTO and is now in neither source) only
runs in daily mode (@fecha_hasta IS NULL) - a bounded backfill can't judge it.
===============================================================================
*/

-- ============================================================================
-- 0. gold.load_dim_tipo_documento - static catalog, full reload (20 rows + 3
--    types seen in data or config but outside the business catalog)
-- ============================================================================
IF OBJECT_ID('gold.load_dim_tipo_documento', 'P') IS NOT NULL DROP PROCEDURE gold.load_dim_tipo_documento;
GO
CREATE PROCEDURE gold.load_dim_tipo_documento
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @n INT;

    DELETE FROM gold.dim_tipo_documento;

    INSERT INTO gold.dim_tipo_documento
        (clase_documento, descripcion_sap, descripcion_anterior, familia, signo_esperado, es_ancla_compensacion, lado_aplicacion, en_alcance_aplicacion, clase_anulacion, clases_cuenta, rango_numeros, nota)
    VALUES
    ('F1', 'Fact Nacional CIOSA',    'FACT',           'FACTURA',       'S', 0, 'RECIBE',  1, 'Z1', 'ADS',   'F1', 'Debt. Receiving side.'),
    ('F2', 'Fact Otras Ven CIOSA',   'FACT',           'FACTURA',       'S', 0, 'RECIBE',  1, 'Z1', 'ADS',   'F2', 'Debt. Receiving side.'),
    ('F3', 'Fact Export. CIOSA',     'FACT',           'FACTURA',       'S', 0, 'RECIBE',  1, 'Z1', 'ADS',   'F3', 'Debt. Receiving side.'),
    ('F4', 'Fact Digital CIOSA',     'FACT',           'FACTURA',       'S', 0, 'RECIBE',  1, 'Z1', 'ADS',   'F4', 'Debt. Receiving side. Largest invoice type (2.7M lines).'),
    ('F5', 'Fact POS CIOSA',         'FACT',           'FACTURA',       'S', 0, 'RECIBE',  1, 'Z1', 'ADS',   'F5', 'Debt, POS (channel 20). Paid almost exclusively by CP via REBZG.'),
    ('F6', 'Fact Outlet CIOSA',      'FACT',           'FACTURA',       'S', 0, 'RECIBE',  1, 'Z1', 'ADS',   'F6', 'Configured, 0 rows ever in bsid/bsad (checked 2026-09-03).'),
    ('D1', 'Nota de Débito CIOSA',   'NOTA DE DEBITO', 'NOTA_DEBITO',   'S', 0, 'RECIBE',  1, 'Z4', 'ADS',   'D1', 'DEBT, not a credit note ($2.7M on S vs $1.4K on H). Receiving side. Z4 reversal type never used.'),
    ('C1', 'Dev. Nacional CIOSA',    'DEVO',           'DEVOLUCION',    'H', 0, 'APLICA',  1, 'Z2', 'ADS',   'C1', 'Reduces debt. REBZG on 95% of lines, never anchors a group.'),
    ('C3', 'Dev. Exporta CIOSA',     'DEVO',           'DEVOLUCION',    'H', 0, 'APLICA',  1, 'Z2', 'ADS',   'C3', 'Reduces debt. 11 lines in all history.'),
    ('C4', 'Dev. POS CIOSA',         'DEVO',           'DEVOLUCION',    'H', 0, 'APLICA',  1, 'Z2', 'ADS',   'C4', 'Reduces debt, POS. REBZG on 99.7% of lines.'),
    ('C5', 'Nota de Crédit CIOSA',   'NOTA DE CREDITO','NOTA_CREDITO',  'H', 0, 'APLICA',  1, 'Z3', 'ADS',   'C5', 'Reduces debt. REBZG on 87.5% of lines.'),
    ('DZ', 'Pago de deudor',         'PAGO',           'PAGO',          'H', 0, 'APLICA',  1, 'DZ', 'ADS',   '14', 'Cash. Virgin deposit = key 11 + REBZG=V (custom program OS_APPLICATION); key 15 with REBZG = referenced payment (R1); key 08 = child mirror; key 02/05 = FB08 reversal (R2b). Reverses with DZ, not a Z type.'),
    ('CP', 'Cobranza POS',           'PAGO',           'PAGO',          'H', 0, 'APLICA',  1, 'CP', 'DS',    'CP', 'Cash, POS. 93.8% of lines carry REBZG straight to F5 (R1). 99.6% of the money is channel 20. Key 05 = FB08 reversal by the POS interface.'),
    ('AB', 'Documento contable',     'AJUSTE',         'AJUSTE',        NULL,1, 'APLICA',  1, 'AB', 'ADKMS', '85', 'What FB1D creates. Role by posting key: 07/17 at $0 = anchor; 07 with amount = consumes a credit; 17 with amount = re-applies it (R5); 15 = credit balance from pool 10006317; 01/11 = manual.'),
    ('Z1', 'Anulacion Fact CIOSA',   NULL,             'ANULACION',     'H', 1, 'NINGUNO', 1, NULL, 'ADS',   'Z3', 'Cancels F1-F6 (99% F5) sharing the group at the identical amount -> anulada flag on the invoice (R2a). Never a row of its own.'),
    ('Z2', 'Anul. Dev. Venta',       NULL,             'ANULACION',     'S', 1, 'NINGUNO', 1, NULL, 'ADS',   'Z3', 'Cancels C1/C3/C4 -> anulada flag on the note (R2a).'),
    ('Z3', 'Anul. NC',               NULL,             'ANULACION',     'S', 1, 'NINGUNO', 1, NULL, 'ADS',   'Z3', 'Cancels C5 -> anulada flag on the note (R2a).'),
    ('Z4', 'Anul. ND (inferred)',    NULL,             'ANULACION',     'H', 1, 'NINGUNO', 1, NULL, NULL,    NULL, 'T003.STBLA of D1. Never used (0 rows). Description inferred, not read from T003T.'),
    ('ZY', 'Doc. Pago D y K',        NULL,             'TECNICO',       'H', 0, 'NINGUNO', 0, 'ZZ', 'DKS',   'ZQ', 'D y K = Deudores y Kreditoren. Corporate credit-card reconciliation on prefix-9 technical accounts (100% of rows). NOT a customer payment. Excluded.'),
    ('SA', 'Documento cta.mayor',    NULL,             'TECNICO',       NULL,1, 'NINGUNO', 0, 'ZZ', 'ADKMS', '10', 'G/L journal. Transit account inside the POS settlement flow (1.4M groups with CP/F5), marketplace commission accruals, balance clean-up, refunds (REEM*). Excluded except the REEM* exclusion signal on payments.'),
    ('SI', 'Saldos Iniciales',       'SALDO INICIAL',  'TECNICO',       'S', 0, 'NINGUNO', 0, 'ZZ', 'ADKMS', '10', 'Opening balances. 1 row in bsid (2015), 0 in bsad: outside the 2022+ data window.'),
    ('ZZ', 'Doc. Anulacion',         NULL,             'ANULACION',     NULL,1, 'NINGUNO', 0, NULL, NULL,    NULL, 'FB08 reversal document, always of an SA (97,584 groups, 100% net zero). 99% = cancelled POS receipts by the interface user. Excluded. STBLA/KOARS not read from T003.'),
    ('DI', 'Dist.Ingresos POS',      NULL,             'TECNICO',       NULL,0, 'NINGUNO', 0, NULL, NULL,    NULL, '2 rows in all history, one self-cancelling pair. Excluded. STBLA/KOARS not read from T003.');

    SELECT @n = COUNT(*) FROM gold.dim_tipo_documento;
    PRINT 'gold.dim_tipo_documento: ' + CAST(@n AS VARCHAR) + ' rows (expected 23: 20 business-catalog types + Z4, ZZ, DI)';
END;
GO
PRINT 'Procedure gold.load_dim_tipo_documento created.';
GO

-- ============================================================================
-- 1. gold.load_fact_facturas
-- ============================================================================
IF OBJECT_ID('gold.load_fact_facturas', 'P') IS NOT NULL DROP PROCEDURE gold.load_fact_facturas;
GO
CREATE PROCEDURE gold.load_fact_facturas
    @fecha_desde DATE = NULL,   -- lower bound on fecha_compensacion for bsad rows; NULL = first day of previous month
    @fecha_hasta DATE = NULL    -- exclusive upper bound; NULL = daily mode (no upper bound, REVERTIDO step runs)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @start_time DATETIME = GETDATE();
    DECLARE @n_stage INT, @n_upd INT, @n_ins INT, @n_rev INT, @n_anul INT;

    IF @fecha_desde IS NULL
        SET @fecha_desde = DATEADD(MONTH, DATEDIFF(MONTH, 0, GETDATE()) - 1, 0);

    BEGIN TRY
        PRINT '>> gold.load_fact_facturas | window fecha_compensacion >= ' + CONVERT(VARCHAR(10), @fecha_desde, 120)
            + CASE WHEN @fecha_hasta IS NULL THEN ' (daily mode)' ELSE ' and < ' + CONVERT(VARCHAR(10), @fecha_hasta, 120) + ' (bounded)' END;

        -- ------------------------------------------------------------------
        -- Step 1: stage. Open items (all of them - bsid is a full mirror) plus
        -- cleared items inside the window. Debt types only.
        -- ------------------------------------------------------------------
        IF OBJECT_ID('tempdb..#stage') IS NOT NULL DROP TABLE #stage;

        SELECT
            b.sociedad, b.cliente_id, b.ejercicio, b.documento_id, b.posicion,
            b.clase_documento, b.clave_contabilizacion, b.debe_haber,
            CAST('ABIERTO' AS VARCHAR(10)) AS estado_sap,
            b.fecha_documento, b.fecha_contabilizacion, b.fecha_registro_sistema, b.fecha_vencimiento,
            b.condicion_pago, b.dias_plazo,
            b.monto_moneda_local, b.monto_moneda_doc, b.moneda,
            CAST(NULL AS VARCHAR(10)) AS documento_compensacion,
            CAST(NULL AS INT)         AS ejercicio_compensacion,
            CAST(NULL AS DATE)        AS fecha_compensacion,
            b.documento_ventas, b.referencia, b.asignacion
        INTO #stage
        FROM silver.sap_bsid b
        WHERE b.mandante = '400'
          AND b.clase_documento IN ('F1','F2','F3','F4','F5','F6','D1')
          AND @fecha_hasta IS NULL;   -- open items only make sense in daily mode; a bounded backfill loads cleared history only

        -- bsid WINS over bsad on the same PK. bronze.sap_bsad / silver.sap_bsad are
        -- incremental MERGEs that never delete: when SAP resets a clearing (FBRA) the
        -- line goes back to BSID and disappears from BSAD in SAP, but its old cleared
        -- copy stays in our bsad forever (49 debt lines as of 2026-09-03). Today's bsid
        -- is a full mirror, so it is the truth for anything it contains.
        INSERT INTO #stage
        SELECT
            b.sociedad, b.cliente_id, b.ejercicio, b.documento_id, b.posicion,
            b.clase_documento, b.clave_contabilizacion, b.debe_haber,
            'COMPENSADO',
            b.fecha_documento, b.fecha_contabilizacion, b.fecha_registro_sistema, b.fecha_vencimiento,
            b.condicion_pago, b.dias_plazo,
            b.monto_moneda_local, b.monto_moneda_doc, b.moneda,
            b.documento_compensacion, b.ejercicio_compensacion, b.fecha_compensacion,
            b.documento_ventas, b.referencia, b.asignacion
        FROM silver.sap_bsad b
        WHERE b.mandante = '400'
          AND b.clase_documento IN ('F1','F2','F3','F4','F5','F6','D1')
          AND b.fecha_compensacion >= @fecha_desde
          AND (@fecha_hasta IS NULL OR b.fecha_compensacion < @fecha_hasta)
          AND NOT EXISTS (
              SELECT 1 FROM #stage s
              WHERE s.sociedad = b.sociedad AND s.cliente_id = b.cliente_id AND s.ejercicio = b.ejercicio
                AND s.documento_id = b.documento_id AND s.posicion = b.posicion
          );

        SELECT @n_stage = COUNT(*) FROM #stage;
        CREATE UNIQUE CLUSTERED INDEX IX_stage ON #stage (sociedad, cliente_id, ejercicio, documento_id, posicion);

        -- ------------------------------------------------------------------
        -- Step 2: cancellation (rule R2a). A Z1 line in the same compensation
        -- group with the identical amount cancels the invoice.
        -- ------------------------------------------------------------------
        IF OBJECT_ID('tempdb..#anul') IS NOT NULL DROP TABLE #anul;

        SELECT s.sociedad, s.cliente_id, s.ejercicio, s.documento_id, s.posicion,
               MIN(z.documento_id) AS documento_anulacion, MIN(z.fecha_contabilizacion) AS fecha_anulacion
        INTO #anul
        FROM #stage s
        JOIN silver.sap_bsad z
          ON  z.mandante = '400'
          AND z.clase_documento = 'Z1'
          AND z.documento_compensacion = s.documento_compensacion
          AND z.ejercicio_compensacion = s.ejercicio_compensacion
          AND z.monto_moneda_local = s.monto_moneda_local
          AND z.debe_haber <> s.debe_haber
        WHERE s.estado_sap = 'COMPENSADO'
        GROUP BY s.sociedad, s.cliente_id, s.ejercicio, s.documento_id, s.posicion;
        SET @n_anul = @@ROWCOUNT;

        -- ------------------------------------------------------------------
        -- Step 3: SCD2 keys, resolved temporally on fecha_contabilizacion.
        -- Current versions carry fecha_fin_vigencia = NULL (27,170 of 28,756
        -- rows in dim_cliente_comercial on 2026-09-03), so BETWEEN would drop
        -- every customer without a historical change - the open-ended test
        -- below is the one that works.
        -- ------------------------------------------------------------------
        IF OBJECT_ID('tempdb..#sk') IS NOT NULL DROP TABLE #sk;

        SELECT s.sociedad, s.cliente_id, s.ejercicio, s.documento_id, s.posicion,
               dcc.id_surrogate AS cliente_comercial_sk,
               dck.id_surrogate AS cliente_credito_sk
        INTO #sk
        FROM #stage s
        LEFT JOIN gold.dim_cliente_comercial dcc
               ON dcc.cliente_id = s.cliente_id
              AND s.fecha_contabilizacion >= dcc.fecha_inicio_vigencia
              AND (dcc.fecha_fin_vigencia IS NULL OR s.fecha_contabilizacion <= dcc.fecha_fin_vigencia)
        LEFT JOIN gold.dim_cliente_credito dck
               ON dck.cliente_id = s.cliente_id
              AND s.fecha_contabilizacion >= dck.fecha_inicio_vigencia
              AND (dck.fecha_fin_vigencia IS NULL OR s.fecha_contabilizacion <= dck.fecha_fin_vigencia);

        -- ------------------------------------------------------------------
        -- Step 4: UPDATE existing rows by PK (state transition ABIERTO ->
        -- COMPENSADO happens here: same PK, new state and clearing fields).
        -- ------------------------------------------------------------------
        UPDATE f
        SET f.clase_documento        = s.clase_documento,
            f.clave_contabilizacion  = s.clave_contabilizacion,
            f.debe_haber             = s.debe_haber,
            f.estado_sap             = s.estado_sap,
            f.fecha_documento        = s.fecha_documento,
            f.fecha_contabilizacion  = s.fecha_contabilizacion,
            f.fecha_registro_sistema = s.fecha_registro_sistema,
            f.fecha_vencimiento      = s.fecha_vencimiento,
            f.condicion_pago         = s.condicion_pago,
            f.dias_plazo             = s.dias_plazo,
            f.monto_moneda_local     = s.monto_moneda_local,
            f.monto_moneda_doc       = s.monto_moneda_doc,
            f.moneda                 = s.moneda,
            f.documento_compensacion = s.documento_compensacion,
            f.ejercicio_compensacion = s.ejercicio_compensacion,
            f.fecha_compensacion     = s.fecha_compensacion,
            f.documento_ventas       = s.documento_ventas,
            f.referencia             = s.referencia,
            f.asignacion             = s.asignacion,
            f.anulada                = CASE WHEN a.documento_anulacion IS NULL THEN 0 ELSE 1 END,
            f.documento_anulacion    = a.documento_anulacion,
            f.fecha_anulacion        = a.fecha_anulacion,
            f.cliente_comercial_sk   = k.cliente_comercial_sk,
            f.cliente_credito_sk     = k.cliente_credito_sk,
            f.fecha_actualizacion    = GETDATE()
        FROM gold.fact_facturas f
        JOIN #stage s
          ON  s.sociedad = f.sociedad AND s.cliente_id = f.cliente_id AND s.ejercicio = f.ejercicio
          AND s.documento_id = f.documento_id AND s.posicion = f.posicion
        LEFT JOIN #anul a
          ON  a.sociedad = s.sociedad AND a.cliente_id = s.cliente_id AND a.ejercicio = s.ejercicio
          AND a.documento_id = s.documento_id AND a.posicion = s.posicion
        LEFT JOIN #sk k
          ON  k.sociedad = s.sociedad AND k.cliente_id = s.cliente_id AND k.ejercicio = s.ejercicio
          AND k.documento_id = s.documento_id AND k.posicion = s.posicion;
        SET @n_upd = @@ROWCOUNT;

        -- ------------------------------------------------------------------
        -- Step 5: INSERT new rows.
        -- ------------------------------------------------------------------
        INSERT INTO gold.fact_facturas (
            sociedad, cliente_id, ejercicio, documento_id, posicion,
            clase_documento, clave_contabilizacion, debe_haber, estado_sap,
            fecha_documento, fecha_contabilizacion, fecha_registro_sistema, fecha_vencimiento,
            condicion_pago, dias_plazo, monto_moneda_local, monto_moneda_doc, moneda,
            documento_compensacion, ejercicio_compensacion, fecha_compensacion,
            documento_ventas, referencia, asignacion,
            anulada, documento_anulacion, fecha_anulacion,
            cliente_comercial_sk, cliente_credito_sk
        )
        SELECT
            s.sociedad, s.cliente_id, s.ejercicio, s.documento_id, s.posicion,
            s.clase_documento, s.clave_contabilizacion, s.debe_haber, s.estado_sap,
            s.fecha_documento, s.fecha_contabilizacion, s.fecha_registro_sistema, s.fecha_vencimiento,
            s.condicion_pago, s.dias_plazo, s.monto_moneda_local, s.monto_moneda_doc, s.moneda,
            s.documento_compensacion, s.ejercicio_compensacion, s.fecha_compensacion,
            s.documento_ventas, s.referencia, s.asignacion,
            CASE WHEN a.documento_anulacion IS NULL THEN 0 ELSE 1 END, a.documento_anulacion, a.fecha_anulacion,
            k.cliente_comercial_sk, k.cliente_credito_sk
        FROM #stage s
        LEFT JOIN #anul a
          ON  a.sociedad = s.sociedad AND a.cliente_id = s.cliente_id AND a.ejercicio = s.ejercicio
          AND a.documento_id = s.documento_id AND a.posicion = s.posicion
        LEFT JOIN #sk k
          ON  k.sociedad = s.sociedad AND k.cliente_id = s.cliente_id AND k.ejercicio = s.ejercicio
          AND k.documento_id = s.documento_id AND k.posicion = s.posicion
        WHERE NOT EXISTS (
            SELECT 1 FROM gold.fact_facturas f
            WHERE f.sociedad = s.sociedad AND f.cliente_id = s.cliente_id AND f.ejercicio = s.ejercicio
              AND f.documento_id = s.documento_id AND f.posicion = s.posicion
        );
        SET @n_ins = @@ROWCOUNT;

        -- ------------------------------------------------------------------
        -- Step 6 (daily mode only): a row that was ABIERTO and is now in
        -- neither source is marked REVERTIDO - never deleted, it may already
        -- have rows in fact_aplicacion.
        -- ------------------------------------------------------------------
        SET @n_rev = 0;
        IF @fecha_hasta IS NULL
        BEGIN
            UPDATE f
            SET f.estado_sap = 'REVERTIDO', f.fecha_actualizacion = GETDATE()
            FROM gold.fact_facturas f
            WHERE f.estado_sap = 'ABIERTO'
              AND NOT EXISTS (
                  SELECT 1 FROM #stage s
                  WHERE s.sociedad = f.sociedad AND s.cliente_id = f.cliente_id AND s.ejercicio = f.ejercicio
                    AND s.documento_id = f.documento_id AND s.posicion = f.posicion
              );
            SET @n_rev = @@ROWCOUNT;
        END

        PRINT 'staged: ' + CAST(@n_stage AS VARCHAR) + ' | updated: ' + CAST(@n_upd AS VARCHAR)
            + ' | inserted: ' + CAST(@n_ins AS VARCHAR) + ' | anuladas in window: ' + CAST(@n_anul AS VARCHAR)
            + ' | marked REVERTIDO: ' + CAST(@n_rev AS VARCHAR)
            + ' | ' + CAST(DATEDIFF(SECOND, @start_time, GETDATE()) AS VARCHAR) + ' s';
    END TRY
    BEGIN CATCH
        PRINT 'ERROR in gold.load_fact_facturas: ' + ERROR_MESSAGE();
        THROW;
    END CATCH;
END;
GO
PRINT 'Procedure gold.load_fact_facturas created.';
GO

-- ============================================================================
-- 2. gold.load_fact_notas - same steps as load_fact_facturas; cancellation
--    comes from Z2 (C1/C3/C4) or Z3 (C5) instead of Z1.
-- ============================================================================
IF OBJECT_ID('gold.load_fact_notas', 'P') IS NOT NULL DROP PROCEDURE gold.load_fact_notas;
GO
CREATE PROCEDURE gold.load_fact_notas
    @fecha_desde DATE = NULL,
    @fecha_hasta DATE = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @start_time DATETIME = GETDATE();
    DECLARE @n_stage INT, @n_upd INT, @n_ins INT, @n_rev INT, @n_anul INT;

    IF @fecha_desde IS NULL
        SET @fecha_desde = DATEADD(MONTH, DATEDIFF(MONTH, 0, GETDATE()) - 1, 0);

    BEGIN TRY
        PRINT '>> gold.load_fact_notas | window fecha_compensacion >= ' + CONVERT(VARCHAR(10), @fecha_desde, 120)
            + CASE WHEN @fecha_hasta IS NULL THEN ' (daily mode)' ELSE ' and < ' + CONVERT(VARCHAR(10), @fecha_hasta, 120) + ' (bounded)' END;

        -- Step 1: stage (bsid wins over bsad on the same PK - see load_fact_facturas)
        IF OBJECT_ID('tempdb..#stage') IS NOT NULL DROP TABLE #stage;

        SELECT
            b.sociedad, b.cliente_id, b.ejercicio, b.documento_id, b.posicion,
            b.clase_documento, b.clave_contabilizacion, b.debe_haber,
            CAST('ABIERTO' AS VARCHAR(10)) AS estado_sap,
            b.fecha_documento, b.fecha_contabilizacion, b.fecha_registro_sistema, b.fecha_vencimiento,
            b.monto_moneda_local, b.monto_moneda_doc, b.moneda,
            CAST(NULL AS VARCHAR(10)) AS documento_compensacion,
            CAST(NULL AS INT)         AS ejercicio_compensacion,
            CAST(NULL AS DATE)        AS fecha_compensacion,
            b.sgtxt, b.factura_referencia_documento, b.factura_referencia_ejercicio, b.factura_referencia_posicion,
            b.documento_ventas, b.referencia, b.asignacion
        INTO #stage
        FROM silver.sap_bsid b
        WHERE b.mandante = '400'
          AND b.clase_documento IN ('C1','C3','C4','C5')
          AND @fecha_hasta IS NULL;

        INSERT INTO #stage
        SELECT
            b.sociedad, b.cliente_id, b.ejercicio, b.documento_id, b.posicion,
            b.clase_documento, b.clave_contabilizacion, b.debe_haber,
            'COMPENSADO',
            b.fecha_documento, b.fecha_contabilizacion, b.fecha_registro_sistema, b.fecha_vencimiento,
            b.monto_moneda_local, b.monto_moneda_doc, b.moneda,
            b.documento_compensacion, b.ejercicio_compensacion, b.fecha_compensacion,
            b.sgtxt, b.factura_referencia_documento, b.factura_referencia_ejercicio, b.factura_referencia_posicion,
            b.documento_ventas, b.referencia, b.asignacion
        FROM silver.sap_bsad b
        WHERE b.mandante = '400'
          AND b.clase_documento IN ('C1','C3','C4','C5')
          AND b.fecha_compensacion >= @fecha_desde
          AND (@fecha_hasta IS NULL OR b.fecha_compensacion < @fecha_hasta)
          AND NOT EXISTS (
              SELECT 1 FROM #stage s
              WHERE s.sociedad = b.sociedad AND s.cliente_id = b.cliente_id AND s.ejercicio = b.ejercicio
                AND s.documento_id = b.documento_id AND s.posicion = b.posicion
          );

        SELECT @n_stage = COUNT(*) FROM #stage;
        CREATE UNIQUE CLUSTERED INDEX IX_stage ON #stage (sociedad, cliente_id, ejercicio, documento_id, posicion);

        -- Step 2: cancellation (R2a). Z2 cancels C1/C3/C4, Z3 cancels C5 - same group, identical amount, opposite side.
        IF OBJECT_ID('tempdb..#anul') IS NOT NULL DROP TABLE #anul;

        SELECT s.sociedad, s.cliente_id, s.ejercicio, s.documento_id, s.posicion,
               MIN(z.documento_id) AS documento_anulacion, MIN(z.fecha_contabilizacion) AS fecha_anulacion
        INTO #anul
        FROM #stage s
        JOIN silver.sap_bsad z
          ON  z.mandante = '400'
          AND z.clase_documento = CASE WHEN s.clase_documento = 'C5' THEN 'Z3' ELSE 'Z2' END
          AND z.documento_compensacion = s.documento_compensacion
          AND z.ejercicio_compensacion = s.ejercicio_compensacion
          AND z.monto_moneda_local = s.monto_moneda_local
          AND z.debe_haber <> s.debe_haber
        WHERE s.estado_sap = 'COMPENSADO'
        GROUP BY s.sociedad, s.cliente_id, s.ejercicio, s.documento_id, s.posicion;
        SET @n_anul = @@ROWCOUNT;

        -- Step 3: SCD2 keys (open-ended fecha_fin_vigencia, see load_fact_facturas)
        IF OBJECT_ID('tempdb..#sk') IS NOT NULL DROP TABLE #sk;

        SELECT s.sociedad, s.cliente_id, s.ejercicio, s.documento_id, s.posicion,
               dcc.id_surrogate AS cliente_comercial_sk,
               dck.id_surrogate AS cliente_credito_sk
        INTO #sk
        FROM #stage s
        LEFT JOIN gold.dim_cliente_comercial dcc
               ON dcc.cliente_id = s.cliente_id
              AND s.fecha_contabilizacion >= dcc.fecha_inicio_vigencia
              AND (dcc.fecha_fin_vigencia IS NULL OR s.fecha_contabilizacion <= dcc.fecha_fin_vigencia)
        LEFT JOIN gold.dim_cliente_credito dck
               ON dck.cliente_id = s.cliente_id
              AND s.fecha_contabilizacion >= dck.fecha_inicio_vigencia
              AND (dck.fecha_fin_vigencia IS NULL OR s.fecha_contabilizacion <= dck.fecha_fin_vigencia);

        -- Step 4: UPDATE existing rows by PK
        UPDATE f
        SET f.clase_documento        = s.clase_documento,
            f.clave_contabilizacion  = s.clave_contabilizacion,
            f.debe_haber             = s.debe_haber,
            f.estado_sap             = s.estado_sap,
            f.fecha_documento        = s.fecha_documento,
            f.fecha_contabilizacion  = s.fecha_contabilizacion,
            f.fecha_registro_sistema = s.fecha_registro_sistema,
            f.fecha_vencimiento      = s.fecha_vencimiento,
            f.monto_moneda_local     = s.monto_moneda_local,
            f.monto_moneda_doc       = s.monto_moneda_doc,
            f.moneda                 = s.moneda,
            f.documento_compensacion = s.documento_compensacion,
            f.ejercicio_compensacion = s.ejercicio_compensacion,
            f.fecha_compensacion     = s.fecha_compensacion,
            f.sgtxt                  = s.sgtxt,
            f.factura_referencia_documento = s.factura_referencia_documento,
            f.factura_referencia_ejercicio = s.factura_referencia_ejercicio,
            f.factura_referencia_posicion  = s.factura_referencia_posicion,
            f.documento_ventas       = s.documento_ventas,
            f.referencia             = s.referencia,
            f.asignacion             = s.asignacion,
            f.anulada                = CASE WHEN a.documento_anulacion IS NULL THEN 0 ELSE 1 END,
            f.documento_anulacion    = a.documento_anulacion,
            f.fecha_anulacion        = a.fecha_anulacion,
            f.cliente_comercial_sk   = k.cliente_comercial_sk,
            f.cliente_credito_sk     = k.cliente_credito_sk,
            f.fecha_actualizacion    = GETDATE()
        FROM gold.fact_notas f
        JOIN #stage s
          ON  s.sociedad = f.sociedad AND s.cliente_id = f.cliente_id AND s.ejercicio = f.ejercicio
          AND s.documento_id = f.documento_id AND s.posicion = f.posicion
        LEFT JOIN #anul a
          ON  a.sociedad = s.sociedad AND a.cliente_id = s.cliente_id AND a.ejercicio = s.ejercicio
          AND a.documento_id = s.documento_id AND a.posicion = s.posicion
        LEFT JOIN #sk k
          ON  k.sociedad = s.sociedad AND k.cliente_id = s.cliente_id AND k.ejercicio = s.ejercicio
          AND k.documento_id = s.documento_id AND k.posicion = s.posicion;
        SET @n_upd = @@ROWCOUNT;

        -- Step 5: INSERT new rows
        INSERT INTO gold.fact_notas (
            sociedad, cliente_id, ejercicio, documento_id, posicion,
            clase_documento, clave_contabilizacion, debe_haber, estado_sap,
            fecha_documento, fecha_contabilizacion, fecha_registro_sistema, fecha_vencimiento,
            monto_moneda_local, monto_moneda_doc, moneda,
            documento_compensacion, ejercicio_compensacion, fecha_compensacion,
            sgtxt, factura_referencia_documento, factura_referencia_ejercicio, factura_referencia_posicion,
            documento_ventas, referencia, asignacion,
            anulada, documento_anulacion, fecha_anulacion,
            cliente_comercial_sk, cliente_credito_sk
        )
        SELECT
            s.sociedad, s.cliente_id, s.ejercicio, s.documento_id, s.posicion,
            s.clase_documento, s.clave_contabilizacion, s.debe_haber, s.estado_sap,
            s.fecha_documento, s.fecha_contabilizacion, s.fecha_registro_sistema, s.fecha_vencimiento,
            s.monto_moneda_local, s.monto_moneda_doc, s.moneda,
            s.documento_compensacion, s.ejercicio_compensacion, s.fecha_compensacion,
            s.sgtxt, s.factura_referencia_documento, s.factura_referencia_ejercicio, s.factura_referencia_posicion,
            s.documento_ventas, s.referencia, s.asignacion,
            CASE WHEN a.documento_anulacion IS NULL THEN 0 ELSE 1 END, a.documento_anulacion, a.fecha_anulacion,
            k.cliente_comercial_sk, k.cliente_credito_sk
        FROM #stage s
        LEFT JOIN #anul a
          ON  a.sociedad = s.sociedad AND a.cliente_id = s.cliente_id AND a.ejercicio = s.ejercicio
          AND a.documento_id = s.documento_id AND a.posicion = s.posicion
        LEFT JOIN #sk k
          ON  k.sociedad = s.sociedad AND k.cliente_id = s.cliente_id AND k.ejercicio = s.ejercicio
          AND k.documento_id = s.documento_id AND k.posicion = s.posicion
        WHERE NOT EXISTS (
            SELECT 1 FROM gold.fact_notas f
            WHERE f.sociedad = s.sociedad AND f.cliente_id = s.cliente_id AND f.ejercicio = s.ejercicio
              AND f.documento_id = s.documento_id AND f.posicion = s.posicion
        );
        SET @n_ins = @@ROWCOUNT;

        -- Step 6 (daily mode only): REVERTIDO
        SET @n_rev = 0;
        IF @fecha_hasta IS NULL
        BEGIN
            UPDATE f
            SET f.estado_sap = 'REVERTIDO', f.fecha_actualizacion = GETDATE()
            FROM gold.fact_notas f
            WHERE f.estado_sap = 'ABIERTO'
              AND NOT EXISTS (
                  SELECT 1 FROM #stage s
                  WHERE s.sociedad = f.sociedad AND s.cliente_id = f.cliente_id AND s.ejercicio = f.ejercicio
                    AND s.documento_id = f.documento_id AND s.posicion = f.posicion
              );
            SET @n_rev = @@ROWCOUNT;
        END

        PRINT 'staged: ' + CAST(@n_stage AS VARCHAR) + ' | updated: ' + CAST(@n_upd AS VARCHAR)
            + ' | inserted: ' + CAST(@n_ins AS VARCHAR) + ' | anuladas in window: ' + CAST(@n_anul AS VARCHAR)
            + ' | marked REVERTIDO: ' + CAST(@n_rev AS VARCHAR)
            + ' | ' + CAST(DATEDIFF(SECOND, @start_time, GETDATE()) AS VARCHAR) + ' s';
    END TRY
    BEGIN CATCH
        PRINT 'ERROR in gold.load_fact_notas: ' + ERROR_MESSAGE();
        THROW;
    END CATCH;
END;
GO
PRINT 'Procedure gold.load_fact_notas created.';
GO

-- ============================================================================
-- 3. gold.load_fact_pagos
-- ============================================================================
IF OBJECT_ID('gold.load_fact_pagos', 'P') IS NOT NULL DROP PROCEDURE gold.load_fact_pagos;
GO
CREATE PROCEDURE gold.load_fact_pagos
    @fecha_desde DATE = NULL,
    @fecha_hasta DATE = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @start_time DATETIME = GETDATE();
    DECLARE @n_stage INT, @n_upd INT, @n_ins INT, @n_rev INT, @n_revertidos INT, @n_reemb INT;

    IF @fecha_desde IS NULL
        SET @fecha_desde = DATEADD(MONTH, DATEDIFF(MONTH, 0, GETDATE()) - 1, 0);

    BEGIN TRY
        PRINT '>> gold.load_fact_pagos | window fecha_compensacion >= ' + CONVERT(VARCHAR(10), @fecha_desde, 120)
            + CASE WHEN @fecha_hasta IS NULL THEN ' (daily mode)' ELSE ' and < ' + CONVERT(VARCHAR(10), @fecha_hasta, 120) + ' (bounded)' END;

        -- Step 1: stage (bsid wins over bsad on the same PK - see load_fact_facturas)
        IF OBJECT_ID('tempdb..#stage') IS NOT NULL DROP TABLE #stage;

        SELECT
            b.sociedad, b.cliente_id, b.ejercicio, b.documento_id, b.posicion,
            b.clase_documento, b.clave_contabilizacion, b.debe_haber,
            CAST('ABIERTO' AS VARCHAR(10)) AS estado_sap,
            b.fecha_documento, b.fecha_contabilizacion, b.fecha_registro_sistema, b.fecha_vencimiento,
            b.monto_moneda_local, b.monto_moneda_doc, b.moneda,
            CAST(NULL AS VARCHAR(10)) AS documento_compensacion,
            CAST(NULL AS INT)         AS ejercicio_compensacion,
            CAST(NULL AS DATE)        AS fecha_compensacion,
            b.sgtxt, b.factura_referencia_documento, b.factura_referencia_ejercicio, b.factura_referencia_posicion,
            b.referencia, b.asignacion
        INTO #stage
        FROM silver.sap_bsid b
        WHERE b.mandante = '400'
          AND b.clase_documento IN ('DZ','CP')
          AND @fecha_hasta IS NULL;

        INSERT INTO #stage
        SELECT
            b.sociedad, b.cliente_id, b.ejercicio, b.documento_id, b.posicion,
            b.clase_documento, b.clave_contabilizacion, b.debe_haber,
            'COMPENSADO',
            b.fecha_documento, b.fecha_contabilizacion, b.fecha_registro_sistema, b.fecha_vencimiento,
            b.monto_moneda_local, b.monto_moneda_doc, b.moneda,
            b.documento_compensacion, b.ejercicio_compensacion, b.fecha_compensacion,
            b.sgtxt, b.factura_referencia_documento, b.factura_referencia_ejercicio, b.factura_referencia_posicion,
            b.referencia, b.asignacion
        FROM silver.sap_bsad b
        WHERE b.mandante = '400'
          AND b.clase_documento IN ('DZ','CP')
          AND b.fecha_compensacion >= @fecha_desde
          AND (@fecha_hasta IS NULL OR b.fecha_compensacion < @fecha_hasta)
          AND NOT EXISTS (
              SELECT 1 FROM #stage s
              WHERE s.sociedad = b.sociedad AND s.cliente_id = b.cliente_id AND s.ejercicio = b.ejercicio
                AND s.documento_id = b.documento_id AND s.posicion = b.posicion
          );

        SELECT @n_stage = COUNT(*) FROM #stage;
        CREATE UNIQUE CLUSTERED INDEX IX_stage ON #stage (sociedad, cliente_id, ejercicio, documento_id, posicion);

        -- Step 2a: "child" documents = documents that at least one VIRGEN (key 11) points
        -- to through its documento_compensacion, over ALL history of bsad (an open virgin
        -- in bsid has no documento_compensacion yet, so it cannot define a child).
        IF OBJECT_ID('tempdb..#doc_hijo') IS NOT NULL DROP TABLE #doc_hijo;

        SELECT DISTINCT v.sociedad, v.ejercicio_compensacion AS ejercicio, v.documento_compensacion AS documento_id
        INTO #doc_hijo
        FROM silver.sap_bsad v
        WHERE v.mandante = '400' AND v.clase_documento = 'DZ' AND v.clave_contabilizacion = '11'
          AND v.documento_compensacion IS NOT NULL;
        CREATE UNIQUE CLUSTERED INDEX IX_hijo ON #doc_hijo (sociedad, ejercicio, documento_id);

        -- Step 2b: documents with a key-08 line (both sources, all history) - used only to
        -- tell a plain direct payment from a re-issued credit.
        IF OBJECT_ID('tempdb..#doc_con_08') IS NOT NULL DROP TABLE #doc_con_08;

        SELECT DISTINCT sociedad, ejercicio, documento_id
        INTO #doc_con_08
        FROM (
            SELECT sociedad, ejercicio, documento_id FROM silver.sap_bsad WHERE mandante = '400' AND clase_documento = 'DZ' AND clave_contabilizacion = '08'
            UNION ALL
            SELECT sociedad, ejercicio, documento_id FROM silver.sap_bsid WHERE mandante = '400' AND clase_documento = 'DZ' AND clave_contabilizacion = '08'
        ) x;
        CREATE UNIQUE CLUSTERED INDEX IX_doc08 ON #doc_con_08 (sociedad, ejercicio, documento_id);

        -- Step 2c: for non-child documents that carry a key-08 line, what does that 08 line
        -- consume? If its compensation group holds a DZ 11/15 credit of ANOTHER document,
        -- the 15 sibling is a re-issue of a deposit already counted (REEMISION_DZ).
        IF OBJECT_ID('tempdb..#reemision') IS NOT NULL DROP TABLE #reemision;

        SELECT o.sociedad, o.ejercicio, o.documento_id,
               CAST(CASE WHEN SUM(CASE WHEN g.clase_documento = 'DZ' AND g.clave_contabilizacion IN ('11','15') AND g.debe_haber = 'H' AND g.documento_id <> o.documento_id THEN 1 ELSE 0 END) > 0
                         THEN 'REEMISION_DZ' ELSE 'REEMISION_SA' END AS VARCHAR(16)) AS origen
        INTO #reemision
        FROM silver.sap_bsad o
        JOIN silver.sap_bsad g
          ON  g.mandante = '400'
          AND g.documento_compensacion = o.documento_compensacion
          AND g.ejercicio_compensacion = o.ejercicio_compensacion
        WHERE o.mandante = '400' AND o.clase_documento = 'DZ' AND o.clave_contabilizacion = '08'
          AND EXISTS (SELECT 1 FROM #stage s WHERE s.sociedad = o.sociedad AND s.ejercicio = o.ejercicio AND s.documento_id = o.documento_id)
          AND NOT EXISTS (SELECT 1 FROM #doc_hijo h WHERE h.sociedad = o.sociedad AND h.ejercicio = o.ejercicio AND h.documento_id = o.documento_id)
        GROUP BY o.sociedad, o.ejercicio, o.documento_id;
        CREATE UNIQUE CLUSTERED INDEX IX_reem ON #reemision (sociedad, ejercicio, documento_id);

        -- Step 3: line classification
        IF OBJECT_ID('tempdb..#clas') IS NOT NULL DROP TABLE #clas;

        SELECT s.sociedad, s.cliente_id, s.ejercicio, s.documento_id, s.posicion,
               CAST(CASE
                    WHEN s.clave_contabilizacion IN ('02','05','12') THEN 'REVERSO'
                    WHEN s.clase_documento = 'CP' AND s.clave_contabilizacion = '15' THEN 'PAGO_DIRECTO'
                    WHEN s.clase_documento = 'DZ' AND s.clave_contabilizacion = '11' THEN 'VIRGEN'
                    WHEN s.clase_documento = 'DZ' AND s.clave_contabilizacion = '08' AND h.documento_id IS NOT NULL THEN 'ESPEJO_HIJO'
                    WHEN s.clase_documento = 'DZ' AND s.clave_contabilizacion = '08' THEN 'TRASPASO_08'
                    WHEN s.clase_documento = 'DZ' AND s.clave_contabilizacion = '07' THEN 'CONSUME_CREDITO'
                    WHEN s.clase_documento = 'DZ' AND s.clave_contabilizacion IN ('15','17','18') AND h.documento_id IS NOT NULL THEN 'APLICACION_HIJO'
                    WHEN s.clase_documento = 'DZ' AND s.clave_contabilizacion = '15' THEN 'PAGO_DIRECTO'
                    ELSE 'OTRO'
               END AS VARCHAR(16)) AS tipo_linea,
               CAST(CASE
                    WHEN s.clave_contabilizacion IN ('02','05','12') THEN NULL
                    WHEN s.clase_documento = 'DZ' AND s.clave_contabilizacion = '11' THEN 'BANCO'
                    WHEN s.clase_documento = 'CP' AND s.clave_contabilizacion = '15' THEN 'DIRECTO'
                    WHEN s.clase_documento = 'DZ' AND s.clave_contabilizacion = '15' AND h.documento_id IS NULL AND o8.documento_id IS NULL THEN 'DIRECTO'
                    WHEN s.clase_documento = 'DZ' AND s.clave_contabilizacion = '15' AND h.documento_id IS NULL AND o8.documento_id IS NOT NULL THEN ISNULL(r.origen, 'REEMISION_SA')
                    ELSE NULL
               END AS VARCHAR(16)) AS origen_efectivo
        INTO #clas
        FROM #stage s
        LEFT JOIN #doc_hijo h    ON h.sociedad = s.sociedad  AND h.ejercicio = s.ejercicio  AND h.documento_id = s.documento_id
        LEFT JOIN #doc_con_08 o8 ON o8.sociedad = s.sociedad AND o8.ejercicio = s.ejercicio AND o8.documento_id = s.documento_id
        LEFT JOIN #reemision r   ON r.sociedad = s.sociedad  AND r.ejercicio = s.ejercicio  AND r.documento_id = s.documento_id;
        CREATE UNIQUE CLUSTERED INDEX IX_clas ON #clas (sociedad, cliente_id, ejercicio, documento_id, posicion);

        -- Step 4: reversals (rule R2b). A cleared group made of exactly 2 documents of
        -- the same type, netting to zero, that contains a reversal key. Every line of
        -- the group is flagged; documento_reverso = the document carrying the key.
        IF OBJECT_ID('tempdb..#grupo_rev') IS NOT NULL DROP TABLE #grupo_rev;

        SELECT s.documento_compensacion, s.ejercicio_compensacion,
               MIN(CASE WHEN s.clave_contabilizacion IN ('02','05','12') THEN s.documento_id END) AS documento_reverso
        INTO #grupo_rev
        FROM #stage s
        WHERE s.estado_sap = 'COMPENSADO'
        GROUP BY s.documento_compensacion, s.ejercicio_compensacion
        HAVING COUNT(DISTINCT s.documento_id) = 2
           AND COUNT(DISTINCT s.clase_documento) = 1
           AND ABS(SUM(CASE WHEN s.debe_haber = 'S' THEN s.monto_moneda_local ELSE -s.monto_moneda_local END)) < 0.01
           AND SUM(CASE WHEN s.clave_contabilizacion IN ('02','05','12') THEN 1 ELSE 0 END) > 0;
        SET @n_revertidos = @@ROWCOUNT;

        -- Step 5: refund-bound deposits (the vw_pago_factura_simple rule, unchanged):
        -- exactly 1 cash candidate in the group and an SA 'REEM%' line matching it within $1.00.
        IF OBJECT_ID('tempdb..#reemb') IS NOT NULL DROP TABLE #reemb;

        SELECT c.documento_compensacion, c.ejercicio_compensacion, c.documento_id, sr.documento_reembolso
        INTO #reemb
        FROM (
            SELECT s.documento_compensacion, s.ejercicio_compensacion,
                   MIN(s.documento_id) AS documento_id, SUM(s.monto_moneda_local) AS monto, COUNT(*) AS candidatos
            FROM #stage s
            JOIN #clas k ON k.sociedad = s.sociedad AND k.cliente_id = s.cliente_id AND k.ejercicio = s.ejercicio AND k.documento_id = s.documento_id AND k.posicion = s.posicion
            WHERE s.estado_sap = 'COMPENSADO' AND k.origen_efectivo IN ('BANCO','DIRECTO','REEMISION_SA')
            GROUP BY s.documento_compensacion, s.ejercicio_compensacion
            HAVING COUNT(*) = 1
        ) c
        JOIN (
            SELECT documento_compensacion, ejercicio_compensacion, SUM(monto_moneda_local) AS monto_sa_reem, MIN(documento_id) AS documento_reembolso
            FROM silver.sap_bsad
            WHERE mandante = '400' AND clase_documento = 'SA' AND sgtxt LIKE 'REEM%'
            GROUP BY documento_compensacion, ejercicio_compensacion
        ) sr ON sr.documento_compensacion = c.documento_compensacion AND sr.ejercicio_compensacion = c.ejercicio_compensacion
        WHERE ABS(c.monto - sr.monto_sa_reem) < 1.0;
        SET @n_reemb = @@ROWCOUNT;

        -- Step 6: SCD2 keys (open-ended fecha_fin_vigencia)
        IF OBJECT_ID('tempdb..#sk') IS NOT NULL DROP TABLE #sk;

        SELECT s.sociedad, s.cliente_id, s.ejercicio, s.documento_id, s.posicion,
               dcc.id_surrogate AS cliente_comercial_sk,
               dck.id_surrogate AS cliente_credito_sk
        INTO #sk
        FROM #stage s
        LEFT JOIN gold.dim_cliente_comercial dcc
               ON dcc.cliente_id = s.cliente_id
              AND s.fecha_contabilizacion >= dcc.fecha_inicio_vigencia
              AND (dcc.fecha_fin_vigencia IS NULL OR s.fecha_contabilizacion <= dcc.fecha_fin_vigencia)
        LEFT JOIN gold.dim_cliente_credito dck
               ON dck.cliente_id = s.cliente_id
              AND s.fecha_contabilizacion >= dck.fecha_inicio_vigencia
              AND (dck.fecha_fin_vigencia IS NULL OR s.fecha_contabilizacion <= dck.fecha_fin_vigencia);

        -- Step 7: assemble the final staged row set once, so UPDATE and INSERT share it
        IF OBJECT_ID('tempdb..#final') IS NOT NULL DROP TABLE #final;

        SELECT s.*,
               k.tipo_linea,
               k.origen_efectivo,
               CAST(CASE WHEN k.origen_efectivo IN ('BANCO','DIRECTO','REEMISION_SA') THEN 1 ELSE 0 END AS BIT) AS es_efectivo,
               CAST(CASE WHEN k.tipo_linea = 'VIRGEN' THEN 1 ELSE 0 END AS BIT) AS es_pago_virgen,
               CAST(CASE WHEN s.sgtxt = 'Asignación Aut. Deposito' OR s.sgtxt LIKE 'BB%' THEN 1 ELSE 0 END AS BIT) AS texto_virgen_valido,
               CASE WHEN k.tipo_linea = 'VIRGEN' THEN s.documento_compensacion END AS documento_hijo,
               CASE WHEN k.tipo_linea = 'VIRGEN' THEN s.ejercicio_compensacion END AS ejercicio_hijo,
               CAST(CASE WHEN r.documento_compensacion IS NULL THEN 0 ELSE 1 END AS BIT) AS revertido,
               r.documento_reverso,
               CAST(CASE WHEN m.documento_compensacion IS NULL THEN 0 ELSE 1 END AS BIT) AS es_reembolso,
               m.documento_reembolso,
               sk.cliente_comercial_sk, sk.cliente_credito_sk
        INTO #final
        FROM #stage s
        JOIN #clas k ON k.sociedad = s.sociedad AND k.cliente_id = s.cliente_id AND k.ejercicio = s.ejercicio AND k.documento_id = s.documento_id AND k.posicion = s.posicion
        LEFT JOIN #grupo_rev r ON r.documento_compensacion = s.documento_compensacion AND r.ejercicio_compensacion = s.ejercicio_compensacion AND s.estado_sap = 'COMPENSADO'
        LEFT JOIN #reemb m ON m.documento_compensacion = s.documento_compensacion AND m.ejercicio_compensacion = s.ejercicio_compensacion AND m.documento_id = s.documento_id AND k.origen_efectivo IN ('BANCO','DIRECTO','REEMISION_SA')
        LEFT JOIN #sk sk ON sk.sociedad = s.sociedad AND sk.cliente_id = s.cliente_id AND sk.ejercicio = s.ejercicio AND sk.documento_id = s.documento_id AND sk.posicion = s.posicion;

        -- Step 8: UPDATE existing rows by PK
        UPDATE f
        SET f.clase_documento        = x.clase_documento,
            f.clave_contabilizacion  = x.clave_contabilizacion,
            f.debe_haber             = x.debe_haber,
            f.estado_sap             = x.estado_sap,
            f.tipo_linea             = x.tipo_linea,
            f.origen_efectivo        = x.origen_efectivo,
            f.es_efectivo            = x.es_efectivo,
            f.es_pago_virgen         = x.es_pago_virgen,
            f.texto_virgen_valido    = x.texto_virgen_valido,
            f.fecha_documento        = x.fecha_documento,
            f.fecha_contabilizacion  = x.fecha_contabilizacion,
            f.fecha_registro_sistema = x.fecha_registro_sistema,
            f.fecha_vencimiento      = x.fecha_vencimiento,
            f.monto_moneda_local     = x.monto_moneda_local,
            f.monto_moneda_doc       = x.monto_moneda_doc,
            f.moneda                 = x.moneda,
            f.documento_compensacion = x.documento_compensacion,
            f.ejercicio_compensacion = x.ejercicio_compensacion,
            f.fecha_compensacion     = x.fecha_compensacion,
            f.sgtxt                  = x.sgtxt,
            f.factura_referencia_documento = x.factura_referencia_documento,
            f.factura_referencia_ejercicio = x.factura_referencia_ejercicio,
            f.factura_referencia_posicion  = x.factura_referencia_posicion,
            f.documento_hijo         = x.documento_hijo,
            f.ejercicio_hijo         = x.ejercicio_hijo,
            f.revertido              = x.revertido,
            f.documento_reverso      = x.documento_reverso,
            f.es_reembolso           = x.es_reembolso,
            f.documento_reembolso    = x.documento_reembolso,
            f.referencia             = x.referencia,
            f.asignacion             = x.asignacion,
            f.cliente_comercial_sk   = x.cliente_comercial_sk,
            f.cliente_credito_sk     = x.cliente_credito_sk,
            f.fecha_actualizacion    = GETDATE()
        FROM gold.fact_pagos f
        JOIN #final x
          ON  x.sociedad = f.sociedad AND x.cliente_id = f.cliente_id AND x.ejercicio = f.ejercicio
          AND x.documento_id = f.documento_id AND x.posicion = f.posicion;
        SET @n_upd = @@ROWCOUNT;

        -- Step 9: INSERT new rows
        INSERT INTO gold.fact_pagos (
            sociedad, cliente_id, ejercicio, documento_id, posicion,
            clase_documento, clave_contabilizacion, debe_haber, estado_sap,
            tipo_linea, origen_efectivo, es_efectivo, es_pago_virgen, texto_virgen_valido,
            fecha_documento, fecha_contabilizacion, fecha_registro_sistema, fecha_vencimiento,
            monto_moneda_local, monto_moneda_doc, moneda,
            documento_compensacion, ejercicio_compensacion, fecha_compensacion,
            sgtxt, factura_referencia_documento, factura_referencia_ejercicio, factura_referencia_posicion,
            documento_hijo, ejercicio_hijo, revertido, documento_reverso, es_reembolso, documento_reembolso,
            referencia, asignacion, cliente_comercial_sk, cliente_credito_sk
        )
        SELECT
            x.sociedad, x.cliente_id, x.ejercicio, x.documento_id, x.posicion,
            x.clase_documento, x.clave_contabilizacion, x.debe_haber, x.estado_sap,
            x.tipo_linea, x.origen_efectivo, x.es_efectivo, x.es_pago_virgen, x.texto_virgen_valido,
            x.fecha_documento, x.fecha_contabilizacion, x.fecha_registro_sistema, x.fecha_vencimiento,
            x.monto_moneda_local, x.monto_moneda_doc, x.moneda,
            x.documento_compensacion, x.ejercicio_compensacion, x.fecha_compensacion,
            x.sgtxt, x.factura_referencia_documento, x.factura_referencia_ejercicio, x.factura_referencia_posicion,
            x.documento_hijo, x.ejercicio_hijo, x.revertido, x.documento_reverso, x.es_reembolso, x.documento_reembolso,
            x.referencia, x.asignacion, x.cliente_comercial_sk, x.cliente_credito_sk
        FROM #final x
        WHERE NOT EXISTS (
            SELECT 1 FROM gold.fact_pagos f
            WHERE f.sociedad = x.sociedad AND f.cliente_id = x.cliente_id AND f.ejercicio = x.ejercicio
              AND f.documento_id = x.documento_id AND f.posicion = x.posicion
        );
        SET @n_ins = @@ROWCOUNT;

        -- Step 10 (daily mode only): REVERTIDO state for rows gone from both sources
        SET @n_rev = 0;
        IF @fecha_hasta IS NULL
        BEGIN
            UPDATE f
            SET f.estado_sap = 'REVERTIDO', f.fecha_actualizacion = GETDATE()
            FROM gold.fact_pagos f
            WHERE f.estado_sap = 'ABIERTO'
              AND NOT EXISTS (
                  SELECT 1 FROM #stage s
                  WHERE s.sociedad = f.sociedad AND s.cliente_id = f.cliente_id AND s.ejercicio = f.ejercicio
                    AND s.documento_id = f.documento_id AND s.posicion = f.posicion
              );
            SET @n_rev = @@ROWCOUNT;
        END

        PRINT 'staged: ' + CAST(@n_stage AS VARCHAR) + ' | updated: ' + CAST(@n_upd AS VARCHAR)
            + ' | inserted: ' + CAST(@n_ins AS VARCHAR)
            + ' | reversal groups (R2b): ' + CAST(@n_revertidos AS VARCHAR)
            + ' | refund-bound deposits: ' + CAST(@n_reemb AS VARCHAR)
            + ' | marked REVERTIDO (state): ' + CAST(@n_rev AS VARCHAR)
            + ' | ' + CAST(DATEDIFF(SECOND, @start_time, GETDATE()) AS VARCHAR) + ' s';
    END TRY
    BEGIN CATCH
        PRINT 'ERROR in gold.load_fact_pagos: ' + ERROR_MESSAGE();
        THROW;
    END CATCH;
END;
GO
PRINT 'Procedure gold.load_fact_pagos created.';
GO

-- Procedure 4 (load_fact_aplicacion) is added once the gate of section 3 passes.
