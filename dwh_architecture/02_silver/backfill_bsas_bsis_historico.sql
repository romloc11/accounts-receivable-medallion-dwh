USE ANALISIS_DATOS;
GO

/*
========================================================================================
HISTORICAL BACKFILL: silver.sap_bsas / silver.sap_bsis
========================================================================================
PURPOSE:
silver.load_silver only maintains a window: AUGDT for sap_bsas, and BUDAT for the part of
sap_bsis whose accounts never clear. bronze holds everything since 2022. This fills silver
once. (The part of sap_bsis that CAN clear is reloaded whole every day by load_silver, so
it would not strictly need this - it is loaded here anyway so the table is complete from
the first run.)

ORDER:
Run AFTER bronze.sap_bsas / bronze.sap_bsis are loaded, and BEFORE the first
silver.load_silver - not because the incremental would break (DELETE + INSERT per year is
idempotent), but so the acceptance check at the end compares like with like.

CHUNK PATTERN (same as backfill_bkpf_historico.sql):
One chunk per BUDAT year, DELETE + INSERT, safe to re-run. If a year breaks with
    Msg 9002: The transaction log for database 'ANALISIS_DATOS' is full
split THAT year in half. Unlikely: the biggest chunk here (663K rows) is about a quarter
of the bsad chunks that already fit in the log.

ROWS PER YEAR (measured in bronze, 2026-09-14):
    sap_bsas  2022 372,579  2023 385,812  2024 432,971  2025 438,057  2026 305,181
    sap_bsis  2022 537,751  2023 600,108  2024 639,737  2025 663,492  2026 489,691

The column list and every transformation below are generated from the same definition as
ddl_silver.sql and sp_load_silver.sql - do not edit one without the others.
========================================================================================
*/

SET NOCOUNT ON;
GO

-- ============================== sap_bsas 2022 ==============================
PRINT '>> [2022] silver.sap_bsas...';
DELETE FROM silver.sap_bsas WHERE fecha_contabilizacion >= '20220101' AND fecha_contabilizacion < '20230101';

INSERT INTO silver.sap_bsas (
    mandante, sociedad, cuenta_mayor, ejercicio, documento_id, posicion, mes,
    clase_documento, fecha_contabilizacion, fecha_documento, fecha_valor, debe_haber,
    monto_moneda_local, monto_moneda_doc, moneda, asignacion, referencia, sgtxt,
    fecha_compensacion, documento_compensacion, ejercicio_compensacion,
    indicador_partidas_abiertas, indicador_compensacion_revertida
)
SELECT
    CAST(LTRIM(RTRIM(MANDT)) AS VARCHAR(3))                          AS mandante,
    CAST(LTRIM(RTRIM(BUKRS)) AS VARCHAR(4))                          AS sociedad,
    CAST(LTRIM(RTRIM(HKONT)) AS VARCHAR(10))                         AS cuenta_mayor,
    CAST(GJAHR AS INT)                                               AS ejercicio,
    CAST(LTRIM(RTRIM(BELNR)) AS VARCHAR(10))                         AS documento_id,
    CAST(BUZEI AS INT)                                               AS posicion,
    NULLIF(LTRIM(RTRIM(MONAT)), '')                                  AS mes,
    NULLIF(LTRIM(RTRIM(BLART)), '')                                  AS clase_documento,
    TRY_CONVERT(DATE, NULLIF(LTRIM(RTRIM(BUDAT)), '00000000'), 112)  AS fecha_contabilizacion,
    TRY_CONVERT(DATE, NULLIF(LTRIM(RTRIM(BLDAT)), '00000000'), 112)  AS fecha_documento,
    TRY_CONVERT(DATE, NULLIF(LTRIM(RTRIM(VALUT)), '00000000'), 112)  AS fecha_valor,
    NULLIF(LTRIM(RTRIM(SHKZG)), '')                                  AS debe_haber,
    ISNULL(DMBTR, 0)                                                 AS monto_moneda_local,
    ISNULL(WRBTR, 0)                                                 AS monto_moneda_doc,
    NULLIF(LTRIM(RTRIM(WAERS)), '')                                  AS moneda,
    NULLIF(LTRIM(RTRIM(ZUONR)), '')                                  AS asignacion,
    NULLIF(LTRIM(RTRIM(XBLNR)), '')                                  AS referencia,
    NULLIF(LTRIM(RTRIM(SGTXT)), '')                                  AS sgtxt,
    TRY_CONVERT(DATE, NULLIF(LTRIM(RTRIM(AUGDT)), '00000000'), 112)  AS fecha_compensacion,
    NULLIF(LTRIM(RTRIM(AUGBL)), '')                                  AS documento_compensacion,
    TRY_CAST(NULLIF(NULLIF(LTRIM(RTRIM(AUGGJ)), ''), '0000') AS INT) AS ejercicio_compensacion,
    NULLIF(LTRIM(RTRIM(XOPVW)), '')                                  AS indicador_partidas_abiertas,
    NULLIF(LTRIM(RTRIM(XRAGL)), '')                                  AS indicador_compensacion_revertida
