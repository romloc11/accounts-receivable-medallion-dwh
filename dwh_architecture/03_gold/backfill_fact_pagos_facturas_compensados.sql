/* ============================================================================
   Backfill gold.fact_pagos_compensados / gold.fact_facturas_compensadas
   Purpose : Loads the legacy settled facts from 2022 up to the daily merge
             window (first day of the previous month).
   Run     : one block at a time, in order. Each block is DELETE + INSERT for
             one clearing year: safe to re-run. Then the check at the end.
   Notes   : gold.vw_pago_factura_simple needs the full history of both tables
             to count candidates per clearing group.
             Msg 9002 (log full): split that year in halves.
   ============================================================================ */
USE ANALISIS_DATOS;
GO

-- Upper bound: the daily merge owns everything from this date on.
DECLARE @limite_check DATE = DATEADD(MONTH, DATEDIFF(MONTH, 0, GETDATE()) - 1, 0);
SELECT @limite_check AS limite_superior_backfill_fecha_compensacion;
GO

-- 2022
DECLARE @t DATETIME2(0) = SYSDATETIME(), @rows INT;

DELETE FROM gold.fact_pagos_compensados
WHERE fecha_compensacion >= '20220101' AND fecha_compensacion < '20230101';

INSERT INTO gold.fact_pagos_compensados (
    sociedad, cliente_id, ejercicio, documento_id, posicion,
    fecha_documento, fecha_contabilizacion, fecha_compensacion, monto_moneda_local,
    documento_compensacion, ejercicio_compensacion
)
SELECT
    sociedad, cliente_id, ejercicio, documento_id, posicion,
    fecha_documento, fecha_contabilizacion, fecha_compensacion, monto_moneda_local,
    documento_compensacion, ejercicio_compensacion
FROM silver.sap_bsad b
WHERE b.clase_documento = 'DZ'
  AND (b.sgtxt = 'Asignación Aut. Deposito' OR b.sgtxt LIKE 'BB%')
  AND b.debe_haber <> 'S'
  AND b.monto_moneda_local > 0
  AND NOT ( -- not a self-canceling internal pair
      b.documento_compensacion = b.documento_id
      AND EXISTS (
          SELECT 1 FROM silver.sap_bsad b2
          WHERE b2.sociedad = b.sociedad AND b2.cliente_id = b.cliente_id
            AND b2.ejercicio = b.ejercicio AND b2.documento_id = b.documento_id
            AND b2.posicion <> b.posicion
            AND b2.clase_documento = 'DZ' AND b2.debe_haber = 'S'
            AND b2.monto_moneda_local = b.monto_moneda_local
      )
  )
  AND b.fecha_compensacion >= '20220101' AND fecha_compensacion < '20230101';

SET @rows = @@ROWCOUNT;
EXEC control.log_step 'backfill gold.fact_pagos_compensados', '2022', @t, @rows;

SET @t = SYSDATETIME();

DELETE FROM gold.fact_facturas_compensadas
WHERE fecha_compensacion >= '20220101' AND fecha_compensacion < '20230101';

INSERT INTO gold.fact_facturas_compensadas (
    sociedad, cliente_id, ejercicio, documento_id, posicion,
    fecha_documento, fecha_vencimiento, fecha_compensacion, monto_moneda_local,
    documento_compensacion, ejercicio_compensacion
)
SELECT
    sociedad, cliente_id, ejercicio, documento_id, posicion,
    fecha_documento, fecha_vencimiento, fecha_compensacion, monto_moneda_local,
    documento_compensacion, ejercicio_compensacion
FROM silver.sap_bsad
WHERE clase_documento IN ('F1', 'F2', 'F3', 'F4', 'F5', 'F6')
  AND fecha_compensacion >= '20220101' AND fecha_compensacion < '20230101';

SET @rows = @@ROWCOUNT;
EXEC control.log_step 'backfill gold.fact_facturas_compensadas', '2022', @t, @rows;
GO

-- 2023
DECLARE @t DATETIME2(0) = SYSDATETIME(), @rows INT;

DELETE FROM gold.fact_pagos_compensados
WHERE fecha_compensacion >= '20230101' AND fecha_compensacion < '20240101';

