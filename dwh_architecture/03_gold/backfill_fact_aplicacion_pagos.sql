/* ============================================================================
   Backfill of the payment application model
   Purpose : Loads gold.fact_facturas, fact_pagos, fact_aplicacion_pagos and
             fact_pagos_sin_aplicacion from 2022 on.
   Run     : block by block, in order, checking the output of each one:
               1. fact_facturas cleared, one year at a time
               2. fact_facturas open
               3. per year: pagos -> aplicacion -> sin_aplicacion
               4. effective payment date, per year
               5. checks
             Every block deletes what it loads first: any block can be re-run.
   Notes   : Step 1 does not use gold.load_fact_facturas: it ignores
             @fecha_hasta, so a call from 2022 would be one 3.2M-row INSERT
             against a 2 GB log.
             All invoices must be loaded before the first bridge year: a 2022
             payment can reach a 2023 invoice through the second hop.
             Msg 9002 (log full): CHECKPOINT, then split that year in halves.
   ============================================================================ */
USE ANALISIS_DATOS;
GO

-- 0. State before starting: keep this output.
SELECT 'fact_pagos' AS tabla, COUNT(*) AS filas FROM gold.fact_pagos
UNION ALL SELECT 'fact_facturas', COUNT(*) FROM gold.fact_facturas
UNION ALL SELECT 'fact_aplicacion_pagos', COUNT(*) FROM gold.fact_aplicacion_pagos
UNION ALL SELECT 'fact_pagos_sin_aplicacion', COUNT(*) FROM gold.fact_pagos_sin_aplicacion;

SELECT name AS archivo_log, size/128 AS mb_asignado,
       FILEPROPERTY(name,'SpaceUsed')/128 AS mb_usado
FROM sys.database_files WHERE type_desc = 'LOG';
GO

-- ----------------------------------------------------------------------------
-- 1. fact_facturas, cleared invoices, one year at a time
-- ----------------------------------------------------------------------------
DECLARE @t DATETIME2(0) = SYSDATETIME(), @rows INT = 0;
DECLARE @lote INT = 1;
WHILE @lote > 0
BEGIN
    DELETE TOP (50000) FROM gold.fact_facturas WHERE flag_compensada = 1;
    SET @lote = @@ROWCOUNT;
    SET @rows = @rows + @lote;
END
EXEC control.log_step 'backfill gold.fact_facturas', 'delete cleared', @t, @rows;
GO

-- 2022 (repeat changing both dates for 2023, 2024, 2025 and 2026)
DECLARE @t DATETIME2(0) = SYSDATETIME(), @rows INT;
INSERT INTO gold.fact_facturas (
    sociedad, cliente_id, ejercicio, documento_id, posicion,
    documento_compensacion, ejercicio_compensacion, clase_documento,
    fecha_documento, fecha_vencimiento, fecha_contabilizacion, fecha_compensacion,
    monto, clave_contabilizacion, flag_compensada,
    cliente_comercial_sk, cliente_credito_sk)
SELECT b.sociedad, b.cliente_id, b.ejercicio, b.documento_id, b.posicion,
       b.documento_compensacion, b.ejercicio_compensacion, b.clase_documento,
       b.fecha_documento, b.fecha_vencimiento, b.fecha_contabilizacion, b.fecha_compensacion,
       b.monto_moneda_local, b.clave_contabilizacion, 1,
       dcc.id_surrogate, dck.id_surrogate
FROM silver.sap_bsad b
LEFT JOIN gold.dim_cliente_comercial dcc
       ON dcc.cliente_id = b.cliente_id
      AND b.fecha_contabilizacion >= dcc.fecha_inicio_vigencia
      AND (dcc.fecha_fin_vigencia IS NULL OR b.fecha_contabilizacion <= dcc.fecha_fin_vigencia)
LEFT JOIN gold.dim_cliente_credito dck
       ON dck.cliente_id = b.cliente_id
      AND b.fecha_contabilizacion >= dck.fecha_inicio_vigencia
      AND (dck.fecha_fin_vigencia IS NULL OR b.fecha_contabilizacion <= dck.fecha_fin_vigencia)
WHERE b.mandante = '400'
  AND b.debe_haber = 'S'
  AND (b.clase_documento LIKE 'F%' OR b.clase_documento = 'D1')
  AND b.fecha_compensacion >= '2022-01-01'
  AND b.fecha_compensacion <  '2023-01-01'
  AND b.cliente_id IN (
        SELECT c1.cliente_id FROM gold.dim_cliente_comercial c1
        WHERE c1.estatus_comercial <> 'FUERA_DE_ALCANCE'
          AND c1.canal_distribucion IN (10, 40, 60))
  -- Clearing reset (FBRA): bsid wins, it is today's state.
  AND NOT EXISTS (
        SELECT 1 FROM silver.sap_bsid i
        WHERE i.mandante = b.mandante AND i.sociedad = b.sociedad
          AND i.cliente_id = b.cliente_id AND i.ejercicio = b.ejercicio
          AND i.documento_id = b.documento_id AND i.posicion = b.posicion);
