USE ANALISIS_DATOS;
GO

/*
========================================================================================
HISTORICAL BACKFILL: silver.sap_bsad
========================================================================================
PURPOSE:
silver.sap_bsad only has ~295K rows (the 2-month window silver.load_silver's incremental
MERGE maintains), while bronze.sap_bsad already has the complete history since
2022-01-01 (~12.2M rows). This script backfills everything before the window the daily
incremental already maintains, so as not to duplicate or step on its work.

UPPER BOUND:
silver.load_silver maintains AUGDT >= first day of the previous month. This backfill
covers everything BEFORE that bound. The bound is computed dynamically (same formula as
sp_load_silver.sql) so it stays correct no matter what day this is run.

CHUNK PATTERN (same as bronze.sap_bsad's original backfill):
One chunk per year. Each chunk is DELETE + INSERT (idempotent - safe to re-run the same
chunk if it fails halfway or the VPN drops). If a full year breaks with:
    Msg 9002: The transaction log for database 'ANALISIS_DATOS' is full
split THAT year into two halves (half-years) and run each half separately, with the
same DELETE+INSERT pattern but a narrower date range. If a half-year still breaks, keep
splitting into quarters or months. Example of splitting the 2022 chunk in two:

    -- 2022 first half
    ... WHERE fecha_compensacion >= '20220101' AND fecha_compensacion < '20220701'
    ... WHERE AUGDT >= '20220101' AND AUGDT < '20220701'

    -- 2022 second half
    ... WHERE fecha_compensacion >= '20220701' AND fecha_compensacion < '20230101'
    ... WHERE AUGDT >= '20220701' AND AUGDT < '20230101'

Don't run two chunks at the same time in different SSMS tabs - one at a time, in order,
checking the rows-inserted PRINT output before moving on to the next.
========================================================================================
*/