FROM bronze.sap_bsas WITH (NOLOCK)
WHERE MANDT = '400' AND BUDAT >= '20220101' AND BUDAT < '20230101';
PRINT '   -> ' + CAST(@@ROWCOUNT AS NVARCHAR) + ' rows (bronze had 372,579).';
GO

-- ============================== sap_bsas 2023 ==============================
PRINT '>> [2023] silver.sap_bsas...';
DELETE FROM silver.sap_bsas WHERE fecha_contabilizacion >= '20230101' AND fecha_contabilizacion < '20240101';

INSERT INTO silver.sap_bsas (
    mandante, sociedad, cuenta_mayor, ejercicio, documento_id, posicion, mes,
    clase_documento, fecha_contabilizacion, fecha_documento, fecha_valor, debe_haber,
    monto_moneda_local, monto_moneda_doc, moneda, asignacion, referencia, sgtxt,
    fecha_compensacion, documento_compensacion, ejercicio_compensacion,
    indicador_partidas_abiertas, indicador_compensacion_revertida
)
SELECT
    CAST(LTRIM(RTRIM(MANDT)) AS VARCHAR(3))                          AS mandante,
    CAST(LTRIM(RTRIM(BUKRS)) AS VARCHAR(4))                          AS sociedad,
    CAST(LTRIM(RTRIM(HKONT)) AS VARCHAR(10))                         AS cuenta_mayor,
    CAST(GJAHR AS INT)                                               AS ejercicio,
    CAST(LTRIM(RTRIM(BELNR)) AS VARCHAR(10))                         AS documento_id,
    CAST(BUZEI AS INT)                                               AS posicion,
    NULLIF(LTRIM(RTRIM(MONAT)), '')                                  AS mes,
    NULLIF(LTRIM(RTRIM(BLART)), '')                                  AS clase_documento,
    TRY_CONVERT(DATE, NULLIF(LTRIM(RTRIM(BUDAT)), '00000000'), 112)  AS fecha_contabilizacion,
    TRY_CONVERT(DATE, NULLIF(LTRIM(RTRIM(BLDAT)), '00000000'), 112)  AS fecha_documento,
    TRY_CONVERT(DATE, NULLIF(LTRIM(RTRIM(VALUT)), '00000000'), 112)  AS fecha_valor,
    NULLIF(LTRIM(RTRIM(SHKZG)), '')                                  AS debe_haber,
    ISNULL(DMBTR, 0)                                                 AS monto_moneda_local,
    ISNULL(WRBTR, 0)                                                 AS monto_moneda_doc,
    NULLIF(LTRIM(RTRIM(WAERS)), '')                                  AS moneda,
    NULLIF(LTRIM(RTRIM(ZUONR)), '')                                  AS asignacion,
    NULLIF(LTRIM(RTRIM(XBLNR)), '')                                  AS referencia,
    NULLIF(LTRIM(RTRIM(SGTXT)), '')                                  AS sgtxt,
    TRY_CONVERT(DATE, NULLIF(LTRIM(RTRIM(AUGDT)), '00000000'), 112)  AS fecha_compensacion,
    NULLIF(LTRIM(RTRIM(AUGBL)), '')                                  AS documento_compensacion,
    TRY_CAST(NULLIF(NULLIF(LTRIM(RTRIM(AUGGJ)), ''), '0000') AS INT) AS ejercicio_compensacion,
    NULLIF(LTRIM(RTRIM(XOPVW)), '')                                  AS indicador_partidas_abiertas,
    NULLIF(LTRIM(RTRIM(XRAGL)), '')                                  AS indicador_compensacion_revertida
FROM bronze.sap_bsas WITH (NOLOCK)
WHERE MANDT = '400' AND BUDAT >= '20230101' AND BUDAT < '20240101';
PRINT '   -> ' + CAST(@@ROWCOUNT AS NVARCHAR) + ' rows (bronze had 385,812).';
GO

-- ============================== sap_bsas 2024 ==============================
PRINT '>> [2024] silver.sap_bsas...';
DELETE FROM silver.sap_bsas WHERE fecha_contabilizacion >= '20240101' AND fecha_contabilizacion < '20250101';