INSERT INTO gold.fact_pagos_compensados (
    sociedad, cliente_id, ejercicio, documento_id, posicion,
    fecha_documento, fecha_contabilizacion, fecha_compensacion, monto_moneda_local,
    documento_compensacion, ejercicio_compensacion
)
SELECT
    sociedad, cliente_id, ejercicio, documento_id, posicion,
    fecha_documento, fecha_contabilizacion, fecha_compensacion, monto_moneda_local,
    documento_compensacion, ejercicio_compensacion
FROM silver.sap_bsad b
WHERE b.clase_documento = 'DZ'
  AND (b.sgtxt = 'Asignación Aut. Deposito' OR b.sgtxt LIKE 'BB%')
  AND b.debe_haber <> 'S'
  AND b.monto_moneda_local > 0
  AND NOT ( -- not a self-canceling internal pair
      b.documento_compensacion = b.documento_id
      AND EXISTS (
          SELECT 1 FROM silver.sap_bsad b2
          WHERE b2.sociedad = b.sociedad AND b2.cliente_id = b.cliente_id
            AND b2.ejercicio = b.ejercicio AND b2.documento_id = b.documento_id
            AND b2.posicion <> b.posicion
            AND b2.clase_documento = 'DZ' AND b2.debe_haber = 'S'
            AND b2.monto_moneda_local = b.monto_moneda_local
      )
  )
  AND b.fecha_compensacion >= '20230101' AND fecha_compensacion < '20240101';

SET @rows = @@ROWCOUNT;
EXEC control.log_step 'backfill gold.fact_pagos_compensados', '2023', @t, @rows;

SET @t = SYSDATETIME();

DELETE FROM gold.fact_facturas_compensadas
WHERE fecha_compensacion >= '20230101' AND fecha_compensacion < '20240101';

INSERT INTO gold.fact_facturas_compensadas (
    sociedad, cliente_id, ejercicio, documento_id, posicion,
    fecha_documento, fecha_vencimiento, fecha_compensacion, monto_moneda_local,
    documento_compensacion, ejercicio_compensacion
)
SELECT
    sociedad, cliente_id, ejercicio, documento_id, posicion,
    fecha_documento, fecha_vencimiento, fecha_compensacion, monto_moneda_local,
    documento_compensacion, ejercicio_compensacion
FROM silver.sap_bsad
WHERE clase_documento IN ('F1', 'F2', 'F3', 'F4', 'F5', 'F6')
  AND fecha_compensacion >= '20230101' AND fecha_compensacion < '20240101';

SET @rows = @@ROWCOUNT;
EXEC control.log_step 'backfill gold.fact_facturas_compensadas', '2023', @t, @rows;
GO

-- 2024
DECLARE @t DATETIME2(0) = SYSDATETIME(), @rows INT;

DELETE FROM gold.fact_pagos_compensados
WHERE fecha_compensacion >= '20240101' AND fecha_compensacion < '20250101';

INSERT INTO gold.fact_pagos_compensados (
    sociedad, cliente_id, ejercicio, documento_id, posicion,
    fecha_documento, fecha_contabilizacion, fecha_compensacion, monto_moneda_local,
    documento_compensacion, ejercicio_compensacion
)
SELECT
    sociedad, cliente_id, ejercicio, documento_id, posicion,
    fecha_documento, fecha_contabilizacion, fecha_compensacion, monto_moneda_local,
    documento_compensacion, ejercicio_compensacion
FROM silver.sap_bsad b
WHERE b.clase_documento = 'DZ'
  AND (b.sgtxt = 'Asignación Aut. Deposito' OR b.sgtxt LIKE 'BB%')
  AND b.debe_haber <> 'S'
  AND b.monto_moneda_local > 0
  AND NOT ( -- not a self-canceling internal pair
      b.documento_compensacion = b.documento_id
      AND EXISTS (
          SELECT 1 FROM silver.sap_bsad b2
          WHERE b2.sociedad = b.sociedad AND b2.cliente_id = b.cliente_id
            AND b2.ejercicio = b.ejercicio AND b2.documento_id = b.documento_id
            AND b2.posicion <> b.posicion
            AND b2.clase_documento = 'DZ' AND b2.debe_haber = 'S'
            AND b2.monto_moneda_local = b.monto_moneda_local
      )
  )
  AND b.fecha_compensacion >= '20240101' AND fecha_compensacion < '20250101';

