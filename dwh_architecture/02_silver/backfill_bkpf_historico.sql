USE ANALISIS_DATOS;
GO

/*
========================================================================================
HISTORICAL BACKFILL: silver.sap_bkpf
========================================================================================
PURPOSE:
silver.load_silver's BKPF step only maintains a 2-month window (BUDAT >= first day of
the previous month), while bronze.sap_bkpf holds the full DZ history since 2022
(1,259,262 rows). This script fills in everything older than that window.

UPPER BOUND:
Each chunk is bounded by year, and the daily incremental owns everything from the first
day of the previous month onward. Running a chunk that overlaps the incremental's window
is harmless - the pattern is DELETE + INSERT per year, so it is idempotent - but there is
no reason to: run the closed years here and let the incremental keep the rest.

CHUNK PATTERN (same as backfill_bsad_historico.sql):
One chunk per year, DELETE + INSERT, safe to re-run. If a year breaks with:
    Msg 9002: The transaction log for database 'ANALISIS_DATOS' is full
split THAT year in half and run each half with a narrower fecha_contabilizacion /
BUDAT range. BKPF is ~1.26M rows against BSAD's 12.2M, so that is unlikely here - the
whole thing is roughly a tenth of the load that made the chunking necessary in the first
place.

ROWS PER YEAR (measured in bronze, BLART = 'DZ'):
    2022  240,063     2023  269,068     2024  276,810
    2025  279,210     2026  194,111 (partial, to 2026-09-11)
========================================================================================
*/

SET NOCOUNT ON;
GO

-- ============================== 2022 ==============================
PRINT '>> [2022] silver.sap_bkpf...';
DELETE FROM silver.sap_bkpf WHERE fecha_contabilizacion >= '20220101' AND fecha_contabilizacion < '20230101';

INSERT INTO silver.sap_bkpf (
    mandante, sociedad, ejercicio, documento_id, clase_documento,
    fecha_documento, fecha_contabilizacion, fecha_registro_sistema, mes,
    usuario, transaccion, referencia, texto_cabecera,
    documento_reversa, ejercicio_reversa, motivo_reversa, indicador_reversa, moneda
)
SELECT
    LTRIM(RTRIM(MANDT)), LTRIM(RTRIM(BUKRS)), GJAHR, LTRIM(RTRIM(BELNR)),
    NULLIF(LTRIM(RTRIM(BLART)), ''),
    TRY_CONVERT(DATE, NULLIF(LTRIM(RTRIM(BLDAT)), '00000000'), 112),
    TRY_CONVERT(DATE, NULLIF(LTRIM(RTRIM(BUDAT)), '00000000'), 112),
    TRY_CONVERT(DATE, NULLIF(LTRIM(RTRIM(CPUDT)), '00000000'), 112),
    NULLIF(LTRIM(RTRIM(MONAT)), ''),
    NULLIF(LTRIM(RTRIM(USNAM)), ''), NULLIF(LTRIM(RTRIM(TCODE)), ''),
    NULLIF(LTRIM(RTRIM(XBLNR)), ''), NULLIF(LTRIM(RTRIM(BKTXT)), ''),
    NULLIF(LTRIM(RTRIM(STBLG)), ''), TRY_CAST(NULLIF(LTRIM(RTRIM(STJAH)), '') AS INT),
    NULLIF(LTRIM(RTRIM(STGRD)), ''), NULLIF(LTRIM(RTRIM(XREVERSAL)), ''),
    NULLIF(LTRIM(RTRIM(WAERS)), '')
FROM bronze.sap_bkpf WITH (NOLOCK)
WHERE MANDT = '400' AND BUDAT >= '20220101' AND BUDAT < '20230101';
PRINT '   -> ' + CAST(@@ROWCOUNT AS NVARCHAR) + ' rows.';
GO

-- ============================== 2023 ==============================
PRINT '>> [2023] silver.sap_bkpf...';
DELETE FROM silver.sap_bkpf WHERE fecha_contabilizacion >= '20230101' AND fecha_contabilizacion < '20240101';