-- Checks the upper bound before starting (informational, doesn't do anything by itself)
DECLARE @limite_check NVARCHAR(8) = CONVERT(NVARCHAR(8), DATEADD(MONTH, DATEDIFF(MONTH, 0, GETDATE()) - 1, 0), 112);
SELECT @limite_check AS limite_superior_backfill_AUGDT;
GO

-- ========================================================================================
-- Full 2022
-- ========================================================================================
DELETE FROM silver.sap_bsad
WHERE mandante = '400'
  AND fecha_compensacion >= '20220101' AND fecha_compensacion < '20230101';

INSERT INTO silver.sap_bsad (
    mandante, sociedad, cliente_id, ejercicio, mes, documento_id,
    asignacion, referencia, documento_ventas, posicion,
    fecha_contabilizacion, fecha_documento, fecha_registro_sistema, fecha_compensacion,
    documento_compensacion, ejercicio_compensacion, clase_documento, codigo_impuesto, debe_haber,
    fecha_vencimiento, monto_moneda_local,
    monto_moneda_doc, moneda, condicion_pago, dias_plazo, sgtxt,
    factura_referencia_documento, factura_referencia_ejercicio, factura_referencia_posicion,
    area_reclamacion, nivel_reclamacion, clave_reclamacion_legal,
    bloqueo_reclamacion_temporal, fecha_ultima_reclamacion
)
SELECT
    LTRIM(RTRIM(MANDT)),
    LTRIM(RTRIM(BUKRS)),
    CAST(CAST(NULLIF(LTRIM(RTRIM(KUNNR)), '') AS BIGINT) AS VARCHAR(10)),
    GJAHR,
    NULLIF(LTRIM(RTRIM(MONAT)), ''),
    LTRIM(RTRIM(BELNR)),
    NULLIF(LTRIM(RTRIM(ZUONR)), ''),
    NULLIF(LTRIM(RTRIM(XBLNR)), ''),
    NULLIF(LTRIM(RTRIM(VBELN)), ''),
    BUZEI,
    TRY_CONVERT(DATE, NULLIF(LTRIM(RTRIM(BUDAT)), '00000000'), 112),
    TRY_CONVERT(DATE, NULLIF(LTRIM(RTRIM(BLDAT)), '00000000'), 112),
    TRY_CONVERT(DATE, NULLIF(LTRIM(RTRIM(CPUDT)), '00000000'), 112),
    TRY_CONVERT(DATE, NULLIF(LTRIM(RTRIM(AUGDT)), '00000000'), 112),
    NULLIF(LTRIM(RTRIM(AUGBL)), ''),
    TRY_CAST(NULLIF(LTRIM(RTRIM(AUGGJ)), '') AS INT),
    NULLIF(LTRIM(RTRIM(BLART)), ''),
    NULLIF(LTRIM(RTRIM(MWSKZ)), ''),
    NULLIF(LTRIM(RTRIM(SHKZG)), ''),
    DATEADD(DAY, ISNULL(ZBD1T, 0), TRY_CONVERT(DATE, NULLIF(LTRIM(RTRIM(ZFBDT)), '00000000'), 112)),
    ISNULL(DMBTR, 0),
    ISNULL(WRBTR, 0),
    NULLIF(LTRIM(RTRIM(WAERS)), ''),
    NULLIF(LTRIM(RTRIM(ZTERM)), ''),
    ISNULL(ZBD1T, 0),
    NULLIF(LTRIM(RTRIM(SGTXT)), ''),
    NULLIF(LTRIM(RTRIM(REBZG)), ''),
    TRY_CAST(NULLIF(LTRIM(RTRIM(REBZJ)), '') AS INT),
    TRY_CAST(NULLIF(LTRIM(RTRIM(REBZZ)), '') AS INT),
    NULLIF(LTRIM(RTRIM(MABER)), ''),
    NULLIF(LTRIM(RTRIM(MANST)), ''),
    NULLIF(LTRIM(RTRIM(MSCHL)), ''),
    NULLIF(LTRIM(RTRIM(MANSP)), ''),
    TRY_CONVERT(DATE, NULLIF(LTRIM(RTRIM(MADAT)), '00000000'), 112)
FROM bronze.sap_bsad WITH (NOLOCK)
WHERE MANDT = '400'
  AND AUGDT >= '20220101' AND AUGDT < '20230101';

PRINT 'Rows inserted 2022: ' + CAST(@@ROWCOUNT AS VARCHAR);
GO

-- ========================================================================================
-- Full 2023
-- ========================================================================================
DELETE FROM silver.sap_bsad
WHERE mandante = '400'
  AND fecha_compensacion >= '20230101' AND fecha_compensacion < '20240101';

INSERT INTO silver.sap_bsad (
    mandante, sociedad, cliente_id, ejercicio, mes, documento_id,
    asignacion, referencia, documento_ventas, posicion,
    fecha_contabilizacion, fecha_documento, fecha_registro_sistema, fecha_compensacion,
    documento_compensacion, ejercicio_compensacion, clase_documento, codigo_impuesto, debe_haber,
    fecha_vencimiento, monto_moneda_local,
    monto_moneda_doc, moneda, condicion_pago, dias_plazo, sgtxt,
    factura_referencia_documento, factura_referencia_ejercicio, factura_referencia_posicion,
    area_reclamacion, nivel_reclamacion, clave_reclamacion_legal,
    bloqueo_reclamacion_temporal, fecha_ultima_reclamacion
)
SELECT
    LTRIM(RTRIM(MANDT)),
    LTRIM(RTRIM(BUKRS)),
    CAST(CAST(NULLIF(LTRIM(RTRIM(KUNNR)), '') AS BIGINT) AS VARCHAR(10)),
    GJAHR,
    NULLIF(LTRIM(RTRIM(MONAT)), ''),
    LTRIM(RTRIM(BELNR)),
    NULLIF(LTRIM(RTRIM(ZUONR)), ''),
    NULLIF(LTRIM(RTRIM(XBLNR)), ''),
    NULLIF(LTRIM(RTRIM(VBELN)), ''),
    BUZEI,
    TRY_CONVERT(DATE, NULLIF(LTRIM(RTRIM(BUDAT)), '00000000'), 112),
    TRY_CONVERT(DATE, NULLIF(LTRIM(RTRIM(BLDAT)), '00000000'), 112),
    TRY_CONVERT(DATE, NULLIF(LTRIM(RTRIM(CPUDT)), '00000000'), 112),
    TRY_CONVERT(DATE, NULLIF(LTRIM(RTRIM(AUGDT)), '00000000'), 112),
    NULLIF(LTRIM(RTRIM(AUGBL)), ''),
    TRY_CAST(NULLIF(LTRIM(RTRIM(AUGGJ)), '') AS INT),
    NULLIF(LTRIM(RTRIM(BLART)), ''),
    NULLIF(LTRIM(RTRIM(MWSKZ)), ''),
    NULLIF(LTRIM(RTRIM(SHKZG)), ''),
    DATEADD(DAY, ISNULL(ZBD1T, 0), TRY_CONVERT(DATE, NULLIF(LTRIM(RTRIM(ZFBDT)), '00000000'), 112)),
    ISNULL(DMBTR, 0),
    ISNULL(WRBTR, 0),
    NULLIF(LTRIM(RTRIM(WAERS)), ''),
    NULLIF(LTRIM(RTRIM(ZTERM)), ''),
    ISNULL(ZBD1T, 0),
    NULLIF(LTRIM(RTRIM(SGTXT)), ''),
    NULLIF(LTRIM(RTRIM(REBZG)), ''),
    TRY_CAST(NULLIF(LTRIM(RTRIM(REBZJ)), '') AS INT),
    TRY_CAST(NULLIF(LTRIM(RTRIM(REBZZ)), '') AS INT),
    NULLIF(LTRIM(RTRIM(MABER)), ''),
    NULLIF(LTRIM(RTRIM(MANST)), ''),
    NULLIF(LTRIM(RTRIM(MSCHL)), ''),
    NULLIF(LTRIM(RTRIM(MANSP)), ''),
    TRY_CONVERT(DATE, NULLIF(LTRIM(RTRIM(MADAT)), '00000000'), 112)
FROM bronze.sap_bsad WITH (NOLOCK)
WHERE MANDT = '400'
  AND AUGDT >= '20230101' AND AUGDT < '20240101';

PRINT 'Rows inserted 2023: ' + CAST(@@ROWCOUNT AS VARCHAR);
GO

-- ========================================================================================
-- Full 2024
-- ========================================================================================
DELETE FROM silver.sap_bsad
WHERE mandante = '400'
  AND fecha_compensacion >= '20240101' AND fecha_compensacion < '20250101';

INSERT INTO silver.sap_bsad (
    mandante, sociedad, cliente_id, ejercicio, mes, documento_id,
    asignacion, referencia, documento_ventas, posicion,
    fecha_contabilizacion, fecha_documento, fecha_registro_sistema, fecha_compensacion,
    documento_compensacion, ejercicio_compensacion, clase_documento, codigo_impuesto, debe_haber,
    fecha_vencimiento, monto_moneda_local,
    monto_moneda_doc, moneda, condicion_pago, dias_plazo, sgtxt,
    factura_referencia_documento, factura_referencia_ejercicio, factura_referencia_posicion,
    area_reclamacion, nivel_reclamacion, clave_reclamacion_legal,
    bloqueo_reclamacion_temporal, fecha_ultima_reclamacion
)
SELECT
    LTRIM(RTRIM(MANDT)),
    LTRIM(RTRIM(BUKRS)),
    CAST(CAST(NULLIF(LTRIM(RTRIM(KUNNR)), '') AS BIGINT) AS VARCHAR(10)),
    GJAHR,
    NULLIF(LTRIM(RTRIM(MONAT)), ''),
    LTRIM(RTRIM(BELNR)),
    NULLIF(LTRIM(RTRIM(ZUONR)), ''),
    NULLIF(LTRIM(RTRIM(XBLNR)), ''),
    NULLIF(LTRIM(RTRIM(VBELN)), ''),
    BUZEI,
    TRY_CONVERT(DATE, NULLIF(LTRIM(RTRIM(BUDAT)), '00000000'), 112),
    TRY_CONVERT(DATE, NULLIF(LTRIM(RTRIM(BLDAT)), '00000000'), 112),
    TRY_CONVERT(DATE, NULLIF(LTRIM(RTRIM(CPUDT)), '00000000'), 112),
    TRY_CONVERT(DATE, NULLIF(LTRIM(RTRIM(AUGDT)), '00000000'), 112),
    NULLIF(LTRIM(RTRIM(AUGBL)), ''),
    TRY_CAST(NULLIF(LTRIM(RTRIM(AUGGJ)), '') AS INT),
    NULLIF(LTRIM(RTRIM(BLART)), ''),
    NULLIF(LTRIM(RTRIM(MWSKZ)), ''),
    NULLIF(LTRIM(RTRIM(SHKZG)), ''),
    DATEADD(DAY, ISNULL(ZBD1T, 0), TRY_CONVERT(DATE, NULLIF(LTRIM(RTRIM(ZFBDT)), '00000000'), 112)),
    ISNULL(DMBTR, 0),
    ISNULL(WRBTR, 0),
    NULLIF(LTRIM(RTRIM(WAERS)), ''),
    NULLIF(LTRIM(RTRIM(ZTERM)), ''),
    ISNULL(ZBD1T, 0),
    NULLIF(LTRIM(RTRIM(SGTXT)), ''),
    NULLIF(LTRIM(RTRIM(REBZG)), ''),
    TRY_CAST(NULLIF(LTRIM(RTRIM(REBZJ)), '') AS INT),
    TRY_CAST(NULLIF(LTRIM(RTRIM(REBZZ)), '') AS INT),
    NULLIF(LTRIM(RTRIM(MABER)), ''),
    NULLIF(LTRIM(RTRIM(MANST)), ''),
    NULLIF(LTRIM(RTRIM(MSCHL)), ''),
    NULLIF(LTRIM(RTRIM(MANSP)), ''),
    TRY_CONVERT(DATE, NULLIF(LTRIM(RTRIM(MADAT)), '00000000'), 112)
FROM bronze.sap_bsad WITH (NOLOCK)
WHERE MANDT = '400'
  AND AUGDT >= '20240101' AND AUGDT < '20250101';

PRINT 'Rows inserted 2024: ' + CAST(@@ROWCOUNT AS VARCHAR);
GO

-- ========================================================================================
-- Full 2025
-- ========================================================================================
DELETE FROM silver.sap_bsad
WHERE mandante = '400'
  AND fecha_compensacion >= '20250101' AND fecha_compensacion < '20260101';

INSERT INTO silver.sap_bsad (
    mandante, sociedad, cliente_id, ejercicio, mes, documento_id,
    asignacion, referencia, documento_ventas, posicion,
    fecha_contabilizacion, fecha_documento, fecha_registro_sistema, fecha_compensacion,
    documento_compensacion, ejercicio_compensacion, clase_documento, codigo_impuesto, debe_haber,
    fecha_vencimiento, monto_moneda_local,
    monto_moneda_doc, moneda, condicion_pago, dias_plazo, sgtxt,
    factura_referencia_documento, factura_referencia_ejercicio, factura_referencia_posicion,
    area_reclamacion, nivel_reclamacion, clave_reclamacion_legal,
    bloqueo_reclamacion_temporal, fecha_ultima_reclamacion
)
SELECT
    LTRIM(RTRIM(MANDT)),
    LTRIM(RTRIM(BUKRS)),
    CAST(CAST(NULLIF(LTRIM(RTRIM(KUNNR)), '') AS BIGINT) AS VARCHAR(10)),
    GJAHR,
    NULLIF(LTRIM(RTRIM(MONAT)), ''),
    LTRIM(RTRIM(BELNR)),
    NULLIF(LTRIM(RTRIM(ZUONR)), ''),
    NULLIF(LTRIM(RTRIM(XBLNR)), ''),
    NULLIF(LTRIM(RTRIM(VBELN)), ''),
    BUZEI,
    TRY_CONVERT(DATE, NULLIF(LTRIM(RTRIM(BUDAT)), '00000000'), 112),
    TRY_CONVERT(DATE, NULLIF(LTRIM(RTRIM(BLDAT)), '00000000'), 112),
    TRY_CONVERT(DATE, NULLIF(LTRIM(RTRIM(CPUDT)), '00000000'), 112),
    TRY_CONVERT(DATE, NULLIF(LTRIM(RTRIM(AUGDT)), '00000000'), 112),
    NULLIF(LTRIM(RTRIM(AUGBL)), ''),
    TRY_CAST(NULLIF(LTRIM(RTRIM(AUGGJ)), '') AS INT),
    NULLIF(LTRIM(RTRIM(BLART)), ''),
    NULLIF(LTRIM(RTRIM(MWSKZ)), ''),
    NULLIF(LTRIM(RTRIM(SHKZG)), ''),
    DATEADD(DAY, ISNULL(ZBD1T, 0), TRY_CONVERT(DATE, NULLIF(LTRIM(RTRIM(ZFBDT)), '00000000'), 112)),
    ISNULL(DMBTR, 0),
    ISNULL(WRBTR, 0),
    NULLIF(LTRIM(RTRIM(WAERS)), ''),
    NULLIF(LTRIM(RTRIM(ZTERM)), ''),
    ISNULL(ZBD1T, 0),
    NULLIF(LTRIM(RTRIM(SGTXT)), ''),
    NULLIF(LTRIM(RTRIM(REBZG)), ''),
    TRY_CAST(NULLIF(LTRIM(RTRIM(REBZJ)), '') AS INT),
    TRY_CAST(NULLIF(LTRIM(RTRIM(REBZZ)), '') AS INT),
    NULLIF(LTRIM(RTRIM(MABER)), ''),
    NULLIF(LTRIM(RTRIM(MANST)), ''),
    NULLIF(LTRIM(RTRIM(MSCHL)), ''),
    NULLIF(LTRIM(RTRIM(MANSP)), ''),
    TRY_CONVERT(DATE, NULLIF(LTRIM(RTRIM(MADAT)), '00000000'), 112)
FROM bronze.sap_bsad WITH (NOLOCK)
WHERE MANDT = '400'
  AND AUGDT >= '20250101' AND AUGDT < '20260101';

PRINT 'Rows inserted 2025: ' + CAST(@@ROWCOUNT AS VARCHAR);
GO

-- ========================================================================================
-- Partial 2026: from Jan 1st up to the bound the daily incremental already covers
-- (dynamic bound - does NOT touch the 2-month window silver.load_silver maintains)
-- ========================================================================================
DECLARE @limite_date DATE = DATEADD(MONTH, DATEDIFF(MONTH, 0, GETDATE()) - 1, 0);
DECLARE @limite_str  NVARCHAR(8) = CONVERT(NVARCHAR(8), @limite_date, 112);

DELETE FROM silver.sap_bsad
WHERE mandante = '400'
  AND fecha_compensacion >= '20260101' AND fecha_compensacion < @limite_date;

INSERT INTO silver.sap_bsad (
    mandante, sociedad, cliente_id, ejercicio, mes, documento_id,
    asignacion, referencia, documento_ventas, posicion,
    fecha_contabilizacion, fecha_documento, fecha_registro_sistema, fecha_compensacion,
    documento_compensacion, ejercicio_compensacion, clase_documento, codigo_impuesto, debe_haber,
    fecha_vencimiento, monto_moneda_local,
    monto_moneda_doc, moneda, condicion_pago, dias_plazo, sgtxt,
    factura_referencia_documento, factura_referencia_ejercicio, factura_referencia_posicion,
    area_reclamacion, nivel_reclamacion, clave_reclamacion_legal,
    bloqueo_reclamacion_temporal, fecha_ultima_reclamacion
)
SELECT
    LTRIM(RTRIM(MANDT)),
    LTRIM(RTRIM(BUKRS)),
    CAST(CAST(NULLIF(LTRIM(RTRIM(KUNNR)), '') AS BIGINT) AS VARCHAR(10)),
    GJAHR,
    NULLIF(LTRIM(RTRIM(MONAT)), ''),
    LTRIM(RTRIM(BELNR)),
    NULLIF(LTRIM(RTRIM(ZUONR)), ''),
    NULLIF(LTRIM(RTRIM(XBLNR)), ''),
    NULLIF(LTRIM(RTRIM(VBELN)), ''),
    BUZEI,
    TRY_CONVERT(DATE, NULLIF(LTRIM(RTRIM(BUDAT)), '00000000'), 112),
    TRY_CONVERT(DATE, NULLIF(LTRIM(RTRIM(BLDAT)), '00000000'), 112),
    TRY_CONVERT(DATE, NULLIF(LTRIM(RTRIM(CPUDT)), '00000000'), 112),
    TRY_CONVERT(DATE, NULLIF(LTRIM(RTRIM(AUGDT)), '00000000'), 112),
    NULLIF(LTRIM(RTRIM(AUGBL)), ''),
    TRY_CAST(NULLIF(LTRIM(RTRIM(AUGGJ)), '') AS INT),
    NULLIF(LTRIM(RTRIM(BLART)), ''),
    NULLIF(LTRIM(RTRIM(MWSKZ)), ''),
    NULLIF(LTRIM(RTRIM(SHKZG)), ''),
    DATEADD(DAY, ISNULL(ZBD1T, 0), TRY_CONVERT(DATE, NULLIF(LTRIM(RTRIM(ZFBDT)), '00000000'), 112)),
    ISNULL(DMBTR, 0),
    ISNULL(WRBTR, 0),
    NULLIF(LTRIM(RTRIM(WAERS)), ''),
    NULLIF(LTRIM(RTRIM(ZTERM)), ''),
    ISNULL(ZBD1T, 0),
    NULLIF(LTRIM(RTRIM(SGTXT)), ''),
    NULLIF(LTRIM(RTRIM(REBZG)), ''),
    TRY_CAST(NULLIF(LTRIM(RTRIM(REBZJ)), '') AS INT),
    TRY_CAST(NULLIF(LTRIM(RTRIM(REBZZ)), '') AS INT),
    NULLIF(LTRIM(RTRIM(MABER)), ''),
    NULLIF(LTRIM(RTRIM(MANST)), ''),
    NULLIF(LTRIM(RTRIM(MSCHL)), ''),
    NULLIF(LTRIM(RTRIM(MANSP)), ''),
    TRY_CONVERT(DATE, NULLIF(LTRIM(RTRIM(MADAT)), '00000000'), 112)
FROM bronze.sap_bsad WITH (NOLOCK)
WHERE MANDT = '400'
  AND AUGDT >= '20260101' AND AUGDT < @limite_str;

PRINT 'Rows inserted 2026 (partial, up to silver.load_silver''s bound): ' + CAST(@@ROWCOUNT AS VARCHAR);
GO

-- ========================================================================================
-- Final check: total in silver vs. what's in bronze before the daily incremental's
-- bound (should match exactly if every chunk ran correctly)
-- ========================================================================================
DECLARE @limite_final NVARCHAR(8) = CONVERT(NVARCHAR(8), DATEADD(MONTH, DATEDIFF(MONTH, 0, GETDATE()) - 1, 0), 112);

SELECT
    (SELECT COUNT(*) FROM bronze.sap_bsad WHERE MANDT = '400' AND AUGDT < @limite_final) AS filas_bronze_antes_del_limite,
    (SELECT COUNT(*) FROM silver.sap_bsad WHERE mandante = '400' AND fecha_compensacion < CONVERT(DATE, @limite_final, 112)) AS filas_silver_antes_del_limite;
GO