SET @rows = @@ROWCOUNT;
EXEC control.log_step 'backfill gold.fact_facturas', 'cleared 2022', @t, @rows;
GO

-- Between years, check the log. Above ~1,200 MB run CHECKPOINT first.
SELECT FILEPROPERTY('ANALISIS_DATOS_log','SpaceUsed')/128 AS log_mb_usado;
GO

-- ----------------------------------------------------------------------------
-- 2. fact_facturas, open invoices: a snapshot of today, loaded once
-- ----------------------------------------------------------------------------
DECLARE @t DATETIME2(0) = SYSDATETIME(), @rows INT;
DECLARE @lote2 INT = 1;
WHILE @lote2 > 0
BEGIN
    DELETE TOP (50000) FROM gold.fact_facturas WHERE flag_compensada = 0;
    SET @lote2 = @@ROWCOUNT;
END

INSERT INTO gold.fact_facturas (
    sociedad, cliente_id, ejercicio, documento_id, posicion,
    documento_compensacion, ejercicio_compensacion, clase_documento,
    fecha_documento, fecha_vencimiento, fecha_contabilizacion, fecha_compensacion,
    monto, clave_contabilizacion, flag_compensada,
    cliente_comercial_sk, cliente_credito_sk)
SELECT b.sociedad, b.cliente_id, b.ejercicio, b.documento_id, b.posicion,
       NULL, NULL, b.clase_documento,
       b.fecha_documento, b.fecha_vencimiento, b.fecha_contabilizacion, NULL,
       b.monto_moneda_local, b.clave_contabilizacion, 0,
       dcc.id_surrogate, dck.id_surrogate
FROM silver.sap_bsid b
LEFT JOIN gold.dim_cliente_comercial dcc
       ON dcc.cliente_id = b.cliente_id
      AND b.fecha_contabilizacion >= dcc.fecha_inicio_vigencia
      AND (dcc.fecha_fin_vigencia IS NULL OR b.fecha_contabilizacion <= dcc.fecha_fin_vigencia)
LEFT JOIN gold.dim_cliente_credito dck
       ON dck.cliente_id = b.cliente_id
      AND b.fecha_contabilizacion >= dck.fecha_inicio_vigencia
      AND (dck.fecha_fin_vigencia IS NULL OR b.fecha_contabilizacion <= dck.fecha_fin_vigencia)
WHERE b.mandante = '400'
  AND b.debe_haber = 'S'
  AND (b.clase_documento LIKE 'F%' OR b.clase_documento = 'D1')
  AND b.cliente_id IN (
        SELECT c1.cliente_id FROM gold.dim_cliente_comercial c1
        WHERE c1.estatus_comercial <> 'FUERA_DE_ALCANCE'
          AND c1.canal_distribucion IN (10, 40, 60));
SET @rows = @@ROWCOUNT;
EXEC control.log_step 'backfill gold.fact_facturas', 'open', @t, @rows;
GO

-- Check before going on: flag 0 about 70K rows, flag 1 about 3.2M.
SELECT flag_compensada, COUNT(*) AS filas FROM gold.fact_facturas GROUP BY flag_compensada;
GO

-- ----------------------------------------------------------------------------
-- 3. Payments, bridge and sin_aplicacion, one whole year at a time
-- ----------------------------------------------------------------------------
EXEC gold.load_fact_pagos                '2022-01-01', '2023-01-01';
EXEC gold.load_fact_aplicacion_pagos     '2022-01-01', '2023-01-01';
EXEC gold.load_fact_pagos_sin_aplicacion '2022-01-01', '2023-01-01';
GO
SELECT FILEPROPERTY('ANALISIS_DATOS_log','SpaceUsed')/128 AS log_mb_usado;
GO

EXEC gold.load_fact_pagos                '2023-01-01', '2024-01-01';
EXEC gold.load_fact_aplicacion_pagos     '2023-01-01', '2024-01-01';
EXEC gold.load_fact_pagos_sin_aplicacion '2023-01-01', '2024-01-01';
GO
SELECT FILEPROPERTY('ANALISIS_DATOS_log','SpaceUsed')/128 AS log_mb_usado;
GO

EXEC gold.load_fact_pagos                '2024-01-01', '2025-01-01';
EXEC gold.load_fact_aplicacion_pagos     '2024-01-01', '2025-01-01';
EXEC gold.load_fact_pagos_sin_aplicacion '2024-01-01', '2025-01-01';
GO
SELECT FILEPROPERTY('ANALISIS_DATOS_log','SpaceUsed')/128 AS log_mb_usado;
GO

EXEC gold.load_fact_pagos                '2025-01-01', '2026-01-01';
EXEC gold.load_fact_aplicacion_pagos     '2025-01-01', '2026-01-01';
EXEC gold.load_fact_pagos_sin_aplicacion '2025-01-01', '2026-01-01';
GO
SELECT FILEPROPERTY('ANALISIS_DATOS_log','SpaceUsed')/128 AS log_mb_usado;
GO