INSERT INTO silver.sap_bkpf (
    mandante, sociedad, ejercicio, documento_id, clase_documento,
    fecha_documento, fecha_contabilizacion, fecha_registro_sistema, mes,
    usuario, transaccion, referencia, texto_cabecera,
    documento_reversa, ejercicio_reversa, motivo_reversa, indicador_reversa, moneda
)
SELECT
    LTRIM(RTRIM(MANDT)), LTRIM(RTRIM(BUKRS)), GJAHR, LTRIM(RTRIM(BELNR)),
    NULLIF(LTRIM(RTRIM(BLART)), ''),
    TRY_CONVERT(DATE, NULLIF(LTRIM(RTRIM(BLDAT)), '00000000'), 112),
    TRY_CONVERT(DATE, NULLIF(LTRIM(RTRIM(BUDAT)), '00000000'), 112),
    TRY_CONVERT(DATE, NULLIF(LTRIM(RTRIM(CPUDT)), '00000000'), 112),
    NULLIF(LTRIM(RTRIM(MONAT)), ''),
    NULLIF(LTRIM(RTRIM(USNAM)), ''), NULLIF(LTRIM(RTRIM(TCODE)), ''),
    NULLIF(LTRIM(RTRIM(XBLNR)), ''), NULLIF(LTRIM(RTRIM(BKTXT)), ''),
    NULLIF(LTRIM(RTRIM(STBLG)), ''), TRY_CAST(NULLIF(LTRIM(RTRIM(STJAH)), '') AS INT),
    NULLIF(LTRIM(RTRIM(STGRD)), ''), NULLIF(LTRIM(RTRIM(XREVERSAL)), ''),
    NULLIF(LTRIM(RTRIM(WAERS)), '')
FROM bronze.sap_bkpf WITH (NOLOCK)
WHERE MANDT = '400' AND BUDAT >= '20230101' AND BUDAT < '20240101';
PRINT '   -> ' + CAST(@@ROWCOUNT AS NVARCHAR) + ' rows.';
GO

-- ============================== 2024 ==============================
PRINT '>> [2024] silver.sap_bkpf...';
DELETE FROM silver.sap_bkpf WHERE fecha_contabilizacion >= '20240101' AND fecha_contabilizacion < '20250101';

INSERT INTO silver.sap_bkpf (
    mandante, sociedad, ejercicio, documento_id, clase_documento,
    fecha_documento, fecha_contabilizacion, fecha_registro_sistema, mes,
    usuario, transaccion, referencia, texto_cabecera,
    documento_reversa, ejercicio_reversa, motivo_reversa, indicador_reversa, moneda
)
SELECT
    LTRIM(RTRIM(MANDT)), LTRIM(RTRIM(BUKRS)), GJAHR, LTRIM(RTRIM(BELNR)),
    NULLIF(LTRIM(RTRIM(BLART)), ''),
    TRY_CONVERT(DATE, NULLIF(LTRIM(RTRIM(BLDAT)), '00000000'), 112),
    TRY_CONVERT(DATE, NULLIF(LTRIM(RTRIM(BUDAT)), '00000000'), 112),
    TRY_CONVERT(DATE, NULLIF(LTRIM(RTRIM(CPUDT)), '00000000'), 112),
    NULLIF(LTRIM(RTRIM(MONAT)), ''),
    NULLIF(LTRIM(RTRIM(USNAM)), ''), NULLIF(LTRIM(RTRIM(TCODE)), ''),
    NULLIF(LTRIM(RTRIM(XBLNR)), ''), NULLIF(LTRIM(RTRIM(BKTXT)), ''),
    NULLIF(LTRIM(RTRIM(STBLG)), ''), TRY_CAST(NULLIF(LTRIM(RTRIM(STJAH)), '') AS INT),
    NULLIF(LTRIM(RTRIM(STGRD)), ''), NULLIF(LTRIM(RTRIM(XREVERSAL)), ''),
    NULLIF(LTRIM(RTRIM(WAERS)), '')
FROM bronze.sap_bkpf WITH (NOLOCK)
WHERE MANDT = '400' AND BUDAT >= '20240101' AND BUDAT < '20250101';
PRINT '   -> ' + CAST(@@ROWCOUNT AS NVARCHAR) + ' rows.';
GO

-- ============================== 2025 ==============================
PRINT '>> [2025] silver.sap_bkpf...';
DELETE FROM silver.sap_bkpf WHERE fecha_contabilizacion >= '20250101' AND fecha_contabilizacion < '20260101';