SET @rows = @@ROWCOUNT;
EXEC control.log_step 'backfill gold.fact_pagos_compensados', '2024', @t, @rows;

SET @t = SYSDATETIME();

DELETE FROM gold.fact_facturas_compensadas
WHERE fecha_compensacion >= '20240101' AND fecha_compensacion < '20250101';

INSERT INTO gold.fact_facturas_compensadas (
    sociedad, cliente_id, ejercicio, documento_id, posicion,
    fecha_documento, fecha_vencimiento, fecha_compensacion, monto_moneda_local,
    documento_compensacion, ejercicio_compensacion
)
SELECT
    sociedad, cliente_id, ejercicio, documento_id, posicion,
    fecha_documento, fecha_vencimiento, fecha_compensacion, monto_moneda_local,
    documento_compensacion, ejercicio_compensacion
FROM silver.sap_bsad
WHERE clase_documento IN ('F1', 'F2', 'F3', 'F4', 'F5', 'F6')
  AND fecha_compensacion >= '20240101' AND fecha_compensacion < '20250101';

SET @rows = @@ROWCOUNT;
EXEC control.log_step 'backfill gold.fact_facturas_compensadas', '2024', @t, @rows;
GO

-- 2025
DECLARE @t DATETIME2(0) = SYSDATETIME(), @rows INT;

DELETE FROM gold.fact_pagos_compensados
WHERE fecha_compensacion >= '20250101' AND fecha_compensacion < '20260101';

INSERT INTO gold.fact_pagos_compensados (
    sociedad, cliente_id, ejercicio, documento_id, posicion,
    fecha_documento, fecha_contabilizacion, fecha_compensacion, monto_moneda_local,
    documento_compensacion, ejercicio_compensacion
)
SELECT
    sociedad, cliente_id, ejercicio, documento_id, posicion,
    fecha_documento, fecha_contabilizacion, fecha_compensacion, monto_moneda_local,
    documento_compensacion, ejercicio_compensacion
FROM silver.sap_bsad b
WHERE b.clase_documento = 'DZ'
  AND (b.sgtxt = 'Asignación Aut. Deposito' OR b.sgtxt LIKE 'BB%')
  AND b.debe_haber <> 'S'
  AND b.monto_moneda_local > 0
  AND NOT ( -- not a self-canceling internal pair
      b.documento_compensacion = b.documento_id
      AND EXISTS (
          SELECT 1 FROM silver.sap_bsad b2
          WHERE b2.sociedad = b.sociedad AND b2.cliente_id = b.cliente_id
            AND b2.ejercicio = b.ejercicio AND b2.documento_id = b.documento_id
            AND b2.posicion <> b.posicion
            AND b2.clase_documento = 'DZ' AND b2.debe_haber = 'S'
            AND b2.monto_moneda_local = b.monto_moneda_local
      )
  )
  AND b.fecha_compensacion >= '20250101' AND fecha_compensacion < '20260101';

SET @rows = @@ROWCOUNT;
EXEC control.log_step 'backfill gold.fact_pagos_compensados', '2025', @t, @rows;

SET @t = SYSDATETIME();

DELETE FROM gold.fact_facturas_compensadas
WHERE fecha_compensacion >= '20250101' AND fecha_compensacion < '20260101';

INSERT INTO gold.fact_facturas_compensadas (
    sociedad, cliente_id, ejercicio, documento_id, posicion,
    fecha_documento, fecha_vencimiento, fecha_compensacion, monto_moneda_local,
    documento_compensacion, ejercicio_compensacion
)
SELECT
    sociedad, cliente_id, ejercicio, documento_id, posicion,
    fecha_documento, fecha_vencimiento, fecha_compensacion, monto_moneda_local,
    documento_compensacion, ejercicio_compensacion
FROM silver.sap_bsad
WHERE clase_documento IN ('F1', 'F2', 'F3', 'F4', 'F5', 'F6')
  AND fecha_compensacion >= '20250101' AND fecha_compensacion < '20260101';

SET @rows = @@ROWCOUNT;
EXEC control.log_step 'backfill gold.fact_facturas_compensadas', '2025', @t, @rows;
GO

