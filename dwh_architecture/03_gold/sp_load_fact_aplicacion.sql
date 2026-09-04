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
    ('Z4', 'Anul. ND (inferred)',    NULL,             'ANULACION',     'H', 1, 'NINGUNO', 1, NULL, 'ADS',   'Z3', 'T003.STBLA of D1. Never used (0 rows). Description inferred, not read from T003T. T003 read 2026-09-03: KOARS=ADS, NUMKR=Z3, no reversal type.'),
    ('ZY', 'Doc. Pago D y K',        NULL,             'TECNICO',       'H', 0, 'NINGUNO', 0, 'ZZ', 'DKS',   'ZQ', 'D y K = Deudores y Kreditoren. Corporate credit-card reconciliation on prefix-9 technical accounts (100% of rows). NOT a customer payment. Excluded.'),
    ('SA', 'Documento cta.mayor',    NULL,             'TECNICO',       NULL,1, 'NINGUNO', 0, 'ZZ', 'ADKMS', '10', 'G/L journal. Transit account inside the POS settlement flow (1.4M groups with CP/F5), marketplace commission accruals, balance clean-up, refunds (REEM*). Excluded except the REEM* exclusion signal on payments.'),
    ('SI', 'Saldos Iniciales',       'SALDO INICIAL',  'TECNICO',       'S', 0, 'NINGUNO', 0, 'ZZ', 'ADKMS', '10', 'Opening balances. 1 row in bsid (2015), 0 in bsad: outside the 2022+ data window.'),
    ('ZZ', 'Doc. Anulacion',         NULL,             'ANULACION',     NULL,1, 'NINGUNO', 0, NULL, 'ADKS',  'ZZ', 'FB08 reversal document, always of an SA (97,584 groups, 100% net zero). 99% = cancelled POS receipts by the interface user. Excluded. T003: KOARS=ADKS, no reversal type (nothing reverses a reversal).'),
    ('DI', 'Dist.Ingresos POS',      NULL,             'TECNICO',       NULL,0, 'NINGUNO', 0, 'DI', 'DKS',   'DI', '2 rows in all history, one self-cancelling pair. Excluded. T003: reverses with itself, KOARS=DKS.');

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
               CAST(CASE
                    WHEN SUM(CASE WHEN g.clase_documento IN ('DZ','CP','C1','C3','C4','C5') AND g.debe_haber = 'H' AND g.documento_id <> o.documento_id THEN 1 ELSE 0 END) > 0
                         THEN 'REEMISION_CREDITO'
                    WHEN SUM(CASE WHEN g.clase_documento = 'SA' AND g.debe_haber = 'H' AND g.sgtxt LIKE 'PAGO%' THEN 1 ELSE 0 END) > 0
                         THEN 'REEMISION_PAGO_SA'
                    ELSE 'REEMISION_AJUSTE_SA'
               END AS VARCHAR(20)) AS origen
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
                    WHEN s.clase_documento = 'DZ' AND s.sgtxt LIKE 'CHEQUE DEVUELTO%' THEN 'CHEQUE_DEVUELTO'   -- bounced check: the key-11 credit + its key-01/05 charge net to zero, no cash (user decision 2026-09-03)
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
                    WHEN s.clase_documento = 'DZ' AND s.sgtxt LIKE 'CHEQUE DEVUELTO%' THEN NULL
                    WHEN s.clave_contabilizacion IN ('02','05','12') THEN NULL
                    WHEN s.clase_documento = 'DZ' AND s.clave_contabilizacion = '11' THEN 'BANCO'
                    WHEN s.clase_documento = 'CP' AND s.clave_contabilizacion = '15' THEN 'DIRECTO'
                    WHEN s.clase_documento = 'DZ' AND s.clave_contabilizacion = '15' AND h.documento_id IS NULL AND o8.documento_id IS NULL THEN 'DIRECTO'
                    WHEN s.clase_documento = 'DZ' AND s.clave_contabilizacion = '15' AND h.documento_id IS NULL AND o8.documento_id IS NOT NULL THEN ISNULL(r.origen, 'REEMISION_AJUSTE_SA')
                    ELSE NULL
               END AS VARCHAR(20)) AS origen_efectivo
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
            WHERE s.estado_sap = 'COMPENSADO' AND k.origen_efectivo IN ('BANCO','DIRECTO','REEMISION_PAGO_SA')
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
               CAST(CASE WHEN k.origen_efectivo IN ('BANCO','DIRECTO','REEMISION_PAGO_SA') THEN 1 ELSE 0 END AS BIT) AS es_efectivo,
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
        LEFT JOIN #reemb m ON m.documento_compensacion = s.documento_compensacion AND m.ejercicio_compensacion = s.ejercicio_compensacion AND m.documento_id = s.documento_id AND k.origen_efectivo IN ('BANCO','DIRECTO','REEMISION_PAGO_SA')
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

