/* ============================================================================
   Backfill silver.sap_bkpf
   Purpose : Loads every year of bronze.sap_bkpf into silver. The daily merge
             only keeps the window from the first day of the previous month.
   Run     : after bronze.backfill_bkpf, one block at a time. Each block is
             DELETE + INSERT for one year, so it is safe to re-run.
   Notes   : If a year fails with Msg 9002 (log full), split it in halves.
   ============================================================================ */
USE ANALISIS_DATOS;
GO

SET NOCOUNT ON;
GO

-- 2022
DECLARE @t DATETIME2(0) = SYSDATETIME(), @rows INT;
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
SET @rows = @@ROWCOUNT;
EXEC control.log_step 'backfill silver.sap_bkpf', '2022', @t, @rows;
GO

-- 2023
DECLARE @t DATETIME2(0) = SYSDATETIME(), @rows INT;
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
SET @rows = @@ROWCOUNT;
EXEC control.log_step 'backfill silver.sap_bkpf', '2023', @t, @rows;
GO

-- 2024
DECLARE @t DATETIME2(0) = SYSDATETIME(), @rows INT;
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
SET @rows = @@ROWCOUNT;
EXEC control.log_step 'backfill silver.sap_bkpf', '2024', @t, @rows;
GO

-- 2025
DECLARE @t DATETIME2(0) = SYSDATETIME(), @rows INT;
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
SET @rows = @@ROWCOUNT;
EXEC control.log_step 'backfill silver.sap_bkpf', '2025', @t, @rows;
GO

-- 2026
DECLARE @t DATETIME2(0) = SYSDATETIME(), @rows INT;
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
SET @rows = @@ROWCOUNT;
EXEC control.log_step 'backfill silver.sap_bkpf', '2026', @t, @rows;
GO