INSERT INTO silver.sap_bsas (
    mandante, sociedad, cuenta_mayor, ejercicio, documento_id, posicion, mes,
    clase_documento, fecha_contabilizacion, fecha_documento, fecha_valor, debe_haber,
    monto_moneda_local, monto_moneda_doc, moneda, asignacion, referencia, sgtxt,
    fecha_compensacion, documento_compensacion, ejercicio_compensacion,
    indicador_partidas_abiertas, indicador_compensacion_revertida
)
SELECT
    CAST(LTRIM(RTRIM(MANDT)) AS VARCHAR(3))                          AS mandante,
    CAST(LTRIM(RTRIM(BUKRS)) AS VARCHAR(4))                          AS sociedad,
    CAST(LTRIM(RTRIM(HKONT)) AS VARCHAR(10))                         AS cuenta_mayor,
    CAST(GJAHR AS INT)                                               AS ejercicio,
    CAST(LTRIM(RTRIM(BELNR)) AS VARCHAR(10))                         AS documento_id,
    CAST(BUZEI AS INT)                                               AS posicion,
    NULLIF(LTRIM(RTRIM(MONAT)), '')                                  AS mes,
    NULLIF(LTRIM(RTRIM(BLART)), '')                                  AS clase_documento,
    TRY_CONVERT(DATE, NULLIF(LTRIM(RTRIM(BUDAT)), '00000000'), 112)  AS fecha_contabilizacion,
    TRY_CONVERT(DATE, NULLIF(LTRIM(RTRIM(BLDAT)), '00000000'), 112)  AS fecha_documento,
    TRY_CONVERT(DATE, NULLIF(LTRIM(RTRIM(VALUT)), '00000000'), 112)  AS fecha_valor,
    NULLIF(LTRIM(RTRIM(SHKZG)), '')                                  AS debe_haber,
    ISNULL(DMBTR, 0)                                                 AS monto_moneda_local,
    ISNULL(WRBTR, 0)                                                 AS monto_moneda_doc,
    NULLIF(LTRIM(RTRIM(WAERS)), '')                                  AS moneda,
    NULLIF(LTRIM(RTRIM(ZUONR)), '')                                  AS asignacion,
    NULLIF(LTRIM(RTRIM(XBLNR)), '')                                  AS referencia,
    NULLIF(LTRIM(RTRIM(SGTXT)), '')                                  AS sgtxt,
    TRY_CONVERT(DATE, NULLIF(LTRIM(RTRIM(AUGDT)), '00000000'), 112)  AS fecha_compensacion,
    NULLIF(LTRIM(RTRIM(AUGBL)), '')                                  AS documento_compensacion,
    TRY_CAST(NULLIF(NULLIF(LTRIM(RTRIM(AUGGJ)), ''), '0000') AS INT) AS ejercicio_compensacion,
    NULLIF(LTRIM(RTRIM(XOPVW)), '')                                  AS indicador_partidas_abiertas,
    NULLIF(LTRIM(RTRIM(XRAGL)), '')                                  AS indicador_compensacion_revertida
FROM bronze.sap_bsas WITH (NOLOCK)
WHERE MANDT = '400' AND BUDAT >= '20240101' AND BUDAT < '20250101';
PRINT '   -> ' + CAST(@@ROWCOUNT AS NVARCHAR) + ' rows (bronze had 432,971).';
GO

-- ============================== sap_bsas 2025 ==============================
PRINT '>> [2025] silver.sap_bsas...';
DELETE FROM silver.sap_bsas WHERE fecha_contabilizacion >= '20250101' AND fecha_contabilizacion < '20260101';

INSERT INTO silver.sap_bsas (
    mandante, sociedad, cuenta_mayor, ejercicio, documento_id, posicion, mes,
    clase_documento, fecha_contabilizacion, fecha_documento, fecha_valor, debe_haber,
    monto_moneda_local, monto_moneda_doc, moneda, asignacion, referencia, sgtxt,
    fecha_compensacion, documento_compensacion, ejercicio_compensacion,
    indicador_partidas_abiertas, indicador_compensacion_revertida
)
SELECT
    CAST(LTRIM(RTRIM(MANDT)) AS VARCHAR(3))                          AS mandante,
    CAST(LTRIM(RTRIM(BUKRS)) AS VARCHAR(4))                          AS sociedad,
    CAST(LTRIM(RTRIM(HKONT)) AS VARCHAR(10))                         AS cuenta_mayor,
    CAST(GJAHR AS INT)                                               AS ejercicio,
    CAST(LTRIM(RTRIM(BELNR)) AS VARCHAR(10))                         AS documento_id,
    CAST(BUZEI AS INT)                                               AS posicion,
    NULLIF(LTRIM(RTRIM(MONAT)), '')                                  AS mes,
    NULLIF(LTRIM(RTRIM(BLART)), '')                                  AS clase_documento,
    TRY_CONVERT(DATE, NULLIF(LTRIM(RTRIM(BUDAT)), '00000000'), 112)  AS fecha_contabilizacion,
    TRY_CONVERT(DATE, NULLIF(LTRIM(RTRIM(BLDAT)), '00000000'), 112)  AS fecha_documento,
    TRY_CONVERT(DATE, NULLIF(LTRIM(RTRIM(VALUT)), '00000000'), 112)  AS fecha_valor,
    NULLIF(LTRIM(RTRIM(SHKZG)), '')                                  AS debe_haber,
    ISNULL(DMBTR, 0)                                                 AS monto_moneda_local,
    ISNULL(WRBTR, 0)                                                 AS monto_moneda_doc,
    NULLIF(LTRIM(RTRIM(WAERS)), '')                                  AS moneda,
    NULLIF(LTRIM(RTRIM(ZUONR)), '')                                  AS asignacion,
    NULLIF(LTRIM(RTRIM(XBLNR)), '')                                  AS referencia,
    NULLIF(LTRIM(RTRIM(SGTXT)), '')                                  AS sgtxt,
    TRY_CONVERT(DATE, NULLIF(LTRIM(RTRIM(AUGDT)), '00000000'), 112)  AS fecha_compensacion,
    NULLIF(LTRIM(RTRIM(AUGBL)), '')                                  AS documento_compensacion,
    TRY_CAST(NULLIF(NULLIF(LTRIM(RTRIM(AUGGJ)), ''), '0000') AS INT) AS ejercicio_compensacion,
    NULLIF(LTRIM(RTRIM(XOPVW)), '')                                  AS indicador_partidas_abiertas,
    NULLIF(LTRIM(RTRIM(XRAGL)), '')                                  AS indicador_compensacion_revertida
