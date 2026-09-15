/* ============================================================================
   Backfill silver.sap_bsad
   Purpose : Loads the cleared items older than the daily merge window from
             bronze.sap_bsad into silver.
   Run     : after bronze.backfill_bsad, one block at a time, in order. Each
             block is DELETE + INSERT for one clearing year: safe to re-run.
   Notes   : If a year fails with Msg 9002 (log full), split it in halves or
             quarters with the same DELETE + INSERT and a narrower date range.
   ============================================================================ */
USE ANALISIS_DATOS;
GO

-- Upper bound: the daily merge owns everything from this date on.
DECLARE @limite_check NVARCHAR(8) = CONVERT(NVARCHAR(8), DATEADD(MONTH, DATEDIFF(MONTH, 0, GETDATE()) - 1, 0), 112);
SELECT @limite_check AS limite_superior_backfill_AUGDT;
GO

-- 2022
DECLARE @t DATETIME2(0) = SYSDATETIME(), @rows INT;

DELETE FROM silver.sap_bsad
WHERE mandante = '400'
  AND fecha_compensacion >= '20220101' AND fecha_compensacion < '20230101';

INSERT INTO silver.sap_bsad (
    mandante, sociedad, cliente_id, ejercicio, mes, documento_id,
    asignacion, referencia, documento_ventas, posicion,
    fecha_contabilizacion, fecha_documento, fecha_registro_sistema, fecha_compensacion,
    documento_compensacion, ejercicio_compensacion, clase_documento, codigo_impuesto, debe_haber,
    clave_contabilizacion,
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
    NULLIF(LTRIM(RTRIM(BSCHL)), ''),
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

SET @rows = @@ROWCOUNT;
EXEC control.log_step 'backfill silver.sap_bsad', '2022', @t, @rows;
GO

-- 2023
DECLARE @t DATETIME2(0) = SYSDATETIME(), @rows INT;

DELETE FROM silver.sap_bsad
WHERE mandante = '400'
  AND fecha_compensacion >= '20230101' AND fecha_compensacion < '20240101';

INSERT INTO silver.sap_bsad (
    mandante, sociedad, cliente_id, ejercicio, mes, documento_id,
    asignacion, referencia, documento_ventas, posicion,
    fecha_contabilizacion, fecha_documento, fecha_registro_sistema, fecha_compensacion,
    documento_compensacion, ejercicio_compensacion, clase_documento, codigo_impuesto, debe_haber,
    clave_contabilizacion,
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
    NULLIF(LTRIM(RTRIM(BSCHL)), ''),
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

SET @rows = @@ROWCOUNT;
EXEC control.log_step 'backfill silver.sap_bsad', '2023', @t, @rows;
GO

-- 2024
DECLARE @t DATETIME2(0) = SYSDATETIME(), @rows INT;

DELETE FROM silver.sap_bsad
WHERE mandante = '400'
  AND fecha_compensacion >= '20240101' AND fecha_compensacion < '20250101';

INSERT INTO silver.sap_bsad (
    mandante, sociedad, cliente_id, ejercicio, mes, documento_id,
    asignacion, referencia, documento_ventas, posicion,
    fecha_contabilizacion, fecha_documento, fecha_registro_sistema, fecha_compensacion,
    documento_compensacion, ejercicio_compensacion, clase_documento, codigo_impuesto, debe_haber,
    clave_contabilizacion,
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
    NULLIF(LTRIM(RTRIM(BSCHL)), ''),
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

SET @rows = @@ROWCOUNT;
EXEC control.log_step 'backfill silver.sap_bsad', '2024', @t, @rows;
GO

-- 2025
DECLARE @t DATETIME2(0) = SYSDATETIME(), @rows INT;

DELETE FROM silver.sap_bsad
WHERE mandante = '400'
  AND fecha_compensacion >= '20250101' AND fecha_compensacion < '20260101';

INSERT INTO silver.sap_bsad (
    mandante, sociedad, cliente_id, ejercicio, mes, documento_id,
    asignacion, referencia, documento_ventas, posicion,
    fecha_contabilizacion, fecha_documento, fecha_registro_sistema, fecha_compensacion,
    documento_compensacion, ejercicio_compensacion, clase_documento, codigo_impuesto, debe_haber,
    clave_contabilizacion,
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
    NULLIF(LTRIM(RTRIM(BSCHL)), ''),
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

SET @rows = @@ROWCOUNT;
EXEC control.log_step 'backfill silver.sap_bsad', '2025', @t, @rows;
GO

-- 2026 up to the daily merge's window
DECLARE @t DATETIME2(0) = SYSDATETIME(), @rows INT;
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
    clave_contabilizacion,
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
    NULLIF(LTRIM(RTRIM(BSCHL)), ''),
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

SET @rows = @@ROWCOUNT;
EXEC control.log_step 'backfill silver.sap_bsad', '2026 partial', @t, @rows;
GO

-- Check: rows before the window, bronze vs silver. Both must match.
DECLARE @limite_final NVARCHAR(8) = CONVERT(NVARCHAR(8), DATEADD(MONTH, DATEDIFF(MONTH, 0, GETDATE()) - 1, 0), 112);

SELECT
    (SELECT COUNT(*) FROM bronze.sap_bsad WHERE MANDT = '400' AND AUGDT < @limite_final) AS filas_bronze_antes_del_limite,
    (SELECT COUNT(*) FROM silver.sap_bsad WHERE mandante = '400' AND fecha_compensacion < CONVERT(DATE, @limite_final, 112)) AS filas_silver_antes_del_limite;
GO