INSERT INTO silver.sap_bkpf (
    mandante, sociedad, ejercicio, documento_id, clase_documento,
    fecha_documento, fecha_contabilizacion, fecha_registro_sistema, mes,
    usuario, transaccion, referencia, texto_cabecera,
    documento_reversa, ejercicio_reversa, motivo_reversa, indicador_reversa, moneda
)
SELECT
    LTRIM(RTRIM(MANDT)), LTRIM(RTRIM(BUKRS)), GJAHR, LTRIM(RTRIM(BELNR)),
    NULLIF(LTRIM(RTRIM(BLART)), ''),
    TRY_CONVERT(DATE, NULLIF(LTRIM(RTRIM(BLDAT)), '00000000'), 112),
    TRY_CONVERT(DATE, NULLIF(LTRIM(RTRIM(BUDAT)), '00000000'), 112),
    TRY_CONVERT(DATE, NULLIF(LTRIM(RTRIM(CPUDT)), '00000000'), 112),
    NULLIF(LTRIM(RTRIM(MONAT)), ''),
    NULLIF(LTRIM(RTRIM(USNAM)), ''), NULLIF(LTRIM(RTRIM(TCODE)), ''),
    NULLIF(LTRIM(RTRIM(XBLNR)), ''), NULLIF(LTRIM(RTRIM(BKTXT)), ''),
    NULLIF(LTRIM(RTRIM(STBLG)), ''), TRY_CAST(NULLIF(LTRIM(RTRIM(STJAH)), '') AS INT),
    NULLIF(LTRIM(RTRIM(STGRD)), ''), NULLIF(LTRIM(RTRIM(XREVERSAL)), ''),
    NULLIF(LTRIM(RTRIM(WAERS)), '')
FROM bronze.sap_bkpf WITH (NOLOCK)
WHERE MANDT = '400' AND BUDAT >= '20250101' AND BUDAT < '20260101';
PRINT '   -> ' + CAST(@@ROWCOUNT AS NVARCHAR) + ' rows.';
GO

-- ============================== 2026 ==============================
-- Overlaps the incremental's window on purpose: DELETE+INSERT is idempotent and
-- this is the first load, so the window has nothing of its own yet.
PRINT '>> [2026] silver.sap_bkpf...';
DELETE FROM silver.sap_bkpf WHERE fecha_contabilizacion >= '20260101' AND fecha_contabilizacion < '20270101';

INSERT INTO silver.sap_bkpf (
    mandante, sociedad, ejercicio, documento_id, clase_documento,
    fecha_documento, fecha_contabilizacion, fecha_registro_sistema, mes,
    usuario, transaccion, referencia, texto_cabecera,
    documento_reversa, ejercicio_reversa, motivo_reversa, indicador_reversa, moneda
)
SELECT
    LTRIM(RTRIM(MANDT)), LTRIM(RTRIM(BUKRS)), GJAHR, LTRIM(RTRIM(BELNR)),
    NULLIF(LTRIM(RTRIM(BLART)), ''),
    TRY_CONVERT(DATE, NULLIF(LTRIM(RTRIM(BLDAT)), '00000000'), 112),
    TRY_CONVERT(DATE, NULLIF(LTRIM(RTRIM(BUDAT)), '00000000'), 112),
    TRY_CONVERT(DATE, NULLIF(LTRIM(RTRIM(CPUDT)), '00000000'), 112),
    NULLIF(LTRIM(RTRIM(MONAT)), ''),
    NULLIF(LTRIM(RTRIM(USNAM)), ''), NULLIF(LTRIM(RTRIM(TCODE)), ''),
    NULLIF(LTRIM(RTRIM(XBLNR)), ''), NULLIF(LTRIM(RTRIM(BKTXT)), ''),
    NULLIF(LTRIM(RTRIM(STBLG)), ''), TRY_CAST(NULLIF(LTRIM(RTRIM(STJAH)), '') AS INT),
    NULLIF(LTRIM(RTRIM(STGRD)), ''), NULLIF(LTRIM(RTRIM(XREVERSAL)), ''),
    NULLIF(LTRIM(RTRIM(WAERS)), '')
FROM bronze.sap_bkpf WITH (NOLOCK)
WHERE MANDT = '400' AND BUDAT >= '20260101' AND BUDAT < '20270101';
PRINT '   -> ' + CAST(@@ROWCOUNT AS NVARCHAR) + ' rows.';
GO

PRINT '>> BKPF historical backfill complete.';
GO