FROM bronze.sap_bsas WITH (NOLOCK)
WHERE MANDT = '400' AND BUDAT >= '20250101' AND BUDAT < '20260101';
PRINT '   -> ' + CAST(@@ROWCOUNT AS NVARCHAR) + ' rows (bronze had 438,057).';
GO

-- ============================== sap_bsas 2026 ==============================
PRINT '>> [2026] silver.sap_bsas...';
DELETE FROM silver.sap_bsas WHERE fecha_contabilizacion >= '20260101' AND fecha_contabilizacion < '20270101';

INSERT INTO silver.sap_bsas (
    mandante, sociedad, cuenta_mayor, ejercicio, documento_id, posicion, mes,
    clase_documento, fecha_contabilizacion, fecha_documento, fecha_valor, debe_haber,
    monto_moneda_local, monto_moneda_doc, moneda, asignacion, referencia, sgtxt,
    fecha_compensacion, documento_compensacion, ejercicio_compensacion,
    indicador_partidas_abiertas, indicador_compensacion_revertida
)
SELECT
    CAST(LTRIM(RTRIM(MANDT)) AS VARCHAR(3))                          AS mandante,
    CAST(LTRIM(RTRIM(BUKRS)) AS VARCHAR(4))                          AS sociedad,
    CAST(LTRIM(RTRIM(HKONT)) AS VARCHAR(10))                         AS cuenta_mayor,
    CAST(GJAHR AS INT)                                               AS ejercicio,
    CAST(LTRIM(RTRIM(BELNR)) AS VARCHAR(10))                         AS documento_id,
    CAST(BUZEI AS INT)                                               AS posicion,
    NULLIF(LTRIM(RTRIM(MONAT)), '')                                  AS mes,
    NULLIF(LTRIM(RTRIM(BLART)), '')                                  AS clase_documento,
    TRY_CONVERT(DATE, NULLIF(LTRIM(RTRIM(BUDAT)), '00000000'), 112)  AS fecha_contabilizacion,
    TRY_CONVERT(DATE, NULLIF(LTRIM(RTRIM(BLDAT)), '00000000'), 112)  AS fecha_documento,
    TRY_CONVERT(DATE, NULLIF(LTRIM(RTRIM(VALUT)), '00000000'), 112)  AS fecha_valor,
    NULLIF(LTRIM(RTRIM(SHKZG)), '')                                  AS debe_haber,
    ISNULL(DMBTR, 0)                                                 AS monto_moneda_local,
    ISNULL(WRBTR, 0)                                                 AS monto_moneda_doc,
    NULLIF(LTRIM(RTRIM(WAERS)), '')                                  AS moneda,
    NULLIF(LTRIM(RTRIM(ZUONR)), '')                                  AS asignacion,
    NULLIF(LTRIM(RTRIM(XBLNR)), '')                                  AS referencia,
    NULLIF(LTRIM(RTRIM(SGTXT)), '')                                  AS sgtxt,
    TRY_CONVERT(DATE, NULLIF(LTRIM(RTRIM(AUGDT)), '00000000'), 112)  AS fecha_compensacion,
    NULLIF(LTRIM(RTRIM(AUGBL)), '')                                  AS documento_compensacion,
    TRY_CAST(NULLIF(NULLIF(LTRIM(RTRIM(AUGGJ)), ''), '0000') AS INT) AS ejercicio_compensacion,
    NULLIF(LTRIM(RTRIM(XOPVW)), '')                                  AS indicador_partidas_abiertas,
    NULLIF(LTRIM(RTRIM(XRAGL)), '')                                  AS indicador_compensacion_revertida
FROM bronze.sap_bsas WITH (NOLOCK)
WHERE MANDT = '400' AND BUDAT >= '20260101' AND BUDAT < '20270101';
PRINT '   -> ' + CAST(@@ROWCOUNT AS NVARCHAR) + ' rows (bronze had 305,181).';
GO

-- ============================== sap_bsis 2022 ==============================
PRINT '>> [2022] silver.sap_bsis...';
DELETE FROM silver.sap_bsis WHERE fecha_contabilizacion >= '20220101' AND fecha_contabilizacion < '20230101';