-- ============================================================================
-- 4. gold.load_fact_aplicacion
--    Rebuilds every application whose VEHICLE line was posted inside the window
--    (fecha_contabilizacion >= @fecha_desde [< @fecha_hasta]). Steps:
--      1  #recibe   receiving documents (fact_facturas, not cancelled / reverted)
--      2  #veh      vehicles: cash lines, child lines (with their origin deposit,
--                   1 or 2 hops), notes, AB 17/15 lines (with the credit their 07 twin consumed)
--      3  R1        REBZG -> receiving, same group or receiving still open
--      4  R3        no REBZG, exactly one receiving document in the vehicle's group
--      5  R0        unidentified remainder per cash origin / per unresolved vehicle
--      6  invariants printed (must all be 0)
-- ============================================================================
IF OBJECT_ID('gold.load_fact_aplicacion', 'P') IS NOT NULL DROP PROCEDURE gold.load_fact_aplicacion;
GO
CREATE PROCEDURE gold.load_fact_aplicacion
    @fecha_desde DATE = NULL,
    @fecha_hasta DATE = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @start_time DATETIME = GETDATE();
    DECLARE @n_del INT, @n_veh INT, @n_r1 INT, @n_r3 INT, @n_r0 INT, @inv1 INT, @inv2 INT, @inv3 INT;

    IF @fecha_desde IS NULL
        SET @fecha_desde = DATEADD(MONTH, DATEDIFF(MONTH, 0, GETDATE()) - 1, 0);

    BEGIN TRY
        PRINT '>> gold.load_fact_aplicacion | window fecha_aplica >= ' + CONVERT(VARCHAR(10), @fecha_desde, 120)
            + CASE WHEN @fecha_hasta IS NULL THEN '' ELSE ' and < ' + CONVERT(VARCHAR(10), @fecha_hasta, 120) END;

        -- ------------------------------------------------------------------
        -- Step 1: receiving documents
        -- ------------------------------------------------------------------
        IF OBJECT_ID('tempdb..#recibe') IS NOT NULL DROP TABLE #recibe;

        SELECT f.sociedad, f.cliente_id, f.ejercicio, f.documento_id, f.posicion, f.clase_documento,
               f.estado_sap, f.fecha_contabilizacion, f.fecha_vencimiento, f.monto_moneda_local, f.moneda,
               f.documento_compensacion, f.ejercicio_compensacion, f.fecha_compensacion
        INTO #recibe
        FROM gold.fact_facturas f
        WHERE f.anulada = 0 AND f.estado_sap <> 'REVERTIDO';
        CREATE UNIQUE CLUSTERED INDEX IX_recibe ON #recibe (documento_id, ejercicio, posicion, sociedad);
        CREATE INDEX IX_recibe_grupo ON #recibe (documento_compensacion, ejercicio_compensacion);

        -- receiving documents per compensation group (for R3 and for the R0 reasons)
        IF OBJECT_ID('tempdb..#recibe_grupo') IS NOT NULL DROP TABLE #recibe_grupo;
        SELECT documento_compensacion, ejercicio_compensacion, COUNT(*) AS num_recibe
        INTO #recibe_grupo
        FROM #recibe WHERE documento_compensacion IS NOT NULL
        GROUP BY documento_compensacion, ejercicio_compensacion;
        CREATE UNIQUE CLUSTERED INDEX IX_rg ON #recibe_grupo (documento_compensacion, ejercicio_compensacion);

        -- ------------------------------------------------------------------
        -- Step 2: vehicles
        -- ------------------------------------------------------------------
        IF OBJECT_ID('tempdb..#veh') IS NOT NULL DROP TABLE #veh;

        CREATE TABLE #veh (
            sociedad VARCHAR(4), cliente_id VARCHAR(10), ejercicio INT, documento_id VARCHAR(10), posicion INT,
            clase_documento VARCHAR(2), clave_contabilizacion VARCHAR(2), estado_sap VARCHAR(10),
            fecha_contabilizacion DATE, monto DECIMAL(15,2), moneda VARCHAR(5),
            documento_compensacion VARCHAR(10), ejercicio_compensacion INT, fecha_compensacion DATE,
            rebzg VARCHAR(10), rebzj INT, rebzz INT,
            tipo_aplicacion VARCHAR(20),
            origen_documento VARCHAR(10), origen_ejercicio INT, origen_posicion INT, origen_clase VARCHAR(2),
            origen_cliente_id VARCHAR(10), origen_fecha DATE, origen_monto DECIMAL(15,2),
            saltos TINYINT, origen_resuelto BIT, es_origen_efectivo BIT
        );

        -- 2a: cash lines - their own origin
        INSERT INTO #veh
        SELECT p.sociedad, p.cliente_id, p.ejercicio, p.documento_id, p.posicion,
               p.clase_documento, p.clave_contabilizacion, p.estado_sap,
               p.fecha_contabilizacion, p.monto_moneda_local, p.moneda,
               p.documento_compensacion, p.ejercicio_compensacion, p.fecha_compensacion,
               CASE WHEN p.factura_referencia_documento IS NULL OR p.factura_referencia_documento = 'V' THEN NULL ELSE p.factura_referencia_documento END,
               p.factura_referencia_ejercicio, p.factura_referencia_posicion,
               'PAGO',
               p.documento_id, p.ejercicio, p.posicion, p.clase_documento, p.cliente_id, p.fecha_contabilizacion, p.monto_moneda_local,
               0, 1, 1
        FROM gold.fact_pagos p
        WHERE p.es_efectivo = 1 AND p.revertido = 0 AND p.es_reembolso = 0
          AND p.fecha_contabilizacion >= @fecha_desde
          AND (@fecha_hasta IS NULL OR p.fecha_contabilizacion < @fecha_hasta);

        -- every cash origin of the window, kept apart from #veh: step 2e may remove a deposit
        -- as a VEHICLE (its group is anchored by its child) but it stays an ORIGIN whose
        -- unexplained remainder R0 must still report
        IF OBJECT_ID('tempdb..#cash') IS NOT NULL DROP TABLE #cash;
        SELECT * INTO #cash FROM #veh WHERE es_origen_efectivo = 1;
        CREATE UNIQUE CLUSTERED INDEX IX_cash ON #cash (sociedad, cliente_id, ejercicio, documento_id, posicion);

        -- 2b: child lines. Hop 1: the deposit(s) pointing to the child document.
        IF OBJECT_ID('tempdb..#hijo1') IS NOT NULL DROP TABLE #hijo1;
        SELECT v.sociedad, v.ejercicio_hijo AS ejercicio, v.documento_hijo AS documento_id,
               COUNT(*) AS num_virgenes,
               MIN(v.documento_id) AS o_documento, MIN(v.ejercicio) AS o_ejercicio, MIN(v.posicion) AS o_posicion,
               MIN(v.cliente_id) AS o_cliente, MIN(v.fecha_contabilizacion) AS o_fecha, MIN(v.monto_moneda_local) AS o_monto
        INTO #hijo1
        FROM gold.fact_pagos v
        WHERE v.tipo_linea = 'VIRGEN' AND v.revertido = 0 AND v.es_reembolso = 0 AND v.documento_hijo IS NOT NULL
        GROUP BY v.sociedad, v.ejercicio_hijo, v.documento_hijo;
        CREATE UNIQUE CLUSTERED INDEX IX_h1 ON #hijo1 (sociedad, ejercicio, documento_id);

        -- Hop 2: a document that a resolved child's own key-15/17/18 line (without REBZG) was
        -- cleared into - the grandchild inherits the child's deposit.
        IF OBJECT_ID('tempdb..#hijo2') IS NOT NULL DROP TABLE #hijo2;
        SELECT c.sociedad, c.ejercicio_compensacion AS ejercicio, c.documento_compensacion AS documento_id,
               COUNT(DISTINCT h.o_documento) AS num_origenes,
               MIN(h.o_documento) AS o_documento, MIN(h.o_ejercicio) AS o_ejercicio, MIN(h.o_posicion) AS o_posicion,
               MIN(h.o_cliente) AS o_cliente, MIN(h.o_fecha) AS o_fecha, MIN(h.o_monto) AS o_monto
        INTO #hijo2
        FROM gold.fact_pagos c
        JOIN #hijo1 h ON h.sociedad = c.sociedad AND h.ejercicio = c.ejercicio AND h.documento_id = c.documento_id AND h.num_virgenes = 1
        WHERE c.tipo_linea = 'APLICACION_HIJO' AND c.revertido = 0
          AND (c.factura_referencia_documento IS NULL OR c.factura_referencia_documento = 'V')
          AND c.documento_compensacion IS NOT NULL
          AND c.documento_compensacion <> c.documento_id
          AND NOT EXISTS (SELECT 1 FROM #hijo1 x WHERE x.sociedad = c.sociedad AND x.ejercicio = c.ejercicio_compensacion AND x.documento_id = c.documento_compensacion)
        GROUP BY c.sociedad, c.ejercicio_compensacion, c.documento_compensacion;
        CREATE UNIQUE CLUSTERED INDEX IX_h2 ON #hijo2 (sociedad, ejercicio, documento_id);

        INSERT INTO #veh
        SELECT p.sociedad, p.cliente_id, p.ejercicio, p.documento_id, p.posicion,
               p.clase_documento, p.clave_contabilizacion, p.estado_sap,
               p.fecha_contabilizacion, p.monto_moneda_local, p.moneda,
               p.documento_compensacion, p.ejercicio_compensacion, p.fecha_compensacion,
               CASE WHEN p.factura_referencia_documento IS NULL OR p.factura_referencia_documento = 'V' THEN NULL ELSE p.factura_referencia_documento END,
               p.factura_referencia_ejercicio, p.factura_referencia_posicion,
               'PAGO',
               COALESCE(CASE WHEN h1.num_virgenes = 1 THEN h1.o_documento END, CASE WHEN h2.num_origenes = 1 THEN h2.o_documento END),
               COALESCE(CASE WHEN h1.num_virgenes = 1 THEN h1.o_ejercicio END, CASE WHEN h2.num_origenes = 1 THEN h2.o_ejercicio END),
               COALESCE(CASE WHEN h1.num_virgenes = 1 THEN h1.o_posicion END, CASE WHEN h2.num_origenes = 1 THEN h2.o_posicion END),
               CASE WHEN h1.num_virgenes = 1 OR h2.num_origenes = 1 THEN 'DZ' END,
               COALESCE(CASE WHEN h1.num_virgenes = 1 THEN h1.o_cliente END, CASE WHEN h2.num_origenes = 1 THEN h2.o_cliente END),
               COALESCE(CASE WHEN h1.num_virgenes = 1 THEN h1.o_fecha END, CASE WHEN h2.num_origenes = 1 THEN h2.o_fecha END),
               COALESCE(CASE WHEN h1.num_virgenes = 1 THEN h1.o_monto END, CASE WHEN h2.num_origenes = 1 THEN h2.o_monto END),
               CASE WHEN h1.num_virgenes = 1 THEN 1 WHEN h2.num_origenes = 1 THEN 2 ELSE 0 END,
               CASE WHEN h1.num_virgenes = 1 OR h2.num_origenes = 1 THEN 1 ELSE 0 END,
               0
        FROM gold.fact_pagos p
        LEFT JOIN #hijo1 h1 ON h1.sociedad = p.sociedad AND h1.ejercicio = p.ejercicio AND h1.documento_id = p.documento_id
        LEFT JOIN #hijo2 h2 ON h2.sociedad = p.sociedad AND h2.ejercicio = p.ejercicio AND h2.documento_id = p.documento_id
        WHERE p.tipo_linea = 'APLICACION_HIJO' AND p.revertido = 0
          AND p.fecha_contabilizacion >= @fecha_desde
          AND (@fecha_hasta IS NULL OR p.fecha_contabilizacion < @fecha_hasta);

        -- 2b2: re-issued credits. A PAGO_DIRECTO line that is NOT cash (REEMISION_CREDITO /
        -- REEMISION_AJUSTE_SA) still applies money: its key-08 sibling consumed a credit of
        -- another document and the 15 line re-issues it. Origin = that credit, or the deposit
        -- behind it when the credit is itself a child line (2 hops). Real case: deposit
        -- 1402621305 -> intermediate 1402621328 -> invoice 7404802497.
        -- The credit the 08 consumed: first choice, the single other-document credit whose
        -- amount EQUALS the 08 line (an exact mirror - the group may also hold credit notes
        -- with REBZG that settle invoices on their own); otherwise the single credit of any
        -- kind; otherwise unresolved.
        IF OBJECT_ID('tempdb..#reem_cred') IS NOT NULL DROP TABLE #reem_cred;
        SELECT o.sociedad, o.ejercicio, o.documento_id, o.monto_moneda_local AS monto_08,
               g.documento_id AS c_documento, g.ejercicio AS c_ejercicio, g.posicion AS c_posicion,
               g.clase_documento AS c_clase, g.cliente_id AS c_cliente, g.fecha_contabilizacion AS c_fecha, g.monto_moneda_local AS c_monto,
               CASE WHEN ABS(g.monto_moneda_local - o.monto_moneda_local) < 0.01 THEN 1 ELSE 0 END AS mismo_monto
        INTO #reem_cred
        FROM gold.fact_pagos o
        JOIN silver.sap_bsad g
          ON  g.mandante = '400' AND g.documento_compensacion = o.documento_compensacion AND g.ejercicio_compensacion = o.ejercicio_compensacion
          AND g.documento_id <> o.documento_id AND g.debe_haber = 'H' AND g.clase_documento IN ('DZ','CP','C1','C3','C4','C5')
        WHERE o.tipo_linea = 'TRASPASO_08'
          AND EXISTS (SELECT 1 FROM gold.fact_pagos p
                      WHERE p.sociedad = o.sociedad AND p.ejercicio = o.ejercicio AND p.documento_id = o.documento_id
                        AND p.tipo_linea = 'PAGO_DIRECTO' AND p.es_efectivo = 0 AND p.revertido = 0
                        AND p.fecha_contabilizacion >= @fecha_desde AND (@fecha_hasta IS NULL OR p.fecha_contabilizacion < @fecha_hasta));

        IF OBJECT_ID('tempdb..#reem_origen') IS NOT NULL DROP TABLE #reem_origen;
        SELECT x.sociedad, x.ejercicio, x.documento_id,
               CASE WHEN x.n_mismo = 1 THEN 1 WHEN x.n_mismo = 0 AND x.n_total = 1 THEN 1 ELSE 0 END AS num_creditos,   -- 1 = resolved
               c.c_documento, c.c_ejercicio, c.c_posicion, c.c_clase, c.c_cliente, c.c_fecha, c.c_monto
        INTO #reem_origen
        FROM (SELECT sociedad, ejercicio, documento_id, SUM(mismo_monto) AS n_mismo, COUNT(*) AS n_total
              FROM #reem_cred GROUP BY sociedad, ejercicio, documento_id) x
        LEFT JOIN #reem_cred c
          ON c.sociedad = x.sociedad AND c.ejercicio = x.ejercicio AND c.documento_id = x.documento_id
         AND ((x.n_mismo = 1 AND c.mismo_monto = 1) OR (x.n_mismo = 0 AND x.n_total = 1));
        CREATE UNIQUE CLUSTERED INDEX IX_ro ON #reem_origen (sociedad, ejercicio, documento_id);

        INSERT INTO #veh
        SELECT p.sociedad, p.cliente_id, p.ejercicio, p.documento_id, p.posicion,
               p.clase_documento, p.clave_contabilizacion, p.estado_sap,
               p.fecha_contabilizacion, p.monto_moneda_local, p.moneda,
               p.documento_compensacion, p.ejercicio_compensacion, p.fecha_compensacion,
               CASE WHEN p.factura_referencia_documento IS NULL OR p.factura_referencia_documento = 'V' THEN NULL ELSE p.factura_referencia_documento END,
               p.factura_referencia_ejercicio, p.factura_referencia_posicion,
               CASE WHEN r.num_creditos = 1 AND r.c_clase = 'C5' THEN 'NOTA_CREDITO'
                    WHEN r.num_creditos = 1 AND r.c_clase IN ('C1','C3','C4') THEN 'DEVOLUCION'
                    WHEN r.num_creditos = 1 THEN 'PAGO'
                    ELSE 'CREDITO_REAPLICADO' END,
               -- origin: the credit line itself (cash or note) or, for a child line, its deposit
               CASE WHEN r.num_creditos <> 1 THEN NULL
                    WHEN c.tipo_linea = 'APLICACION_HIJO' THEN CASE WHEN h1.num_virgenes = 1 THEN h1.o_documento END
                    WHEN c.tipo_linea IN ('VIRGEN','PAGO_DIRECTO') AND c.es_efectivo = 1 THEN r.c_documento
                    WHEN c.documento_id IS NULL THEN r.c_documento          -- a note (not in fact_pagos)
                    ELSE NULL END,
               CASE WHEN r.num_creditos <> 1 THEN NULL
                    WHEN c.tipo_linea = 'APLICACION_HIJO' THEN CASE WHEN h1.num_virgenes = 1 THEN h1.o_ejercicio END
                    WHEN c.tipo_linea IN ('VIRGEN','PAGO_DIRECTO') AND c.es_efectivo = 1 THEN r.c_ejercicio
                    WHEN c.documento_id IS NULL THEN r.c_ejercicio ELSE NULL END,
               CASE WHEN r.num_creditos <> 1 THEN NULL
                    WHEN c.tipo_linea = 'APLICACION_HIJO' THEN CASE WHEN h1.num_virgenes = 1 THEN h1.o_posicion END
                    WHEN c.tipo_linea IN ('VIRGEN','PAGO_DIRECTO') AND c.es_efectivo = 1 THEN r.c_posicion
                    WHEN c.documento_id IS NULL THEN r.c_posicion ELSE NULL END,
               CASE WHEN r.num_creditos <> 1 THEN NULL
                    WHEN c.tipo_linea = 'APLICACION_HIJO' THEN CASE WHEN h1.num_virgenes = 1 THEN 'DZ' END
                    WHEN c.tipo_linea IN ('VIRGEN','PAGO_DIRECTO') AND c.es_efectivo = 1 THEN r.c_clase
                    WHEN c.documento_id IS NULL THEN r.c_clase ELSE NULL END,
               CASE WHEN r.num_creditos <> 1 THEN NULL
                    WHEN c.tipo_linea = 'APLICACION_HIJO' THEN CASE WHEN h1.num_virgenes = 1 THEN h1.o_cliente END
                    ELSE r.c_cliente END,
               CASE WHEN r.num_creditos <> 1 THEN NULL
                    WHEN c.tipo_linea = 'APLICACION_HIJO' THEN CASE WHEN h1.num_virgenes = 1 THEN h1.o_fecha END
                    WHEN c.tipo_linea IN ('VIRGEN','PAGO_DIRECTO') AND c.es_efectivo = 1 THEN r.c_fecha
                    WHEN c.documento_id IS NULL THEN r.c_fecha ELSE NULL END,
               CASE WHEN r.num_creditos <> 1 THEN NULL
                    WHEN c.tipo_linea = 'APLICACION_HIJO' THEN CASE WHEN h1.num_virgenes = 1 THEN h1.o_monto END
                    WHEN c.tipo_linea IN ('VIRGEN','PAGO_DIRECTO') AND c.es_efectivo = 1 THEN r.c_monto
                    WHEN c.documento_id IS NULL THEN r.c_monto ELSE NULL END,
               CASE WHEN r.num_creditos = 1 AND c.tipo_linea = 'APLICACION_HIJO' AND h1.num_virgenes = 1 THEN 2
                    WHEN r.num_creditos = 1 THEN 1 ELSE 0 END,
               CASE WHEN r.num_creditos = 1 AND (
                         (c.tipo_linea = 'APLICACION_HIJO' AND h1.num_virgenes = 1)
                      OR (c.tipo_linea IN ('VIRGEN','PAGO_DIRECTO') AND c.es_efectivo = 1)
                      OR  c.documento_id IS NULL) THEN 1 ELSE 0 END,
               0
        FROM gold.fact_pagos p
        LEFT JOIN #reem_origen r ON r.sociedad = p.sociedad AND r.ejercicio = p.ejercicio AND r.documento_id = p.documento_id
        LEFT JOIN gold.fact_pagos c ON c.sociedad = p.sociedad AND c.documento_id = r.c_documento AND c.ejercicio = r.c_ejercicio AND c.posicion = r.c_posicion
        LEFT JOIN #hijo1 h1 ON h1.sociedad = c.sociedad AND h1.ejercicio = c.ejercicio AND h1.documento_id = c.documento_id
        WHERE p.tipo_linea = 'PAGO_DIRECTO' AND p.es_efectivo = 0 AND p.revertido = 0
          AND ISNULL(c.tipo_linea, '') <> 'CHEQUE_DEVUELTO'   -- a re-issue of a bounced check carries no money either
          AND p.fecha_contabilizacion >= @fecha_desde
          AND (@fecha_hasta IS NULL OR p.fecha_contabilizacion < @fecha_hasta);

        -- 2c: credit notes and returns - their own origin
        INSERT INTO #veh
        SELECT n.sociedad, n.cliente_id, n.ejercicio, n.documento_id, n.posicion,
               n.clase_documento, n.clave_contabilizacion, n.estado_sap,
               n.fecha_contabilizacion, n.monto_moneda_local, n.moneda,
               n.documento_compensacion, n.ejercicio_compensacion, n.fecha_compensacion,
               CASE WHEN n.factura_referencia_documento IS NULL OR n.factura_referencia_documento = 'V' THEN NULL ELSE n.factura_referencia_documento END,
               n.factura_referencia_ejercicio, n.factura_referencia_posicion,
               CASE WHEN n.clase_documento = 'C5' THEN 'NOTA_CREDITO' ELSE 'DEVOLUCION' END,
               n.documento_id, n.ejercicio, n.posicion, n.clase_documento, n.cliente_id, n.fecha_contabilizacion, n.monto_moneda_local,
               0, 1, 0
        FROM gold.fact_notas n
        WHERE n.anulada = 0 AND n.estado_sap <> 'REVERTIDO'
          AND n.fecha_contabilizacion >= @fecha_desde
          AND (@fecha_hasta IS NULL OR n.fecha_contabilizacion < @fecha_hasta);

        -- 2d: AB key-17 / key-15 lines with amount (rule R5). Origin = the credit consumed by the
        -- same document's key-07 twin in ITS compensation group (exactly one other document ->
        -- resolved). Self-contained re-postings (the 17 line's own group holds no other
        -- document) are not vehicles - that credit applies later, in another group.
        IF OBJECT_ID('tempdb..#ab') IS NOT NULL DROP TABLE #ab;
        SELECT a.sociedad, a.cliente_id, a.ejercicio, a.documento_id, a.posicion, a.clave_contabilizacion,
               CAST('COMPENSADO' AS VARCHAR(10)) AS estado_sap, a.fecha_contabilizacion, a.monto_moneda_local, a.moneda,
               a.documento_compensacion, a.ejercicio_compensacion, a.fecha_compensacion,
               a.factura_referencia_documento, a.factura_referencia_ejercicio, a.factura_referencia_posicion
        INTO #ab
        FROM silver.sap_bsad a
        WHERE a.mandante = '400' AND a.clase_documento = 'AB' AND a.clave_contabilizacion IN ('15','17')
          AND a.debe_haber = 'H' AND a.monto_moneda_local > 0
          AND a.fecha_contabilizacion >= @fecha_desde
          AND (@fecha_hasta IS NULL OR a.fecha_contabilizacion < @fecha_hasta)
          AND EXISTS (SELECT 1 FROM silver.sap_bsad g WHERE g.mandante = '400' AND g.documento_compensacion = a.documento_compensacion
                        AND g.ejercicio_compensacion = a.ejercicio_compensacion AND g.documento_id <> a.documento_id)
        UNION ALL
        SELECT a.sociedad, a.cliente_id, a.ejercicio, a.documento_id, a.posicion, a.clave_contabilizacion,
               'ABIERTO', a.fecha_contabilizacion, a.monto_moneda_local, a.moneda,
               NULL, NULL, NULL,
               a.factura_referencia_documento, a.factura_referencia_ejercicio, a.factura_referencia_posicion
        FROM silver.sap_bsid a
        WHERE a.mandante = '400' AND a.clase_documento = 'AB' AND a.clave_contabilizacion IN ('15','17')
          AND a.debe_haber = 'H' AND a.monto_moneda_local > 0
          AND a.fecha_contabilizacion >= @fecha_desde
          AND (@fecha_hasta IS NULL OR a.fecha_contabilizacion < @fecha_hasta);

        IF OBJECT_ID('tempdb..#ab_origen') IS NOT NULL DROP TABLE #ab_origen;
        SELECT t.sociedad, t.ejercicio, t.documento_id,
               COUNT(DISTINCT g.documento_id) AS num_creditos,
               MIN(g.documento_id) AS o_documento, MIN(g.ejercicio) AS o_ejercicio, MIN(g.posicion) AS o_posicion,
               MIN(g.clase_documento) AS o_clase, MIN(g.cliente_id) AS o_cliente, MIN(g.fecha_contabilizacion) AS o_fecha, MIN(g.monto_moneda_local) AS o_monto
        INTO #ab_origen
        FROM silver.sap_bsad t
        JOIN silver.sap_bsad g
          ON  g.mandante = '400' AND g.documento_compensacion = t.documento_compensacion AND g.ejercicio_compensacion = t.ejercicio_compensacion
          AND g.documento_id <> t.documento_id AND g.debe_haber = 'H' AND g.clase_documento <> 'AB'
        WHERE t.mandante = '400' AND t.clase_documento = 'AB' AND t.clave_contabilizacion = '07'
          AND EXISTS (SELECT 1 FROM #ab x WHERE x.sociedad = t.sociedad AND x.ejercicio = t.ejercicio AND x.documento_id = t.documento_id)
        GROUP BY t.sociedad, t.ejercicio, t.documento_id;
        CREATE UNIQUE CLUSTERED INDEX IX_abo ON #ab_origen (sociedad, ejercicio, documento_id);

        INSERT INTO #veh
        SELECT a.sociedad, a.cliente_id, a.ejercicio, a.documento_id, a.posicion,
               'AB', a.clave_contabilizacion, a.estado_sap,
               a.fecha_contabilizacion, a.monto_moneda_local, a.moneda,
               a.documento_compensacion, a.ejercicio_compensacion, a.fecha_compensacion,
               CASE WHEN a.factura_referencia_documento IS NULL OR a.factura_referencia_documento = 'V' THEN NULL ELSE a.factura_referencia_documento END,
               a.factura_referencia_ejercicio, a.factura_referencia_posicion,
               CASE WHEN a.clave_contabilizacion = '15' THEN 'SALDO_A_FAVOR' ELSE 'CREDITO_REAPLICADO' END,
               CASE WHEN o.num_creditos = 1 THEN o.o_documento END,
               CASE WHEN o.num_creditos = 1 THEN o.o_ejercicio END,
               CASE WHEN o.num_creditos = 1 THEN o.o_posicion END,
               CASE WHEN o.num_creditos = 1 THEN o.o_clase END,
               CASE WHEN o.num_creditos = 1 THEN o.o_cliente END,
               CASE WHEN o.num_creditos = 1 THEN o.o_fecha END,
               CASE WHEN o.num_creditos = 1 THEN o.o_monto END,
               1,
               CASE WHEN o.num_creditos = 1 THEN 1 ELSE 0 END,
               0
        FROM #ab a
        LEFT JOIN #ab_origen o ON o.sociedad = a.sociedad AND o.ejercicio = a.ejercicio AND o.documento_id = a.documento_id
        -- pass-through pairs: the same AB document's key-07 line sits in the SAME group with
        -- the same amount - an internal transfer that nets to zero, not an application
        WHERE NOT EXISTS (
            SELECT 1 FROM silver.sap_bsad t
            WHERE t.mandante = '400' AND t.sociedad = a.sociedad AND t.ejercicio = a.ejercicio AND t.documento_id = a.documento_id
              AND t.clave_contabilizacion = '07' AND t.monto_moneda_local = a.monto_moneda_local
              AND t.documento_compensacion = a.documento_compensacion AND t.ejercicio_compensacion = a.ejercicio_compensacion
        );

        -- 2e: a payment line whose group is anchored by ANOTHER document carrying a key-08
        -- line of the SAME amount is not a candidate in that group: the anchor consumed it
        -- whole with that mirror and re-issued it through its own key-15 lines, which are the
        -- vehicles for the invoices of the group (real shape: {incoming credit H, anchor 08 S
        -- = incoming, anchor 15 H lines, invoices S} - 1,512 groups / $19M in July 2026).
        -- A broader version of this step (any child-anchored group) was tried and dropped the
        -- same day: when the 08 carries only a LEFTOVER (group 1402632140: $495,651.99
        -- deposit, 3 invoices $288,722.28, 08 $206,929.71) the deposit IS the vehicle for the
        -- invoices and R4 must see it. Double counting through the chain is prevented by the
        -- cumulative caps in steps 4b/4c.
        -- The mirror can belong to ANY other DZ document of the group, not only to the anchor:
        -- in the most frequent July shape (2,501 groups / $36.35M) the deposit anchors the
        -- group with its OWN number and the child (08 mirror + 15 re-issue) sits inside it.
        DELETE v
        FROM #veh v
        WHERE v.tipo_aplicacion = 'PAGO'
          AND v.documento_compensacion IS NOT NULL
          AND EXISTS (
              SELECT 1 FROM silver.sap_bsad m
              WHERE m.mandante = '400' AND m.sociedad = v.sociedad
                AND m.documento_compensacion = v.documento_compensacion AND m.ejercicio_compensacion = v.ejercicio_compensacion
                AND m.documento_id <> v.documento_id
                AND m.clase_documento = 'DZ'   -- only the DZ child mechanism. An SA anchor with an 08/15 pair is the POS transit: there the CP line IS the vehicle (REBZG -> F5)
                AND m.clave_contabilizacion = '08' AND m.debe_haber = 'S'
                AND ABS(m.monto_moneda_local - v.monto) < 0.01
          );

        -- 2f: payment-difference lines. A key-15 line of the ANCHOR document itself, inside its
        -- own group, without REBZG, when the group already holds another candidate, is the
        -- clearing's difference posting ($0.01 / $7.23 ...), not an applicator: the deposit is
        -- the single candidate and the difference is added to what it covers. (Real shape,
        -- 2,490 groups / $36.3M in July 2026: {deposit H, anchor 15 H $0.01, invoices S}.)
        -- If the anchor's own line is the ONLY candidate (the incoming credit was consumed by
        -- the anchor's 08 mirror and removed in 2e, e.g. group 1402657695), it stays a vehicle.
        IF OBJECT_ID('tempdb..#dif') IS NOT NULL DROP TABLE #dif;
        SELECT v.documento_compensacion, v.ejercicio_compensacion, SUM(v.monto) AS suma_dif
        INTO #dif
        FROM #veh v
        WHERE v.tipo_aplicacion = 'PAGO' AND v.clase_documento = 'DZ'
          AND v.documento_id = v.documento_compensacion AND v.ejercicio = v.ejercicio_compensacion
          AND v.rebzg IS NULL
          AND EXISTS (SELECT 1 FROM #veh o
                      WHERE o.documento_compensacion = v.documento_compensacion AND o.ejercicio_compensacion = v.ejercicio_compensacion
                        AND o.documento_id <> v.documento_id AND o.rebzg IS NULL)
        GROUP BY v.documento_compensacion, v.ejercicio_compensacion;
        CREATE UNIQUE CLUSTERED INDEX IX_dif ON #dif (documento_compensacion, ejercicio_compensacion);

        DELETE v
        FROM #veh v
        WHERE v.tipo_aplicacion = 'PAGO' AND v.clase_documento = 'DZ'
          AND v.documento_id = v.documento_compensacion AND v.ejercicio = v.ejercicio_compensacion
          AND v.rebzg IS NULL
          AND EXISTS (SELECT 1 FROM #dif d WHERE d.documento_compensacion = v.documento_compensacion AND d.ejercicio_compensacion = v.ejercicio_compensacion);

        SELECT @n_veh = COUNT(*) FROM #veh;
        CREATE UNIQUE CLUSTERED INDEX IX_veh ON #veh (sociedad, cliente_id, ejercicio, documento_id, posicion);
        CREATE INDEX IX_veh_grupo ON #veh (documento_compensacion, ejercicio_compensacion);

        -- ------------------------------------------------------------------
        -- Delete the window before inserting
        -- ------------------------------------------------------------------
        DELETE FROM gold.fact_aplicacion
        WHERE fecha_aplica >= @fecha_desde AND (@fecha_hasta IS NULL OR fecha_aplica < @fecha_hasta);
        SET @n_del = @@ROWCOUNT;

        -- ------------------------------------------------------------------
        -- Step 3: R1 - REBZG. Counts only when vehicle and receiving document met in the
        -- same compensation group, or the receiving document is still open (partial payment
        -- in progress). A reference to an invoice cleared elsewhere is not an application.
        -- ------------------------------------------------------------------
        IF OBJECT_ID('tempdb..#r1') IS NOT NULL DROP TABLE #r1;
        SELECT v.sociedad, v.cliente_id, v.ejercicio, v.documento_id, v.posicion,
               r.documento_id AS r_documento, r.ejercicio AS r_ejercicio, r.posicion AS r_posicion
        INTO #r1
        FROM #veh v
        JOIN #recibe r ON r.documento_id = v.rebzg AND r.ejercicio = v.rebzj AND r.posicion = v.rebzz AND r.sociedad = v.sociedad
        WHERE v.rebzg IS NOT NULL
          AND ( (r.documento_compensacion = v.documento_compensacion AND r.ejercicio_compensacion = v.ejercicio_compensacion)
                OR r.estado_sap = 'ABIERTO' );

        INSERT INTO gold.fact_aplicacion (
            sociedad, documento_aplica, ejercicio_aplica, posicion_aplica, clase_documento_aplica, clave_contabilizacion_aplica,
            cliente_pagador_id, fecha_aplica, monto_documento_aplica,
            documento_origen, ejercicio_origen, posicion_origen, clase_documento_origen, fecha_origen, monto_documento_origen, saltos,
            documento_recibe, ejercicio_recibe, posicion_recibe, clase_documento_recibe, cliente_factura_id, fecha_factura, fecha_vencimiento, monto_documento_recibe, estado_recibe,
            monto_aplicado, tipo_aplicacion, estatus_identificacion, motivo_no_identificado,
            documento_compensacion, ejercicio_compensacion, fecha_compensacion, fuente_sap, regla, nivel_certeza, origen_resuelto, moneda
        )
        SELECT v.sociedad, v.documento_id, v.ejercicio, v.posicion, v.clase_documento, v.clave_contabilizacion,
               v.cliente_id, v.fecha_contabilizacion, v.monto,
               v.origen_documento, v.origen_ejercicio, v.origen_posicion, v.origen_clase, v.origen_fecha, v.origen_monto, v.saltos,
               r.documento_id, r.ejercicio, r.posicion, r.clase_documento, r.cliente_id, r.fecha_contabilizacion, r.fecha_vencimiento, r.monto_moneda_local, r.estado_sap,
               CASE WHEN v.monto < r.monto_moneda_local THEN v.monto ELSE r.monto_moneda_local END,
               v.tipo_aplicacion, 'IDENTIFICADA', NULL,
               CASE WHEN r.estado_sap = 'ABIERTO' THEN NULL ELSE r.documento_compensacion END,
               CASE WHEN r.estado_sap = 'ABIERTO' THEN NULL ELSE r.ejercicio_compensacion END,
               CASE WHEN r.estado_sap = 'ABIERTO' THEN NULL ELSE r.fecha_compensacion END,
               CASE WHEN r.estado_sap = 'ABIERTO' AND v.estado_sap = 'ABIERTO' THEN 'BSID'
                    WHEN r.estado_sap = 'ABIERTO' OR v.estado_sap = 'ABIERTO' THEN 'BSAD+BSID' ELSE 'BSAD' END,
               'R1', 1, v.origen_resuelto, v.moneda
        FROM #r1 x
        JOIN #veh v ON v.sociedad = x.sociedad AND v.cliente_id = x.cliente_id AND v.ejercicio = x.ejercicio AND v.documento_id = x.documento_id AND v.posicion = x.posicion
        JOIN #recibe r ON r.documento_id = x.r_documento AND r.ejercicio = x.r_ejercicio AND r.posicion = x.r_posicion AND r.sociedad = x.sociedad;
        SET @n_r1 = @@ROWCOUNT;

        -- ------------------------------------------------------------------
        -- Step 4: R3 - no REBZG (or REBZG that did not qualify), cleared, exactly one
        -- receiving document in the vehicle's group, AND every R3 candidate of the group
        -- fits in what R1 left of that document. If the candidates together exceed it, part
        -- of that credit was consumed by something else in the group (an 07/08 debit) and
        -- which part is unknowable - the whole group goes to R0 as GRUPO_AMBIGUO.
        -- ------------------------------------------------------------------
        IF OBJECT_ID('tempdb..#r3_grupo') IS NOT NULL DROP TABLE #r3_grupo;
        SELECT v.documento_compensacion, v.ejercicio_compensacion, SUM(v.monto) AS suma_candidatos, COUNT(*) AS num_candidatos
        INTO #r3_grupo
        FROM #veh v
        WHERE v.estado_sap = 'COMPENSADO'
          AND NOT EXISTS (SELECT 1 FROM #r1 x WHERE x.sociedad = v.sociedad AND x.cliente_id = v.cliente_id AND x.ejercicio = v.ejercicio AND x.documento_id = v.documento_id AND x.posicion = v.posicion)
        GROUP BY v.documento_compensacion, v.ejercicio_compensacion;
        CREATE UNIQUE CLUSTERED INDEX IX_r3g ON #r3_grupo (documento_compensacion, ejercicio_compensacion);

        IF OBJECT_ID('tempdb..#r1_recibe') IS NOT NULL DROP TABLE #r1_recibe;
        SELECT documento_recibe, ejercicio_recibe, posicion_recibe, SUM(monto_aplicado) AS aplicado_r1
        INTO #r1_recibe
        FROM gold.fact_aplicacion WHERE regla = 'R1'
        GROUP BY documento_recibe, ejercicio_recibe, posicion_recibe;
        CREATE UNIQUE CLUSTERED INDEX IX_r1r ON #r1_recibe (documento_recibe, ejercicio_recibe, posicion_recibe);

        INSERT INTO gold.fact_aplicacion (
            sociedad, documento_aplica, ejercicio_aplica, posicion_aplica, clase_documento_aplica, clave_contabilizacion_aplica,
            cliente_pagador_id, fecha_aplica, monto_documento_aplica,
            documento_origen, ejercicio_origen, posicion_origen, clase_documento_origen, fecha_origen, monto_documento_origen, saltos,
            documento_recibe, ejercicio_recibe, posicion_recibe, clase_documento_recibe, cliente_factura_id, fecha_factura, fecha_vencimiento, monto_documento_recibe, estado_recibe,
            monto_aplicado, tipo_aplicacion, estatus_identificacion, motivo_no_identificado,
            documento_compensacion, ejercicio_compensacion, fecha_compensacion, fuente_sap, regla, nivel_certeza, origen_resuelto, moneda
        )
        SELECT v.sociedad, v.documento_id, v.ejercicio, v.posicion, v.clase_documento, v.clave_contabilizacion,
               v.cliente_id, v.fecha_contabilizacion, v.monto,
               v.origen_documento, v.origen_ejercicio, v.origen_posicion, v.origen_clase, v.origen_fecha, v.origen_monto, v.saltos,
               r.documento_id, r.ejercicio, r.posicion, r.clase_documento, r.cliente_id, r.fecha_contabilizacion, r.fecha_vencimiento, r.monto_moneda_local, r.estado_sap,
               CASE WHEN v.monto < r.monto_moneda_local THEN v.monto ELSE r.monto_moneda_local END,
               v.tipo_aplicacion, 'IDENTIFICADA', NULL,
               v.documento_compensacion, v.ejercicio_compensacion, v.fecha_compensacion, 'BSAD',
               'R3', 2, v.origen_resuelto, v.moneda
        FROM #veh v
        JOIN #recibe_grupo g ON g.documento_compensacion = v.documento_compensacion AND g.ejercicio_compensacion = v.ejercicio_compensacion AND g.num_recibe = 1
        JOIN #recibe r ON r.documento_compensacion = v.documento_compensacion AND r.ejercicio_compensacion = v.ejercicio_compensacion
        JOIN #r3_grupo c ON c.documento_compensacion = v.documento_compensacion AND c.ejercicio_compensacion = v.ejercicio_compensacion
        LEFT JOIN #r1_recibe a ON a.documento_recibe = r.documento_id AND a.ejercicio_recibe = r.ejercicio AND a.posicion_recibe = r.posicion
        WHERE v.estado_sap = 'COMPENSADO'
          AND c.suma_candidatos <= r.monto_moneda_local - ISNULL(a.aplicado_r1, 0) + 1.00
          AND NOT EXISTS (SELECT 1 FROM #r1 x WHERE x.sociedad = v.sociedad AND x.cliente_id = v.cliente_id AND x.ejercicio = v.ejercicio AND x.documento_id = v.documento_id AND x.posicion = v.posicion);
        SET @n_r3 = @@ROWCOUNT;

        -- ------------------------------------------------------------------
        -- Step 4d: R4 - exactly ONE candidate vehicle in the group (after R1) and several
        -- receiving documents, and that vehicle covers everything R1 left of all of them:
        -- each receiving document is settled in full by the single vehicle. There is nothing
        -- to mis-attribute with one applicator. Not proration: every row is a whole remainder.
        -- (This is the same gate vw_pago_factura_simple adopted on 2026-08-29.)
        -- ------------------------------------------------------------------
        -- R4 covers any number of receiving documents (1 included): with a single candidate,
        -- "the vehicle covers what is left of every receiving document" is the only certain
        -- statement. R3 keeps the other certain shape: several candidates that ALL fit in one
        -- receiving document. The two never overlap: a single candidate that fits inside a
        -- single receiving document is R3 (v.monto <= restante); one that exceeds it is R4.
        -- Remaining amounts are floored at zero - a receiving document over-applied by R1
        -- (capped later in 4b) must not offset the others.
        IF OBJECT_ID('tempdb..#r4_grupo') IS NOT NULL DROP TABLE #r4_grupo;
        SELECT r.documento_compensacion, r.ejercicio_compensacion, g.num_recibe,
               SUM(CASE WHEN r.monto_moneda_local - ISNULL(a.aplicado_r1, 0) > 0 THEN r.monto_moneda_local - ISNULL(a.aplicado_r1, 0) ELSE 0 END)
                 - ISNULL(MAX(d.suma_dif), 0) AS restante_recibe   -- the anchor's own difference lines (step 2f) cover part of it
        INTO #r4_grupo
        FROM #recibe r
        JOIN #recibe_grupo g ON g.documento_compensacion = r.documento_compensacion AND g.ejercicio_compensacion = r.ejercicio_compensacion
        JOIN #r3_grupo c ON c.documento_compensacion = r.documento_compensacion AND c.ejercicio_compensacion = r.ejercicio_compensacion AND c.num_candidatos = 1
        LEFT JOIN #r1_recibe a ON a.documento_recibe = r.documento_id AND a.ejercicio_recibe = r.ejercicio AND a.posicion_recibe = r.posicion
        LEFT JOIN #dif d ON d.documento_compensacion = r.documento_compensacion AND d.ejercicio_compensacion = r.ejercicio_compensacion
        GROUP BY r.documento_compensacion, r.ejercicio_compensacion, g.num_recibe;
        CREATE UNIQUE CLUSTERED INDEX IX_r4g ON #r4_grupo (documento_compensacion, ejercicio_compensacion);

        INSERT INTO gold.fact_aplicacion (
            sociedad, documento_aplica, ejercicio_aplica, posicion_aplica, clase_documento_aplica, clave_contabilizacion_aplica,
            cliente_pagador_id, fecha_aplica, monto_documento_aplica,
            documento_origen, ejercicio_origen, posicion_origen, clase_documento_origen, fecha_origen, monto_documento_origen, saltos,
            documento_recibe, ejercicio_recibe, posicion_recibe, clase_documento_recibe, cliente_factura_id, fecha_factura, fecha_vencimiento, monto_documento_recibe, estado_recibe,
            monto_aplicado, tipo_aplicacion, estatus_identificacion, motivo_no_identificado,
            documento_compensacion, ejercicio_compensacion, fecha_compensacion, fuente_sap, regla, nivel_certeza, origen_resuelto, moneda
        )
        SELECT v.sociedad, v.documento_id, v.ejercicio, v.posicion, v.clase_documento, v.clave_contabilizacion,
               v.cliente_id, v.fecha_contabilizacion, v.monto,
               v.origen_documento, v.origen_ejercicio, v.origen_posicion, v.origen_clase, v.origen_fecha, v.origen_monto, v.saltos,
               r.documento_id, r.ejercicio, r.posicion, r.clase_documento, r.cliente_id, r.fecha_contabilizacion, r.fecha_vencimiento, r.monto_moneda_local, r.estado_sap,
               r.monto_moneda_local - ISNULL(a.aplicado_r1, 0),
               v.tipo_aplicacion, 'IDENTIFICADA', NULL,
               v.documento_compensacion, v.ejercicio_compensacion, v.fecha_compensacion, 'BSAD',
               'R4', 2, v.origen_resuelto, v.moneda
        FROM #veh v
        JOIN #r4_grupo g4 ON g4.documento_compensacion = v.documento_compensacion AND g4.ejercicio_compensacion = v.ejercicio_compensacion
        JOIN #recibe r ON r.documento_compensacion = v.documento_compensacion AND r.ejercicio_compensacion = v.ejercicio_compensacion
        LEFT JOIN #r1_recibe a ON a.documento_recibe = r.documento_id AND a.ejercicio_recibe = r.ejercicio AND a.posicion_recibe = r.posicion
        WHERE v.estado_sap = 'COMPENSADO'
          AND v.monto >= g4.restante_recibe - 1.00
          AND (g4.num_recibe >= 2 OR v.monto > g4.restante_recibe + 1.00)   -- the single-receiver "fits" case belongs to R3
          AND r.monto_moneda_local - ISNULL(a.aplicado_r1, 0) > 0.01
          AND NOT EXISTS (SELECT 1 FROM #r1 x WHERE x.sociedad = v.sociedad AND x.cliente_id = v.cliente_id AND x.ejercicio = v.ejercicio AND x.documento_id = v.documento_id AND x.posicion = v.posicion);
        SET @n_r3 = @n_r3 + @@ROWCOUNT;

        -- ------------------------------------------------------------------
        -- Step 4a: cumulative cap per VEHICLE. R4 hands every receiving document its full
        -- remainder; when the group also holds the anchor's difference lines (step 2f) the
        -- vehicle would exceed its own amount by that difference. The last rows (smallest
        -- invoices) are trimmed to the vehicle's amount - the trimmed cents are the payment
        -- difference SAP posted, not money of this vehicle.
        -- ------------------------------------------------------------------
        ;WITH cap_veh AS (
            SELECT id_aplicacion, monto_aplicado, monto_documento_aplica,
                   SUM(monto_aplicado) OVER (
                       PARTITION BY sociedad, documento_aplica, ejercicio_aplica, posicion_aplica
                       ORDER BY CASE regla WHEN 'R1' THEN 0 ELSE 1 END, monto_aplicado DESC, documento_recibe, posicion_recibe
                       ROWS UNBOUNDED PRECEDING) AS acumulado
            FROM gold.fact_aplicacion
            WHERE regla <> 'R0'
              AND fecha_aplica >= @fecha_desde AND (@fecha_hasta IS NULL OR fecha_aplica < @fecha_hasta)
        )
        UPDATE cap_veh
        SET monto_aplicado = CASE WHEN acumulado - monto_aplicado >= monto_documento_aplica THEN 0
                                  ELSE monto_documento_aplica - (acumulado - monto_aplicado) END
        WHERE acumulado > monto_documento_aplica + 1.00;

        DELETE FROM gold.fact_aplicacion
        WHERE regla <> 'R0' AND monto_aplicado <= 0
          AND fecha_aplica >= @fecha_desde AND (@fecha_hasta IS NULL OR fecha_aplica < @fecha_hasta);

        -- ------------------------------------------------------------------
        -- Step 4b: cumulative cap per RECEIVING document. Two credit notes can both
        -- reference the same invoice (SAP allows it); the second one's surplus is a credit
        -- balance, not an application. R1 rows first, then by date - deterministic, no
        -- proration. Rows reduced to zero are removed (their vehicle's remainder shows in R0).
        -- ------------------------------------------------------------------
        ;WITH cap_recibe AS (
            SELECT id_aplicacion, monto_aplicado, monto_documento_recibe,
                   SUM(monto_aplicado) OVER (
                       PARTITION BY documento_recibe, ejercicio_recibe, posicion_recibe
                       ORDER BY CASE regla WHEN 'R1' THEN 0 ELSE 1 END, fecha_aplica, documento_aplica, posicion_aplica
                       ROWS UNBOUNDED PRECEDING) AS acumulado
            FROM gold.fact_aplicacion
            WHERE regla <> 'R0'
              AND fecha_aplica >= @fecha_desde AND (@fecha_hasta IS NULL OR fecha_aplica < @fecha_hasta)
        )
        UPDATE cap_recibe
        SET monto_aplicado = CASE WHEN acumulado - monto_aplicado >= monto_documento_recibe THEN 0
                                  ELSE monto_documento_recibe - (acumulado - monto_aplicado) END
        WHERE acumulado > monto_documento_recibe + 1.00;   -- $1.00 tolerance: SAP rounding lines (AB 07 of $0.01) make chains exceed by cents

        DELETE FROM gold.fact_aplicacion
        WHERE regla <> 'R0' AND monto_aplicado <= 0
          AND fecha_aplica >= @fecha_desde AND (@fecha_hasta IS NULL OR fecha_aplica < @fecha_hasta);

        -- ------------------------------------------------------------------
        -- Step 4c: cumulative cap per ORIGIN. A child (or an AB) can carry more than the
        -- deposit/credit it was attributed (it also consumed other credits). Rows beyond the
        -- origin's amount keep their application (the invoice really was settled) but lose
        -- the origin - which money funded them is not knowable. The origin's own remainder
        -- then reports the unattributed part as CADENA_AMBIGUA.
        -- ------------------------------------------------------------------
        -- The origin's OWN application rows (vehicle = origin, e.g. a credit note settling an
        -- invoice directly) consume the origin first; only rows of OTHER vehicles can lose it.
        ;WITH cap_origen AS (
            SELECT id_aplicacion, monto_aplicado, monto_documento_origen, documento_origen, origen_resuelto,
                   CASE WHEN documento_origen = documento_aplica AND ejercicio_origen = ejercicio_aplica AND posicion_origen = posicion_aplica THEN 1 ELSE 0 END AS es_propio,
                   SUM(monto_aplicado) OVER (
                       PARTITION BY documento_origen, ejercicio_origen, posicion_origen
                       ORDER BY CASE WHEN documento_origen = documento_aplica AND ejercicio_origen = ejercicio_aplica AND posicion_origen = posicion_aplica THEN 0 ELSE 1 END,
                                CASE regla WHEN 'R1' THEN 0 ELSE 1 END, fecha_aplica, documento_aplica, posicion_aplica
                       ROWS UNBOUNDED PRECEDING) AS acumulado
            FROM gold.fact_aplicacion
            WHERE regla <> 'R0' AND documento_origen IS NOT NULL
              AND fecha_aplica >= @fecha_desde AND (@fecha_hasta IS NULL OR fecha_aplica < @fecha_hasta)
        )
        UPDATE cap_origen
        SET documento_origen = NULL, origen_resuelto = 0
        WHERE acumulado > monto_documento_origen + 1.00 AND es_propio = 0;   -- same $1.00 tolerance (a child re-applying $27,645.96 of a $27,645.93 deposit is rounding, not another credit)

        UPDATE gold.fact_aplicacion
        SET ejercicio_origen = NULL, posicion_origen = NULL, clase_documento_origen = NULL, fecha_origen = NULL, monto_documento_origen = NULL
        WHERE documento_origen IS NULL AND origen_resuelto = 0 AND regla <> 'R0'
          AND fecha_aplica >= @fecha_desde AND (@fecha_hasta IS NULL OR fecha_aplica < @fecha_hasta);

        -- ------------------------------------------------------------------
        -- Step 5: R0 - unidentified. (a) cash origins: whatever of the deposit is not explained
        -- by rows whose origin is that deposit; (b) non-cash vehicles (notes, AB, unresolved
        -- child lines): whatever of the line is neither applied by itself nor through an AB
        -- that consumed it - unless its resolved origin is itself in the window, in which case
        -- the origin's own remainder already reports it.
        -- ------------------------------------------------------------------
        IF OBJECT_ID('tempdb..#aplicado_origen') IS NOT NULL DROP TABLE #aplicado_origen;
        SELECT documento_origen, ejercicio_origen, posicion_origen, SUM(monto_aplicado) AS aplicado
        INTO #aplicado_origen
        FROM gold.fact_aplicacion
        WHERE documento_origen IS NOT NULL AND regla <> 'R0'
        GROUP BY documento_origen, ejercicio_origen, posicion_origen;
        CREATE UNIQUE CLUSTERED INDEX IX_ao ON #aplicado_origen (documento_origen, ejercicio_origen, posicion_origen);

        -- applied by each vehicle itself (any origin) - for the remainder of non-cash vehicles
        IF OBJECT_ID('tempdb..#aplicado_vehiculo') IS NOT NULL DROP TABLE #aplicado_vehiculo;
        SELECT sociedad, documento_aplica, ejercicio_aplica, posicion_aplica, SUM(monto_aplicado) AS aplicado
        INTO #aplicado_vehiculo
        FROM gold.fact_aplicacion
        WHERE regla <> 'R0'
        GROUP BY sociedad, documento_aplica, ejercicio_aplica, posicion_aplica;
        CREATE UNIQUE CLUSTERED INDEX IX_av ON #aplicado_vehiculo (sociedad, documento_aplica, ejercicio_aplica, posicion_aplica);

        -- applied by OTHER vehicles that carry this line as their origin (an AB 17 re-applying a note)
        IF OBJECT_ID('tempdb..#aplicado_origen_otros') IS NOT NULL DROP TABLE #aplicado_origen_otros;
        SELECT documento_origen, ejercicio_origen, posicion_origen, SUM(monto_aplicado) AS aplicado
        INTO #aplicado_origen_otros
        FROM gold.fact_aplicacion
        WHERE regla <> 'R0' AND documento_origen IS NOT NULL
          AND NOT (documento_origen = documento_aplica AND ejercicio_origen = ejercicio_aplica AND posicion_origen = posicion_aplica)
        GROUP BY documento_origen, ejercicio_origen, posicion_origen;
        CREATE UNIQUE CLUSTERED INDEX IX_aoo ON #aplicado_origen_otros (documento_origen, ejercicio_origen, posicion_origen);

        -- (a) cash origins in the window
        INSERT INTO gold.fact_aplicacion (
            sociedad, documento_aplica, ejercicio_aplica, posicion_aplica, clase_documento_aplica, clave_contabilizacion_aplica,
            cliente_pagador_id, fecha_aplica, monto_documento_aplica,
            documento_origen, ejercicio_origen, posicion_origen, clase_documento_origen, fecha_origen, monto_documento_origen, saltos,
            monto_aplicado, tipo_aplicacion, estatus_identificacion, motivo_no_identificado,
            documento_compensacion, ejercicio_compensacion, fecha_compensacion, fuente_sap, regla, nivel_certeza, origen_resuelto, moneda
        )
        SELECT v.sociedad, v.documento_id, v.ejercicio, v.posicion, v.clase_documento, v.clave_contabilizacion,
               v.cliente_id, v.fecha_contabilizacion, v.monto,
               v.documento_id, v.ejercicio, v.posicion, v.clase_documento, v.fecha_contabilizacion, v.monto, 0,
               v.monto - ISNULL(ao.aplicado, 0),
               'PAGO', 'NO_IDENTIFICADA',
               CASE WHEN v.estado_sap = 'ABIERTO' THEN 'ORIGEN_ABIERTO'
                    -- the remainder is (at most) what the child still holds OPEN in bsid: SAP has not applied it yet
                    WHEN h.documento_id IS NOT NULL
                     AND v.monto - ISNULL(ao.aplicado, 0) <= 1.00 + ISNULL((SELECT SUM(c.monto_moneda_local) FROM gold.fact_pagos c
                                                                          WHERE c.sociedad = v.sociedad AND c.ejercicio = h.ejercicio AND c.documento_id = h.documento_id
                                                                            AND c.tipo_linea = 'APLICACION_HIJO' AND c.estado_sap = 'ABIERTO'), 0)
                         THEN 'SOBRANTE_EN_HIJO'
                    WHEN ISNULL(g.num_recibe, 0) >= 1 THEN 'GRUPO_AMBIGUO'   -- 2+ receiving docs with 2+ candidates, or candidates that do not fit / were capped
                    WHEN EXISTS (SELECT 1 FROM gold.fact_pagos c WHERE c.sociedad = v.sociedad AND c.ejercicio = h.ejercicio AND c.documento_id = h.documento_id AND c.tipo_linea = 'APLICACION_HIJO') THEN 'CADENA_AMBIGUA'
                    WHEN ISNULL(g.num_recibe, 0) = 0 THEN 'SIN_DOCUMENTO_EN_GRUPO'
                    ELSE 'SIN_REGLA' END,
               v.documento_compensacion, v.ejercicio_compensacion, v.fecha_compensacion,
               CASE WHEN v.estado_sap = 'ABIERTO' THEN 'BSID' ELSE 'BSAD' END, 'R0', 0, 1, v.moneda
        FROM #cash v
        LEFT JOIN #aplicado_origen ao ON ao.documento_origen = v.documento_id AND ao.ejercicio_origen = v.ejercicio AND ao.posicion_origen = v.posicion
        LEFT JOIN #recibe_grupo g ON g.documento_compensacion = v.documento_compensacion AND g.ejercicio_compensacion = v.ejercicio_compensacion
        LEFT JOIN (SELECT sociedad, ejercicio, documento_id FROM #hijo1) h ON h.sociedad = v.sociedad AND h.ejercicio = v.ejercicio_compensacion AND h.documento_id = v.documento_compensacion
        WHERE v.monto - ISNULL(ao.aplicado, 0) > 1.00;   -- same $1.00 tolerance: a remainder of cents is rounding, not an unidentified payment
        SET @n_r0 = @@ROWCOUNT;

        -- (b) non-cash vehicles with no row at all (notes, AB, child lines whose origin is unresolved)
        INSERT INTO gold.fact_aplicacion (
            sociedad, documento_aplica, ejercicio_aplica, posicion_aplica, clase_documento_aplica, clave_contabilizacion_aplica,
            cliente_pagador_id, fecha_aplica, monto_documento_aplica,
            documento_origen, ejercicio_origen, posicion_origen, clase_documento_origen, fecha_origen, monto_documento_origen, saltos,
            monto_aplicado, tipo_aplicacion, estatus_identificacion, motivo_no_identificado,
            documento_compensacion, ejercicio_compensacion, fecha_compensacion, fuente_sap, regla, nivel_certeza, origen_resuelto, moneda
        )
        SELECT v.sociedad, v.documento_id, v.ejercicio, v.posicion, v.clase_documento, v.clave_contabilizacion,
               v.cliente_id, v.fecha_contabilizacion, v.monto,
               -- an unapplied remainder larger than what is left of the attributed origin means the
               -- vehicle consumed more than that one credit: the origin is dropped, not stretched
               CASE WHEN x.excede = 1 THEN NULL ELSE v.origen_documento END,
               CASE WHEN x.excede = 1 THEN NULL ELSE v.origen_ejercicio END,
               CASE WHEN x.excede = 1 THEN NULL ELSE v.origen_posicion END,
               CASE WHEN x.excede = 1 THEN NULL ELSE v.origen_clase END,
               CASE WHEN x.excede = 1 THEN NULL ELSE v.origen_fecha END,
               CASE WHEN x.excede = 1 THEN NULL ELSE v.origen_monto END,
               v.saltos,
               v.monto - ISNULL(ao.aplicado, 0) - ISNULL(av.aplicado, 0),   -- ao = applied by others with this line as origin, av = applied by this line itself
               v.tipo_aplicacion, 'NO_IDENTIFICADA',
               CASE WHEN v.estado_sap = 'ABIERTO' THEN 'ORIGEN_ABIERTO'
                    WHEN v.origen_resuelto = 0 OR x.excede = 1 THEN 'CADENA_AMBIGUA'
                    WHEN ISNULL(g.num_recibe, 0) >= 1 THEN 'GRUPO_AMBIGUO'   -- 2+ receiving documents, or 1 whose candidates did not fit (R3 refused) / capped away
                    WHEN ISNULL(g.num_recibe, 0) = 0 THEN 'SIN_DOCUMENTO_EN_GRUPO'
                    ELSE 'SIN_REGLA' END,
               v.documento_compensacion, v.ejercicio_compensacion, v.fecha_compensacion,
               CASE WHEN v.estado_sap = 'ABIERTO' THEN 'BSID' ELSE 'BSAD' END, 'R0', 0,
               CASE WHEN x.excede = 1 THEN 0 ELSE v.origen_resuelto END, v.moneda
        FROM #veh v
        LEFT JOIN #recibe_grupo g ON g.documento_compensacion = v.documento_compensacion AND g.ejercicio_compensacion = v.ejercicio_compensacion
        LEFT JOIN #aplicado_origen_otros ao ON ao.documento_origen = v.documento_id AND ao.ejercicio_origen = v.ejercicio AND ao.posicion_origen = v.posicion
        LEFT JOIN #aplicado_vehiculo av ON av.sociedad = v.sociedad AND av.documento_aplica = v.documento_id AND av.ejercicio_aplica = v.ejercicio AND av.posicion_aplica = v.posicion
        LEFT JOIN #aplicado_origen_otros oo ON oo.documento_origen = v.origen_documento AND oo.ejercicio_origen = v.origen_ejercicio AND oo.posicion_origen = v.origen_posicion
        CROSS APPLY (SELECT CASE WHEN v.origen_resuelto = 1
                                  AND NOT (v.origen_documento = v.documento_id AND v.origen_ejercicio = v.ejercicio AND v.origen_posicion = v.posicion)
                                  AND v.monto - ISNULL(ao.aplicado, 0) - ISNULL(av.aplicado, 0) > v.origen_monto - ISNULL(oo.aplicado, 0) + 1.00
                                 THEN 1 ELSE 0 END AS excede) x
        WHERE v.es_origen_efectivo = 0
          AND v.monto - ISNULL(ao.aplicado, 0) - ISNULL(av.aplicado, 0) > 1.00
          -- a vehicle whose resolved origin is another document IN THE WINDOW does not report its
          -- own remainder: that money is reported once, at the origin (cash in (a), a note here)
          AND NOT (
                v.origen_resuelto = 1
            AND NOT (v.origen_documento = v.documento_id AND v.origen_ejercicio = v.ejercicio AND v.origen_posicion = v.posicion)
            AND (   EXISTS (SELECT 1 FROM #cash c WHERE c.documento_id = v.origen_documento AND c.ejercicio = v.origen_ejercicio AND c.posicion = v.origen_posicion)
                 OR EXISTS (SELECT 1 FROM #veh  w WHERE w.documento_id = v.origen_documento AND w.ejercicio = v.origen_ejercicio AND w.posicion = v.origen_posicion AND w.es_origen_efectivo = 0))
          );
        SET @n_r0 = @n_r0 + @@ROWCOUNT;

        -- ------------------------------------------------------------------
        -- Step 5c: R6 - identified at LOT level (user decision 2026-09-03). The money
        -- demonstrably went into a set of invoices, but the split per invoice is not unique
        -- (several candidates, notes referencing invoices paid elsewhere, K deposits merged
        -- into one child). The row keeps documento_recibe NULL and records the lot instead.
        -- Never a guess: nothing is attributed to any single invoice.
        -- ------------------------------------------------------------------
        DECLARE @lote_max_facturas INT = 20;          -- a lot a person can still read
        DECLARE @lote_min_cobertura DECIMAL(5,4) = 0.50;  -- or the money is most of the lot

        -- (a) LOTE_EN_GRUPO: the unidentified candidates of a cleared group fit in what its
        --     invoices have left after every identified row of that group.
        IF OBJECT_ID('tempdb..#lote_grupo') IS NOT NULL DROP TABLE #lote_grupo;
        SELECT r.documento_compensacion, r.ejercicio_compensacion,
               COUNT(*) AS num_facturas, SUM(r.monto_moneda_local) AS monto_facturas,
               SUM(r.monto_moneda_local) - ISNULL(MAX(i.identificado), 0) AS restante,
               ISNULL(MAX(u.no_identificado), 0) AS no_identificado
        INTO #lote_grupo
        FROM #recibe r
        LEFT JOIN (SELECT documento_compensacion, ejercicio_compensacion, SUM(monto_aplicado) AS identificado
                   FROM gold.fact_aplicacion WHERE regla <> 'R0' GROUP BY documento_compensacion, ejercicio_compensacion) i
               ON i.documento_compensacion = r.documento_compensacion AND i.ejercicio_compensacion = r.ejercicio_compensacion
        LEFT JOIN (SELECT documento_compensacion, ejercicio_compensacion, SUM(monto_aplicado) AS no_identificado
                   FROM gold.fact_aplicacion WHERE regla = 'R0' AND estatus_identificacion = 'NO_IDENTIFICADA' AND documento_compensacion IS NOT NULL
                   GROUP BY documento_compensacion, ejercicio_compensacion) u
               ON u.documento_compensacion = r.documento_compensacion AND u.ejercicio_compensacion = r.ejercicio_compensacion
        WHERE r.documento_compensacion IS NOT NULL
        GROUP BY r.documento_compensacion, r.ejercicio_compensacion
        HAVING ISNULL(MAX(u.no_identificado), 0) > 0
           AND ISNULL(MAX(u.no_identificado), 0) <= SUM(r.monto_moneda_local) - ISNULL(MAX(i.identificado), 0) + 1.00;
        CREATE UNIQUE CLUSTERED INDEX IX_lg ON #lote_grupo (documento_compensacion, ejercicio_compensacion);

        UPDATE f
        SET f.estatus_identificacion = 'IDENTIFICADA_LOTE',
            f.motivo_no_identificado = 'LOTE_EN_GRUPO',
            f.nivel_certeza          = 3,
            f.documento_lote         = l.documento_compensacion,
            f.ejercicio_lote         = l.ejercicio_compensacion,
            f.num_facturas_lote      = l.num_facturas,
            f.monto_facturas_lote    = l.monto_facturas
        FROM gold.fact_aplicacion f
        JOIN #lote_grupo l ON l.documento_compensacion = f.documento_compensacion AND l.ejercicio_compensacion = f.ejercicio_compensacion
        WHERE f.regla = 'R0' AND f.estatus_identificacion = 'NO_IDENTIFICADA'
          AND f.motivo_no_identificado IN ('GRUPO_AMBIGUO', 'SIN_REGLA')
          -- gate: a lot is only an identification when the ambiguity is bounded. Either the
          -- lot is small enough to be read by a person, or the money is essentially the whole
          -- lot. "$300 somewhere inside 1,400 invoices" is noise, not an identification.
          AND (l.num_facturas <= @lote_max_facturas
               OR (l.monto_facturas > 0 AND f.monto_aplicado >= @lote_min_cobertura * l.monto_facturas))
          AND f.fecha_aplica >= @fecha_desde AND (@fecha_hasta IS NULL OR f.fecha_aplica < @fecha_hasta);

        -- (b) LOTE_EN_HIJO: K deposits merged into one child whose lines are all applied (or
        --     still open) and together account for those deposits: each deposit is identified
        --     through the child, without knowing which invoice took which deposit.
        IF OBJECT_ID('tempdb..#lote_hijo') IS NOT NULL DROP TABLE #lote_hijo;
        -- (this server cannot aggregate an expression that contains a subquery, so the
        --  per-line flag and the per-child totals are materialised step by step)
        IF OBJECT_ID('tempdb..#hijo_lin') IS NOT NULL DROP TABLE #hijo_lin;
        SELECT c.sociedad, c.ejercicio, c.documento_id, c.posicion, c.monto_moneda_local,
               CAST(CASE WHEN c.estado_sap = 'ABIERTO' THEN 1
                         WHEN EXISTS (SELECT 1 FROM gold.fact_aplicacion a
                                       WHERE a.sociedad         = c.sociedad
                                         AND a.documento_aplica = c.documento_id
                                         AND a.ejercicio_aplica = c.ejercicio
                                         AND a.posicion_aplica  = c.posicion
                                         AND a.regla <> 'R0') THEN 1
                         ELSE 0 END AS TINYINT) AS aplicada_o_abierta
        INTO #hijo_lin
        FROM gold.fact_pagos c
        JOIN #hijo1 h ON h.sociedad = c.sociedad AND h.ejercicio = c.ejercicio AND h.documento_id = c.documento_id
        WHERE c.tipo_linea = 'APLICACION_HIJO';

        IF OBJECT_ID('tempdb..#hijo_tot') IS NOT NULL DROP TABLE #hijo_tot;
        SELECT sociedad, ejercicio, documento_id,
               SUM(monto_moneda_local) AS total_hijo,
               SUM(CASE WHEN aplicada_o_abierta = 1 THEN monto_moneda_local ELSE 0 END) AS aplicado_o_abierto
        INTO #hijo_tot
        FROM #hijo_lin
        GROUP BY sociedad, ejercicio, documento_id;

        -- invoices actually reached through that child (the lot the money went into)
        IF OBJECT_ID('tempdb..#hijo_fac') IS NOT NULL DROP TABLE #hijo_fac;
        SELECT a.sociedad, a.ejercicio_aplica AS ejercicio, a.documento_aplica AS documento_id,
               COUNT(DISTINCT a.documento_recibe) AS num_facturas,
               SUM(a.monto_aplicado)              AS monto_facturas
        INTO #hijo_fac
        FROM gold.fact_aplicacion a
        JOIN #hijo1 h ON h.sociedad = a.sociedad AND h.ejercicio = a.ejercicio_aplica AND h.documento_id = a.documento_aplica
        WHERE a.regla <> 'R0'
        GROUP BY a.sociedad, a.ejercicio_aplica, a.documento_aplica;

        SELECT t.sociedad, t.ejercicio, t.documento_id,
               ISNULL(fc.num_facturas, 0)   AS num_facturas,
               ISNULL(fc.monto_facturas, 0) AS monto_facturas
        INTO #lote_hijo
        FROM #hijo_tot t
        JOIN (SELECT v.sociedad, v.ejercicio_hijo, v.documento_hijo, SUM(v.monto_moneda_local) AS total_virgenes
              FROM gold.fact_pagos v WHERE v.tipo_linea = 'VIRGEN' AND v.revertido = 0 AND v.es_reembolso = 0
              GROUP BY v.sociedad, v.ejercicio_hijo, v.documento_hijo) tv
          ON tv.sociedad = t.sociedad AND tv.ejercicio_hijo = t.ejercicio AND tv.documento_hijo = t.documento_id
        LEFT JOIN #hijo_fac fc
          ON fc.sociedad = t.sociedad AND fc.ejercicio = t.ejercicio AND fc.documento_id = t.documento_id
        WHERE t.aplicado_o_abierto >= t.total_hijo - 1.00
          AND t.total_hijo         >= tv.total_virgenes - 1.00;
        CREATE UNIQUE CLUSTERED INDEX IX_lh ON #lote_hijo (sociedad, ejercicio, documento_id);

        UPDATE f
        SET f.estatus_identificacion = 'IDENTIFICADA_LOTE',
            f.motivo_no_identificado = 'LOTE_EN_HIJO',
            f.nivel_certeza          = 3,
            f.documento_lote         = l.documento_id,
            f.ejercicio_lote         = l.ejercicio,
            f.num_facturas_lote      = l.num_facturas,
            f.monto_facturas_lote    = l.monto_facturas
        FROM gold.fact_aplicacion f
        JOIN gold.fact_pagos p ON p.sociedad = f.sociedad AND p.documento_id = f.documento_aplica AND p.ejercicio = f.ejercicio_aplica AND p.posicion = f.posicion_aplica
        JOIN #lote_hijo l ON l.sociedad = p.sociedad AND l.ejercicio = p.ejercicio_hijo AND l.documento_id = p.documento_hijo
        WHERE f.regla = 'R0' AND f.estatus_identificacion = 'NO_IDENTIFICADA' AND f.tipo_aplicacion = 'PAGO'
          AND f.motivo_no_identificado IN ('CADENA_AMBIGUA', 'SIN_DOCUMENTO_EN_GRUPO', 'GRUPO_AMBIGUO', 'SIN_REGLA')
          -- same gate as (a); a child's lot is small by construction, this only keeps it that way
          AND (l.num_facturas <= @lote_max_facturas
               OR (l.monto_facturas > 0 AND f.monto_aplicado >= @lote_min_cobertura * l.monto_facturas))
          AND f.fecha_aplica >= @fecha_desde AND (@fecha_hasta IS NULL OR f.fecha_aplica < @fecha_hasta);

        -- ------------------------------------------------------------------
        -- SCD2 keys of the payer, resolved on the origin date when known
        -- ------------------------------------------------------------------
        UPDATE f
        SET f.cliente_comercial_sk = dcc.id_surrogate,
            f.cliente_credito_sk   = dck.id_surrogate
        FROM gold.fact_aplicacion f
        LEFT JOIN gold.dim_cliente_comercial dcc
               ON dcc.cliente_id = f.cliente_pagador_id
              AND ISNULL(f.fecha_origen, f.fecha_aplica) >= dcc.fecha_inicio_vigencia
              AND (dcc.fecha_fin_vigencia IS NULL OR ISNULL(f.fecha_origen, f.fecha_aplica) <= dcc.fecha_fin_vigencia)
        LEFT JOIN gold.dim_cliente_credito dck
               ON dck.cliente_id = f.cliente_pagador_id
              AND ISNULL(f.fecha_origen, f.fecha_aplica) >= dck.fecha_inicio_vigencia
              AND (dck.fecha_fin_vigencia IS NULL OR ISNULL(f.fecha_origen, f.fecha_aplica) <= dck.fecha_fin_vigencia)
        WHERE f.fecha_aplica >= @fecha_desde AND (@fecha_hasta IS NULL OR f.fecha_aplica < @fecha_hasta);

        -- ------------------------------------------------------------------
        -- Step 6: invariants (every count must be 0)
        -- ------------------------------------------------------------------
        SELECT @inv1 = COUNT(*) FROM (
            SELECT documento_recibe, ejercicio_recibe, posicion_recibe
            FROM gold.fact_aplicacion WHERE regla <> 'R0'
            GROUP BY documento_recibe, ejercicio_recibe, posicion_recibe, monto_documento_recibe
            HAVING SUM(monto_aplicado) > monto_documento_recibe + 1.00) x;
        SELECT @inv2 = COUNT(*) FROM (
            SELECT documento_origen, ejercicio_origen, posicion_origen
            FROM gold.fact_aplicacion WHERE documento_origen IS NOT NULL
            GROUP BY documento_origen, ejercicio_origen, posicion_origen, monto_documento_origen
            HAVING SUM(monto_aplicado) > monto_documento_origen + 1.00) x;
        SELECT @inv3 = COUNT(*) FROM (
            SELECT documento_aplica, ejercicio_aplica, posicion_aplica, documento_recibe, ejercicio_recibe, posicion_recibe
            FROM gold.fact_aplicacion WHERE regla <> 'R0'
            GROUP BY documento_aplica, ejercicio_aplica, posicion_aplica, documento_recibe, ejercicio_recibe, posicion_recibe
            HAVING COUNT(*) > 1) x;

        PRINT 'deleted: ' + CAST(@n_del AS VARCHAR) + ' | vehicles: ' + CAST(@n_veh AS VARCHAR)
            + ' | R1: ' + CAST(@n_r1 AS VARCHAR) + ' | R3+R4: ' + CAST(@n_r3 AS VARCHAR) + ' | R0: ' + CAST(@n_r0 AS VARCHAR)
            + ' | ' + CAST(DATEDIFF(SECOND, @start_time, GETDATE()) AS VARCHAR) + ' s';
        PRINT 'invariants -> over-applied receiving docs: ' + CAST(@inv1 AS VARCHAR)
            + ' | over-applied origins: ' + CAST(@inv2 AS VARCHAR)
            + ' | duplicate (aplica, recibe) pairs: ' + CAST(@inv3 AS VARCHAR) + '   (all must be 0)';
    END TRY
    BEGIN CATCH
        PRINT 'ERROR in gold.load_fact_aplicacion: ' + ERROR_MESSAGE();
        THROW;
    END CATCH;
END;
GO
PRINT 'Procedure gold.load_fact_aplicacion created.';
GO