-- 2026 up to the daily merge window
DECLARE @t DATETIME2(0) = SYSDATETIME(), @rows INT;
DECLARE @limite_date DATE = DATEADD(MONTH, DATEDIFF(MONTH, 0, GETDATE()) - 1, 0);

DELETE FROM gold.fact_pagos_compensados
WHERE fecha_compensacion >= '20260101' AND fecha_compensacion < @limite_date;

INSERT INTO gold.fact_pagos_compensados (
    sociedad, cliente_id, ejercicio, documento_id, posicion,
    fecha_documento, fecha_contabilizacion, fecha_compensacion, monto_moneda_local,
    documento_compensacion, ejercicio_compensacion
)
SELECT
    sociedad, cliente_id, ejercicio, documento_id, posicion,
    fecha_documento, fecha_contabilizacion, fecha_compensacion, monto_moneda_local,
    documento_compensacion, ejercicio_compensacion
FROM silver.sap_bsad b
WHERE b.clase_documento = 'DZ'
  AND (b.sgtxt = 'Asignación Aut. Deposito' OR b.sgtxt LIKE 'BB%')
  AND b.debe_haber <> 'S'
  AND b.monto_moneda_local > 0
  AND NOT ( -- not a self-canceling internal pair
      b.documento_compensacion = b.documento_id
      AND EXISTS (
          SELECT 1 FROM silver.sap_bsad b2
          WHERE b2.sociedad = b.sociedad AND b2.cliente_id = b.cliente_id
            AND b2.ejercicio = b.ejercicio AND b2.documento_id = b.documento_id
            AND b2.posicion <> b.posicion
            AND b2.clase_documento = 'DZ' AND b2.debe_haber = 'S'
            AND b2.monto_moneda_local = b.monto_moneda_local
      )
  )
  AND b.fecha_compensacion >= '20260101' AND fecha_compensacion < @limite_date;

SET @rows = @@ROWCOUNT;
EXEC control.log_step 'backfill gold.fact_pagos_compensados', '2026 partial', @t, @rows;

SET @t = SYSDATETIME();

DELETE FROM gold.fact_facturas_compensadas
WHERE fecha_compensacion >= '20260101' AND fecha_compensacion < @limite_date;

INSERT INTO gold.fact_facturas_compensadas (
    sociedad, cliente_id, ejercicio, documento_id, posicion,
    fecha_documento, fecha_vencimiento, fecha_compensacion, monto_moneda_local,
    documento_compensacion, ejercicio_compensacion
)
SELECT
    sociedad, cliente_id, ejercicio, documento_id, posicion,
    fecha_documento, fecha_vencimiento, fecha_compensacion, monto_moneda_local,
    documento_compensacion, ejercicio_compensacion
FROM silver.sap_bsad
WHERE clase_documento IN ('F1', 'F2', 'F3', 'F4', 'F5', 'F6')
  AND fecha_compensacion >= '20260101' AND fecha_compensacion < @limite_date;

SET @rows = @@ROWCOUNT;
EXEC control.log_step 'backfill gold.fact_facturas_compensadas', '2026 partial', @t, @rows;
GO

-- Check: rows before the window, silver vs gold. Both pairs must match.
DECLARE @limite_final DATE = DATEADD(MONTH, DATEDIFF(MONTH, 0, GETDATE()) - 1, 0);

SELECT
    (SELECT COUNT(*) FROM silver.sap_bsad WHERE clase_documento = 'DZ' AND (sgtxt = 'Asignación Aut. Deposito' OR sgtxt LIKE 'BB%') AND debe_haber <> 'S' AND monto_moneda_local > 0 AND fecha_compensacion < @limite_final) AS pagos_silver_antes_del_limite,
    (SELECT COUNT(*) FROM gold.fact_pagos_compensados WHERE fecha_compensacion < @limite_final) AS pagos_gold_antes_del_limite,
    (SELECT COUNT(*) FROM silver.sap_bsad WHERE clase_documento IN ('F1','F2','F3','F4','F5','F6') AND fecha_compensacion < @limite_final) AS facturas_silver_antes_del_limite,
    (SELECT COUNT(*) FROM gold.fact_facturas_compensadas WHERE fecha_compensacion < @limite_final) AS facturas_gold_antes_del_limite;
GO