INSERT INTO silver.sap_bsis (
    mandante, sociedad, cuenta_mayor, ejercicio, documento_id, posicion, mes,
    clase_documento, fecha_contabilizacion, fecha_documento, fecha_valor, debe_haber,
    monto_moneda_local, monto_moneda_doc, moneda, asignacion, referencia, sgtxt,
    fecha_compensacion, documento_compensacion, ejercicio_compensacion,
    indicador_partidas_abiertas, indicador_compensacion_revertida
)
SELECT
    CAST(LTRIM(RTRIM(MANDT)) AS VARCHAR(3))                          AS mandante,
    CAST(LTRIM(RTRIM(BUKRS)) AS VARCHAR(4))                          AS sociedad,
    CAST(LTRIM(RTRIM(HKONT)) AS VARCHAR(10))                         AS cuenta_mayor,
    CAST(GJAHR AS INT)                                               AS ejercicio,
    CAST(LTRIM(RTRIM(BELNR)) AS VARCHAR(10))                         AS documento_id,
    CAST(BUZEI AS INT)                                               AS posicion,
    NULLIF(LTRIM(RTRIM(MONAT)), '')                                  AS mes,
    NULLIF(LTRIM(RTRIM(BLART)), '')                                  AS clase_documento,
    TRY_CONVERT(DATE, NULLIF(LTRIM(RTRIM(BUDAT)), '00000000'), 112)  AS fecha_contabilizacion,
    TRY_CONVERT(DATE, NULLIF(LTRIM(RTRIM(BLDAT)), '00000000'), 112)  AS fecha_documento,
    TRY_CONVERT(DATE, NULLIF(LTRIM(RTRIM(VALUT)), '00000000'), 112)  AS fecha_valor,
    NULLIF(LTRIM(RTRIM(SHKZG)), '')                                  AS debe_haber,
    ISNULL(DMBTR, 0)                                                 AS monto_moneda_local,
    ISNULL(WRBTR, 0)                                                 AS monto_moneda_doc,
    NULLIF(LTRIM(RTRIM(WAERS)), '')                                  AS moneda,
    NULLIF(LTRIM(RTRIM(ZUONR)), '')                                  AS asignacion,
    NULLIF(LTRIM(RTRIM(XBLNR)), '')                                  AS referencia,
    NULLIF(LTRIM(RTRIM(SGTXT)), '')                                  AS sgtxt,
    TRY_CONVERT(DATE, NULLIF(LTRIM(RTRIM(AUGDT)), '00000000'), 112)  AS fecha_compensacion,
    NULLIF(LTRIM(RTRIM(AUGBL)), '')                                  AS documento_compensacion,
    TRY_CAST(NULLIF(NULLIF(LTRIM(RTRIM(AUGGJ)), ''), '0000') AS INT) AS ejercicio_compensacion,
    NULLIF(LTRIM(RTRIM(XOPVW)), '')                                  AS indicador_partidas_abiertas,
    NULLIF(LTRIM(RTRIM(XRAGL)), '')                                  AS indicador_compensacion_revertida
FROM bronze.sap_bsis WITH (NOLOCK)
WHERE MANDT = '400' AND BUDAT >= '20220101' AND BUDAT < '20230101';
PRINT '   -> ' + CAST(@@ROWCOUNT AS NVARCHAR) + ' rows (bronze had 537,751).';
GO

-- ============================== sap_bsis 2023 ==============================
PRINT '>> [2023] silver.sap_bsis...';
DELETE FROM silver.sap_bsis WHERE fecha_contabilizacion >= '20230101' AND fecha_contabilizacion < '20240101';

INSERT INTO silver.sap_bsis (
    mandante, sociedad, cuenta_mayor, ejercicio, documento_id, posicion, mes,
    clase_documento, fecha_contabilizacion, fecha_documento, fecha_valor, debe_haber,
    monto_moneda_local, monto_moneda_doc, moneda, asignacion, referencia, sgtxt,
    fecha_compensacion, documento_compensacion, ejercicio_compensacion,
    indicador_partidas_abiertas, indicador_compensacion_revertida
)
SELECT
    CAST(LTRIM(RTRIM(MANDT)) AS VARCHAR(3))                          AS mandante,
    CAST(LTRIM(RTRIM(BUKRS)) AS VARCHAR(4))                          AS sociedad,
    CAST(LTRIM(RTRIM(HKONT)) AS VARCHAR(10))                         AS cuenta_mayor,
    CAST(GJAHR AS INT)                                               AS ejercicio,
    CAST(LTRIM(RTRIM(BELNR)) AS VARCHAR(10))                         AS documento_id,
    CAST(BUZEI AS INT)                                               AS posicion,
    NULLIF(LTRIM(RTRIM(MONAT)), '')                                  AS mes,
    NULLIF(LTRIM(RTRIM(BLART)), '')                                  AS clase_documento,
    TRY_CONVERT(DATE, NULLIF(LTRIM(RTRIM(BUDAT)), '00000000'), 112)  AS fecha_contabilizacion,
    TRY_CONVERT(DATE, NULLIF(LTRIM(RTRIM(BLDAT)), '00000000'), 112)  AS fecha_documento,
    TRY_CONVERT(DATE, NULLIF(LTRIM(RTRIM(VALUT)), '00000000'), 112)  AS fecha_valor,
    NULLIF(LTRIM(RTRIM(SHKZG)), '')                                  AS debe_haber,
    ISNULL(DMBTR, 0)                                                 AS monto_moneda_local,
    ISNULL(WRBTR, 0)                                                 AS monto_moneda_doc,
    NULLIF(LTRIM(RTRIM(WAERS)), '')                                  AS moneda,
    NULLIF(LTRIM(RTRIM(ZUONR)), '')                                  AS asignacion,
    NULLIF(LTRIM(RTRIM(XBLNR)), '')                                  AS referencia,
    NULLIF(LTRIM(RTRIM(SGTXT)), '')                                  AS sgtxt,
    TRY_CONVERT(DATE, NULLIF(LTRIM(RTRIM(AUGDT)), '00000000'), 112)  AS fecha_compensacion,
    NULLIF(LTRIM(RTRIM(AUGBL)), '')                                  AS documento_compensacion,
    TRY_CAST(NULLIF(NULLIF(LTRIM(RTRIM(AUGGJ)), ''), '0000') AS INT) AS ejercicio_compensacion,
    NULLIF(LTRIM(RTRIM(XOPVW)), '')                                  AS indicador_partidas_abiertas,
    NULLIF(LTRIM(RTRIM(XRAGL)), '')                                  AS indicador_compensacion_revertida
