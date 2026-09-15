/* ============================================================================
   Backfill silver.sap_bsas / silver.sap_bsis
   Purpose : Loads every year of bronze.sap_bsas and bronze.sap_bsis into silver.
             The daily load only keeps its window.
   Run     : after the bronze backfills and before the first silver.load_silver,
             one block at a time. Each block is DELETE + INSERT for one posting
             year: safe to re-run. Then run the two checks at the end.
   Notes   : The column list and transformations must match ddl_silver.sql and
             sp_load_silver.sql.
   ============================================================================ */
USE ANALISIS_DATOS;
GO

SET NOCOUNT ON;
GO

-- sap_bsas 2022
DECLARE @t DATETIME2(0) = SYSDATETIME(), @rows INT;
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
SET @rows = @@ROWCOUNT;
EXEC control.log_step 'backfill silver.sap_bsas', '2022', @t, @rows;
GO

-- sap_bsas 2023
DECLARE @t DATETIME2(0) = SYSDATETIME(), @rows INT;
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
SET @rows = @@ROWCOUNT;
EXEC control.log_step 'backfill silver.sap_bsas', '2023', @t, @rows;
GO

-- sap_bsas 2024
DECLARE @t DATETIME2(0) = SYSDATETIME(), @rows INT;
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
SET @rows = @@ROWCOUNT;
EXEC control.log_step 'backfill silver.sap_bsas', '2024', @t, @rows;
GO

-- sap_bsas 2025
DECLARE @t DATETIME2(0) = SYSDATETIME(), @rows INT;
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
SET @rows = @@ROWCOUNT;
EXEC control.log_step 'backfill silver.sap_bsas', '2025', @t, @rows;
GO

-- sap_bsas 2026
DECLARE @t DATETIME2(0) = SYSDATETIME(), @rows INT;
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
SET @rows = @@ROWCOUNT;
EXEC control.log_step 'backfill silver.sap_bsas', '2026', @t, @rows;
GO

-- sap_bsis 2022
DECLARE @t DATETIME2(0) = SYSDATETIME(), @rows INT;
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
SET @rows = @@ROWCOUNT;
EXEC control.log_step 'backfill silver.sap_bsis', '2022', @t, @rows;
GO

-- sap_bsis 2023
DECLARE @t DATETIME2(0) = SYSDATETIME(), @rows INT;
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
SET @rows = @@ROWCOUNT;
EXEC control.log_step 'backfill silver.sap_bsis', '2023', @t, @rows;
GO

-- sap_bsis 2024
DECLARE @t DATETIME2(0) = SYSDATETIME(), @rows INT;
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
SET @rows = @@ROWCOUNT;
EXEC control.log_step 'backfill silver.sap_bsis', '2024', @t, @rows;
GO

-- sap_bsis 2025
DECLARE @t DATETIME2(0) = SYSDATETIME(), @rows INT;
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
SET @rows = @@ROWCOUNT;
EXEC control.log_step 'backfill silver.sap_bsis', '2025', @t, @rows;
GO

-- sap_bsis 2026
DECLARE @t DATETIME2(0) = SYSDATETIME(), @rows INT;
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
SET @rows = @@ROWCOUNT;
EXEC control.log_step 'backfill silver.sap_bsis', '2026', @t, @rows;
GO

-- Check: rows and net amount per year, bronze vs silver. Every row must say OK.
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

-- Check: no line open and cleared at the same time. Must be 0.
SELECT COUNT(*) AS lineas_en_ambas
FROM silver.sap_bsas a
JOIN silver.sap_bsis i
  ON  i.mandante = a.mandante AND i.sociedad = a.sociedad AND i.cuenta_mayor = a.cuenta_mayor
  AND i.ejercicio = a.ejercicio AND i.documento_id = a.documento_id AND i.posicion = a.posicion;
GO