-- Current year: no upper bound.
EXEC gold.load_fact_pagos                '2026-01-01';
EXEC gold.load_fact_aplicacion_pagos     '2026-01-01';
EXEC gold.load_fact_pagos_sin_aplicacion '2026-01-01';
GO

-- ----------------------------------------------------------------------------
-- 4. Effective payment date on the invoices, one year at a time
-- ----------------------------------------------------------------------------
CHECKPOINT;
EXEC gold.load_fact_facturas_pago_efectivo '2022-01-01', '2023-01-01';
GO
CHECKPOINT;
EXEC gold.load_fact_facturas_pago_efectivo '2023-01-01', '2024-01-01';
GO
CHECKPOINT;
EXEC gold.load_fact_facturas_pago_efectivo '2024-01-01', '2025-01-01';
GO
CHECKPOINT;
EXEC gold.load_fact_facturas_pago_efectivo '2025-01-01', '2026-01-01';
GO
CHECKPOINT;
EXEC gold.load_fact_facturas_pago_efectivo '2026-01-01';
GO

-- ----------------------------------------------------------------------------
-- 5. Checks: B + C = A; D, E and F must be 0.
-- ----------------------------------------------------------------------------
SELECT 'A. total fact_pagos' AS invariante,
       CAST(CAST(SUM(monto) AS DECIMAL(18,2)) AS VARCHAR(24)) AS valor
FROM gold.fact_pagos
UNION ALL
SELECT 'B. ligado a facturas',
       CAST(CAST(SUM(p.monto) AS DECIMAL(18,2)) AS VARCHAR(24))
FROM gold.fact_pagos p
WHERE EXISTS (SELECT 1 FROM gold.fact_aplicacion_pagos a
              WHERE a.sociedad=p.sociedad AND a.ejercicio_pago=p.ejercicio
                AND a.pago_id=p.documento_id AND a.posicion_pago=p.posicion)
UNION ALL
SELECT 'C. sin aplicacion',
       CAST(CAST(SUM(p.monto) AS DECIMAL(18,2)) AS VARCHAR(24))
FROM gold.fact_pagos p
JOIN gold.fact_pagos_sin_aplicacion s
  ON s.sociedad=p.sociedad AND s.ejercicio=p.ejercicio
 AND s.documento_id=p.documento_id AND s.posicion=p.posicion
UNION ALL
SELECT 'D. pagos en AMBAS tablas (debe ser 0)',
       CAST(COUNT(*) AS VARCHAR(24))
FROM gold.fact_pagos p
WHERE EXISTS (SELECT 1 FROM gold.fact_aplicacion_pagos a
              WHERE a.sociedad=p.sociedad AND a.ejercicio_pago=p.ejercicio
                AND a.pago_id=p.documento_id AND a.posicion_pago=p.posicion)
  AND EXISTS (SELECT 1 FROM gold.fact_pagos_sin_aplicacion s
              WHERE s.sociedad=p.sociedad AND s.ejercicio=p.ejercicio
                AND s.documento_id=p.documento_id AND s.posicion=p.posicion)
UNION ALL
SELECT 'E. pagos sin clasificar (debe ser 0)',
       CAST(COUNT(*) AS VARCHAR(24))
FROM gold.fact_pagos p
WHERE NOT EXISTS (SELECT 1 FROM gold.fact_aplicacion_pagos a
                  WHERE a.sociedad=p.sociedad AND a.ejercicio_pago=p.ejercicio
                    AND a.pago_id=p.documento_id AND a.posicion_pago=p.posicion)
  AND NOT EXISTS (SELECT 1 FROM gold.fact_pagos_sin_aplicacion s
                  WHERE s.sociedad=p.sociedad AND s.ejercicio=p.ejercicio
                    AND s.documento_id=p.documento_id AND s.posicion=p.posicion)
UNION ALL
SELECT 'F. etiqueta REVISAR (debe ser 0)',
       CAST(COUNT(*) AS VARCHAR(24))
FROM gold.fact_pagos_sin_aplicacion WHERE motivo = 'REVISAR';
GO

-- Coverage per year.
SELECT YEAR(p.fecha_compensacion) AS anio,
       COUNT(*) AS pagos,
       CAST(SUM(p.monto) AS DECIMAL(18,2)) AS total,
       CAST(SUM(CASE WHEN a.pago_id IS NOT NULL THEN p.monto ELSE 0 END) AS DECIMAL(18,2)) AS ligado
FROM gold.fact_pagos p
LEFT JOIN (SELECT DISTINCT sociedad, ejercicio_pago, pago_id, posicion_pago
           FROM gold.fact_aplicacion_pagos) a
       ON a.sociedad=p.sociedad AND a.ejercicio_pago=p.ejercicio
      AND a.pago_id=p.documento_id AND a.posicion_pago=p.posicion
GROUP BY YEAR(p.fecha_compensacion)
ORDER BY anio;
GO