FROM bronze.sap_bsis WITH (NOLOCK)
WHERE MANDT = '400' AND BUDAT >= '20230101' AND BUDAT < '20240101';
PRINT '   -> ' + CAST(@@ROWCOUNT AS NVARCHAR) + ' rows (bronze had 600,108).';
GO

-- ============================== sap_bsis 2024 ==============================
PRINT '>> [2024] silver.sap_bsis...';
DELETE FROM silver.sap_bsis WHERE fecha_contabilizacion >= '20240101' AND fecha_contabilizacion < '20250101';

INSERT INTO silver.sap_bsis (
    mandante, sociedad, cuenta_mayor, ejercicio, documento_id, posicion, mes,
    clase_documento, fecha_contabilizacion, fecha_documento, fecha_valor, debe_haber,
    monto_moneda_local, monto_moneda_doc, moneda, asignacion, referencia, sgtxt,
    fecha_compensacion, documento_compensacion, ejercicio_compensacion,
    indicador_partidas_abiertas, indicador_compensacion_revertida
)
SELECT
    CAST(LTRIM(RTRIM(MANDT)) AS VARCHAR(3))                          AS mandante,
    CAST(LTRIM(RTRIM(BUKRS)) AS VARCHAR(4))                          AS sociedad,
    CAST(LTRIM(RTRIM(HKONT)) AS VARCHAR(10))                         AS cuenta_mayor,
    CAST(GJAHR AS INT)                                               AS ejercicio,
    CAST(LTRIM(RTRIM(BELNR)) AS VARCHAR(10))                         AS documento_id,
    CAST(BUZEI AS INT)                                               AS posicion,
    NULLIF(LTRIM(RTRIM(MONAT)), '')                                  AS mes,
    NULLIF(LTRIM(RTRIM(BLART)), '')                                  AS clase_documento,
    TRY_CONVERT(DATE, NULLIF(LTRIM(RTRIM(BUDAT)), '00000000'), 112)  AS fecha_contabilizacion,
    TRY_CONVERT(DATE, NULLIF(LTRIM(RTRIM(BLDAT)), '00000000'), 112)  AS fecha_documento,
    TRY_CONVERT(DATE, NULLIF(LTRIM(RTRIM(VALUT)), '00000000'), 112)  AS fecha_valor,
    NULLIF(LTRIM(RTRIM(SHKZG)), '')                                  AS debe_haber,
    ISNULL(DMBTR, 0)                                                 AS monto_moneda_local,
    ISNULL(WRBTR, 0)                                                 AS monto_moneda_doc,
    NULLIF(LTRIM(RTRIM(WAERS)), '')                                  AS moneda,
    NULLIF(LTRIM(RTRIM(ZUONR)), '')                                  AS asignacion,
    NULLIF(LTRIM(RTRIM(XBLNR)), '')                                  AS referencia,
    NULLIF(LTRIM(RTRIM(SGTXT)), '')                                  AS sgtxt,
    TRY_CONVERT(DATE, NULLIF(LTRIM(RTRIM(AUGDT)), '00000000'), 112)  AS fecha_compensacion,
    NULLIF(LTRIM(RTRIM(AUGBL)), '')                                  AS documento_compensacion,
    TRY_CAST(NULLIF(NULLIF(LTRIM(RTRIM(AUGGJ)), ''), '0000') AS INT) AS ejercicio_compensacion,
    NULLIF(LTRIM(RTRIM(XOPVW)), '')                                  AS indicador_partidas_abiertas,
    NULLIF(LTRIM(RTRIM(XRAGL)), '')                                  AS indicador_compensacion_revertida
