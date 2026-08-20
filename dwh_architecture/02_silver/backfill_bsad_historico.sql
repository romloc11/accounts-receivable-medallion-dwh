USE ANALISIS_DATOS;
GO

/*
========================================================================================
BACKFILL HISTORICO: silver.sap_bsad
========================================================================================
PROPOSITO:
silver.sap_bsad solo tiene ~295K filas (ventana de 2 meses que mantiene el MERGE
incremental de silver.load_silver), mientras que bronze.sap_bsad ya tiene el historico
completo desde 2022-01-01 (~12.2M filas). Este script hace el backfill de todo lo
anterior a la ventana que ya mantiene el incremental diario, para no duplicar ni pisar
su trabajo.

LIMITE SUPERIOR:
silver.load_silver mantiene AUGDT >= primer dia del mes anterior. Este backfill cubre
todo lo ANTERIOR a ese limite. El limite se calcula dinamicamente (misma formula que
sp_load_silver.sql) para que siga siendo correcto sin importar que dia se corra esto.

PATRON DE CHUNKS (igual que el backfill original de bronze.sap_bsad):
Un chunk por año. Cada chunk es DELETE + INSERT (idempotente - seguro volver a correr
el mismo chunk si falla a la mitad o se cae la VPN). Si un año completo truena con:
    Msg 9002: The transaction log for database 'ANALISIS_DATOS' is full
parte ESE año en dos mitades (semestres) y corre cada mitad por separado, con el mismo
patron DELETE+INSERT pero acotando el rango de fechas. Si un semestre todavia truena,
sigue partiendo a trimestres o meses. Ejemplo de como partir el chunk de 2022 en dos:

    -- 2022 primer semestre
    ... WHERE fecha_compensacion >= '20220101' AND fecha_compensacion < '20220701'
    ... WHERE AUGDT >= '20220101' AND AUGDT < '20220701'

    -- 2022 segundo semestre
    ... WHERE fecha_compensacion >= '20220701' AND fecha_compensacion < '20230101'
    ... WHERE AUGDT >= '20220701' AND AUGDT < '20230101'

No corras dos chunks al mismo tiempo en pestañas distintas de SSMS - uno a la vez, en
orden, revisando el PRINT de filas insertadas antes de seguir con el siguiente.
========================================================================================
*/

-- Verifica el limite superior antes de arrancar (informativo, no hace nada por si solo)
DECLARE @limite_check NVARCHAR(8) = CONVERT(NVARCHAR(8), DATEADD(MONTH, DATEDIFF(MONTH, 0, GETDATE()) - 1, 0), 112);
SELECT @limite_check AS limite_superior_backfill_AUGDT;
GO

-- ========================================================================================
-- 2022 completo
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

PRINT 'Filas insertadas 2022: ' + CAST(@@ROWCOUNT AS VARCHAR);
GO

-- ========================================================================================
-- 2023 completo
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

PRINT 'Filas insertadas 2023: ' + CAST(@@ROWCOUNT AS VARCHAR);
GO

-- ========================================================================================
-- 2024 completo
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

PRINT 'Filas insertadas 2024: ' + CAST(@@ROWCOUNT AS VARCHAR);
GO

-- ========================================================================================
-- 2025 completo
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

PRINT 'Filas insertadas 2025: ' + CAST(@@ROWCOUNT AS VARCHAR);
GO

-- ========================================================================================
-- 2026 parcial: desde el 1-ene hasta el limite que ya cubre el incremental diario
-- (limite dinamico - NO toca la ventana de 2 meses que mantiene silver.load_silver)
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

PRINT 'Filas insertadas 2026 (parcial, hasta limite de silver.load_silver): ' + CAST(@@ROWCOUNT AS VARCHAR);
GO

-- ========================================================================================
-- Verificacion final: total en silver vs. lo que hay en bronze antes del limite del
-- incremental diario (deberian coincidir exactamente si todos los chunks corrieron bien)
-- ========================================================================================
DECLARE @limite_final NVARCHAR(8) = CONVERT(NVARCHAR(8), DATEADD(MONTH, DATEDIFF(MONTH, 0, GETDATE()) - 1, 0), 112);

SELECT
    (SELECT COUNT(*) FROM bronze.sap_bsad WHERE MANDT = '400' AND AUGDT < @limite_final) AS filas_bronze_antes_del_limite,
    (SELECT COUNT(*) FROM silver.sap_bsad WHERE mandante = '400' AND fecha_compensacion < CONVERT(DATE, @limite_final, 112)) AS filas_silver_antes_del_limite;
GO