FROM bronze.sap_bsis WITH (NOLOCK)
WHERE MANDT = '400' AND BUDAT >= '20240101' AND BUDAT < '20250101';
PRINT '   -> ' + CAST(@@ROWCOUNT AS NVARCHAR) + ' rows (bronze had 639,737).';
GO

-- ============================== sap_bsis 2025 ==============================
PRINT '>> [2025] silver.sap_bsis...';
DELETE FROM silver.sap_bsis WHERE fecha_contabilizacion >= '20250101' AND fecha_contabilizacion < '20260101';

INSERT INTO silver.sap_bsis (
    mandante, sociedad, cuenta_mayor, ejercicio, documento_id, posicion, mes,
    clase_documento, fecha_contabilizacion, fecha_documento, fecha_valor, debe_haber,
    monto_moneda_local, monto_moneda_doc, moneda, asignacion, referencia, sgtxt,
    fecha_compensacion, documento_compensacion, ejercicio_compensacion,
    indicador_partidas_abiertas, indicador_compensacion_revertida
)
SELECT
    CAST(LTRIM(RTRIM(MANDT)) AS VARCHAR(3))                          AS mandante,
    CAST(LTRIM(RTRIM(BUKRS)) AS VARCHAR(4))                          AS sociedad,
    CAST(LTRIM(RTRIM(HKONT)) AS VARCHAR(10))                         AS cuenta_mayor,
    CAST(GJAHR AS INT)                                               AS ejercicio,
    CAST(LTRIM(RTRIM(BELNR)) AS VARCHAR(10))                         AS documento_id,
    CAST(BUZEI AS INT)                                               AS posicion,
    NULLIF(LTRIM(RTRIM(MONAT)), '')                                  AS mes,
    NULLIF(LTRIM(RTRIM(BLART)), '')                                  AS clase_documento,
    TRY_CONVERT(DATE, NULLIF(LTRIM(RTRIM(BUDAT)), '00000000'), 112)  AS fecha_contabilizacion,
    TRY_CONVERT(DATE, NULLIF(LTRIM(RTRIM(BLDAT)), '00000000'), 112)  AS fecha_documento,
    TRY_CONVERT(DATE, NULLIF(LTRIM(RTRIM(VALUT)), '00000000'), 112)  AS fecha_valor,
    NULLIF(LTRIM(RTRIM(SHKZG)), '')                                  AS debe_haber,
    ISNULL(DMBTR, 0)                                                 AS monto_moneda_local,
    ISNULL(WRBTR, 0)                                                 AS monto_moneda_doc,
    NULLIF(LTRIM(RTRIM(WAERS)), '')                                  AS moneda,
    NULLIF(LTRIM(RTRIM(ZUONR)), '')                                  AS asignacion,
    NULLIF(LTRIM(RTRIM(XBLNR)), '')                                  AS referencia,
    NULLIF(LTRIM(RTRIM(SGTXT)), '')                                  AS sgtxt,
    TRY_CONVERT(DATE, NULLIF(LTRIM(RTRIM(AUGDT)), '00000000'), 112)  AS fecha_compensacion,
    NULLIF(LTRIM(RTRIM(AUGBL)), '')                                  AS documento_compensacion,
    TRY_CAST(NULLIF(NULLIF(LTRIM(RTRIM(AUGGJ)), ''), '0000') AS INT) AS ejercicio_compensacion,
    NULLIF(LTRIM(RTRIM(XOPVW)), '')                                  AS indicador_partidas_abiertas,
    NULLIF(LTRIM(RTRIM(XRAGL)), '')                                  AS indicador_compensacion_revertida
FROM bronze.sap_bsis WITH (NOLOCK)
WHERE MANDT = '400' AND BUDAT >= '20250101' AND BUDAT < '20260101';
PRINT '   -> ' + CAST(@@ROWCOUNT AS NVARCHAR) + ' rows (bronze had 663,492).';
GO

-- ============================== sap_bsis 2026 ==============================
PRINT '>> [2026] silver.sap_bsis...';
DELETE FROM silver.sap_bsis WHERE fecha_contabilizacion >= '20260101' AND fecha_contabilizacion < '20270101';

INSERT INTO silver.sap_bsis (
    mandante, sociedad, cuenta_mayor, ejercicio, documento_id, posicion, mes,
    clase_documento, fecha_contabilizacion, fecha_documento, fecha_valor, debe_haber,
    monto_moneda_local, monto_moneda_doc, moneda, asignacion, referencia, sgtxt,
    fecha_compensacion, documento_compensacion, ejercicio_compensacion,
    indicador_partidas_abiertas, indicador_compensacion_revertida
)
SELECT
    CAST(LTRIM(RTRIM(MANDT)) AS VARCHAR(3))                          AS mandante,
    CAST(LTRIM(RTRIM(BUKRS)) AS VARCHAR(4))                          AS sociedad,
    CAST(LTRIM(RTRIM(HKONT)) AS VARCHAR(10))                         AS cuenta_mayor,
    CAST(GJAHR AS INT)                                               AS ejercicio,
    CAST(LTRIM(RTRIM(BELNR)) AS VARCHAR(10))                         AS documento_id,
    CAST(BUZEI AS INT)                                               AS posicion,
    NULLIF(LTRIM(RTRIM(MONAT)), '')                                  AS mes,
    NULLIF(LTRIM(RTRIM(BLART)), '')                                  AS clase_documento,
    TRY_CONVERT(DATE, NULLIF(LTRIM(RTRIM(BUDAT)), '00000000'), 112)  AS fecha_contabilizacion,
    TRY_CONVERT(DATE, NULLIF(LTRIM(RTRIM(BLDAT)), '00000000'), 112)  AS fecha_documento,
    TRY_CONVERT(DATE, NULLIF(LTRIM(RTRIM(VALUT)), '00000000'), 112)  AS fecha_valor,
    NULLIF(LTRIM(RTRIM(SHKZG)), '')                                  AS debe_haber,
    ISNULL(DMBTR, 0)                                                 AS monto_moneda_local,
    ISNULL(WRBTR, 0)                                                 AS monto_moneda_doc,
    NULLIF(LTRIM(RTRIM(WAERS)), '')                                  AS moneda,
    NULLIF(LTRIM(RTRIM(ZUONR)), '')                                  AS asignacion,
    NULLIF(LTRIM(RTRIM(XBLNR)), '')                                  AS referencia,
    NULLIF(LTRIM(RTRIM(SGTXT)), '')                                  AS sgtxt,
    TRY_CONVERT(DATE, NULLIF(LTRIM(RTRIM(AUGDT)), '00000000'), 112)  AS fecha_compensacion,
    NULLIF(LTRIM(RTRIM(AUGBL)), '')                                  AS documento_compensacion,
    TRY_CAST(NULLIF(NULLIF(LTRIM(RTRIM(AUGGJ)), ''), '0000') AS INT) AS ejercicio_compensacion,
    NULLIF(LTRIM(RTRIM(XOPVW)), '')                                  AS indicador_partidas_abiertas,
    NULLIF(LTRIM(RTRIM(XRAGL)), '')                                  AS indicador_compensacion_revertida
FROM bronze.sap_bsis WITH (NOLOCK)
WHERE MANDT = '400' AND BUDAT >= '20260101' AND BUDAT < '20270101';
PRINT '   -> ' + CAST(@@ROWCOUNT AS NVARCHAR) + ' rows (bronze had 489,691).';
GO

-- ==================================================================================
-- ACCEPTANCE CHECK. Silver must equal bronze, row for row and peso for peso, every
-- year. Any difference in filas or in neto is a transformation losing or changing data.
-- ==================================================================================
SELECT b.tabla, b.anio,
       b.filas AS filas_bronze, s.filas AS filas_silver,
       b.neto  AS neto_bronze,  s.neto  AS neto_silver,
       CASE WHEN b.filas = s.filas AND b.neto = s.neto THEN 'OK' ELSE '<<< DIFIERE' END AS resultado
FROM (
    SELECT 'sap_bsas' AS tabla, CAST(LEFT(BUDAT, 4) AS VARCHAR(4)) AS anio, COUNT(*) AS filas,
           SUM(CASE WHEN SHKZG = 'S' THEN DMBTR ELSE -DMBTR END) AS neto
    FROM bronze.sap_bsas WHERE MANDT = '400' GROUP BY LEFT(BUDAT, 4)
    UNION ALL
    SELECT 'sap_bsis', CAST(LEFT(BUDAT, 4) AS VARCHAR(4)), COUNT(*),
           SUM(CASE WHEN SHKZG = 'S' THEN DMBTR ELSE -DMBTR END)
    FROM bronze.sap_bsis WHERE MANDT = '400' GROUP BY LEFT(BUDAT, 4)
) b
LEFT JOIN (
    SELECT 'sap_bsas' AS tabla, CAST(YEAR(fecha_contabilizacion) AS VARCHAR(4)) AS anio, COUNT(*) AS filas,
           SUM(CASE WHEN debe_haber = 'S' THEN monto_moneda_local ELSE -monto_moneda_local END) AS neto
    FROM silver.sap_bsas GROUP BY YEAR(fecha_contabilizacion)
    UNION ALL
    SELECT 'sap_bsis', CAST(YEAR(fecha_contabilizacion) AS VARCHAR(4)), COUNT(*),
           SUM(CASE WHEN debe_haber = 'S' THEN monto_moneda_local ELSE -monto_moneda_local END)
    FROM silver.sap_bsis GROUP BY YEAR(fecha_contabilizacion)
) s ON s.tabla = b.tabla AND s.anio = b.anio
ORDER BY b.tabla, b.anio;

-- And no line open and cleared at the same time (must be 0):
SELECT COUNT(*) AS lineas_en_ambas
FROM silver.sap_bsas a
JOIN silver.sap_bsis i
  ON  i.mandante = a.mandante AND i.sociedad = a.sociedad AND i.cuenta_mayor = a.cuenta_mayor
  AND i.ejercicio = a.ejercicio AND i.documento_id = a.documento_id AND i.posicion = a.posicion;
GO
