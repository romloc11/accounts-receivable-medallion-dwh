USE ANALISIS_DATOS;
GO

/*
========================================================================================
HISTORICAL BACKFILL: gold.fact_pagos_compensados / gold.fact_facturas_compensadas
========================================================================================
PURPOSE:
gold.load_fact_pagos_compensados / gold.load_fact_facturas_compensadas (incremental MERGE in sp_load_gold.sql)
only maintain current month + previous month, the same way silver.load_silver does with bsad.
This script brings in the complete history since 2022-01-01 (the same start date as
silver.sap_bsad, confirmed via MIN(AUGDT) in bronze's original backfill).

UNLIKE gold.fact_aplicacion_pagos (which was scoped to 2024+ because its 3-tier matching
logic was expensive per row), fact_pagos_compensados/fact_facturas_compensadas are a simple filter
+ INSERT over silver.sap_bsad (the same per-row cost as silver.sap_bsad's own backfill,
which already ran in 5 yearly chunks with no issue) - there's no computational reason to
scope the range, and gold.vw_pago_factura_simple needs the complete history of BOTH
tables to correctly count candidates per compensation group (if history were missing
from one but not the other, the "num_pagos_candidatos" count per group would be wrong
for groups with activity outside the partial window).

debe_haber<>'S' FILTER in fact_pagos_compensados (added 2026-08-19, see ddl_gold.sql section 6):
excludes the mirror/offsetting line that the "child" document of a compensation always
carries (same documento_id=documento_compensacion, same amount, same
sgtxt='Asignación Aut. Deposito' as the real deposit, but debe_haber='S') - without this
filter it was counted as a second candidate raw payment, falsely inflating ambiguity in
gold.vw_pago_factura_simple.

UPPER BOUND:
Same as backfill_bsad_historico.sql: the bound is computed dynamically (first day of
the month before today) so as not to step on the window the daily incremental already
maintains.

CHUNK PATTERN: one chunk per year, DELETE + INSERT (idempotent). If a given year breaks
with "Msg 9002: transaction log full," split that year into half-years/quarters, same
method as backfill_bsad_historico.sql. Don't run two chunks at once in different tabs -
one at a time, checking the PRINT output before continuing.
========================================================================================
*/

DECLARE @limite_check DATE = DATEADD(MONTH, DATEDIFF(MONTH, 0, GETDATE()) - 1, 0);
SELECT @limite_check AS limite_superior_backfill_fecha_compensacion;
GO

-- ========================================================================================
-- Full 2022
-- ========================================================================================
DELETE FROM gold.fact_pagos_compensados
WHERE fecha_compensacion >= '20220101' AND fecha_compensacion < '20230101';

INSERT INTO gold.fact_pagos_compensados (
    sociedad, cliente_id, ejercicio, documento_id, posicion,
    fecha_documento, fecha_compensacion, monto_moneda_local,
    documento_compensacion, ejercicio_compensacion
)
SELECT
    sociedad, cliente_id, ejercicio, documento_id, posicion,
    fecha_documento, fecha_compensacion, monto_moneda_local,
    documento_compensacion, ejercicio_compensacion
FROM silver.sap_bsad
WHERE clase_documento = 'DZ'
  AND sgtxt = 'Asignación Aut. Deposito'
  AND debe_haber <> 'S'
  AND monto_moneda_local > 0
  AND fecha_compensacion >= '20220101' AND fecha_compensacion < '20230101';

PRINT 'fact_pagos_compensados - rows inserted 2022: ' + CAST(@@ROWCOUNT AS VARCHAR);

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

PRINT 'fact_facturas_compensadas - rows inserted 2022: ' + CAST(@@ROWCOUNT AS VARCHAR);
GO

-- ========================================================================================
-- Full 2023
-- ========================================================================================
DELETE FROM gold.fact_pagos_compensados
WHERE fecha_compensacion >= '20230101' AND fecha_compensacion < '20240101';

INSERT INTO gold.fact_pagos_compensados (
    sociedad, cliente_id, ejercicio, documento_id, posicion,
    fecha_documento, fecha_compensacion, monto_moneda_local,
    documento_compensacion, ejercicio_compensacion
)
SELECT
    sociedad, cliente_id, ejercicio, documento_id, posicion,
    fecha_documento, fecha_compensacion, monto_moneda_local,
    documento_compensacion, ejercicio_compensacion
FROM silver.sap_bsad
WHERE clase_documento = 'DZ'
  AND sgtxt = 'Asignación Aut. Deposito'
  AND debe_haber <> 'S'
  AND monto_moneda_local > 0
  AND fecha_compensacion >= '20230101' AND fecha_compensacion < '20240101';

PRINT 'fact_pagos_compensados - rows inserted 2023: ' + CAST(@@ROWCOUNT AS VARCHAR);

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

PRINT 'fact_facturas_compensadas - rows inserted 2023: ' + CAST(@@ROWCOUNT AS VARCHAR);
GO

-- ========================================================================================
-- Full 2024
-- ========================================================================================
DELETE FROM gold.fact_pagos_compensados
WHERE fecha_compensacion >= '20240101' AND fecha_compensacion < '20250101';

INSERT INTO gold.fact_pagos_compensados (
    sociedad, cliente_id, ejercicio, documento_id, posicion,
    fecha_documento, fecha_compensacion, monto_moneda_local,
    documento_compensacion, ejercicio_compensacion
)
SELECT
    sociedad, cliente_id, ejercicio, documento_id, posicion,
    fecha_documento, fecha_compensacion, monto_moneda_local,
    documento_compensacion, ejercicio_compensacion
FROM silver.sap_bsad
WHERE clase_documento = 'DZ'
  AND sgtxt = 'Asignación Aut. Deposito'
  AND debe_haber <> 'S'
  AND monto_moneda_local > 0
  AND fecha_compensacion >= '20240101' AND fecha_compensacion < '20250101';

PRINT 'fact_pagos_compensados - rows inserted 2024: ' + CAST(@@ROWCOUNT AS VARCHAR);

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

PRINT 'fact_facturas_compensadas - rows inserted 2024: ' + CAST(@@ROWCOUNT AS VARCHAR);
GO

-- ========================================================================================
-- Full 2025
-- ========================================================================================
DELETE FROM gold.fact_pagos_compensados
WHERE fecha_compensacion >= '20250101' AND fecha_compensacion < '20260101';

INSERT INTO gold.fact_pagos_compensados (
    sociedad, cliente_id, ejercicio, documento_id, posicion,
    fecha_documento, fecha_compensacion, monto_moneda_local,
    documento_compensacion, ejercicio_compensacion
)
SELECT
    sociedad, cliente_id, ejercicio, documento_id, posicion,
    fecha_documento, fecha_compensacion, monto_moneda_local,
    documento_compensacion, ejercicio_compensacion
FROM silver.sap_bsad
WHERE clase_documento = 'DZ'
  AND sgtxt = 'Asignación Aut. Deposito'
  AND debe_haber <> 'S'
  AND monto_moneda_local > 0
  AND fecha_compensacion >= '20250101' AND fecha_compensacion < '20260101';

PRINT 'fact_pagos_compensados - rows inserted 2025: ' + CAST(@@ROWCOUNT AS VARCHAR);

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

PRINT 'fact_facturas_compensadas - rows inserted 2025: ' + CAST(@@ROWCOUNT AS VARCHAR);
GO

-- ========================================================================================
-- Partial 2026: from Jan 1st up to the bound the incremental already covers
-- (dynamic bound - does NOT touch the 2-month window that load_fact_pagos_compensados/
-- load_fact_facturas_compensadas maintain)
-- ========================================================================================
DECLARE @limite_date DATE = DATEADD(MONTH, DATEDIFF(MONTH, 0, GETDATE()) - 1, 0);

DELETE FROM gold.fact_pagos_compensados
WHERE fecha_compensacion >= '20260101' AND fecha_compensacion < @limite_date;

INSERT INTO gold.fact_pagos_compensados (
    sociedad, cliente_id, ejercicio, documento_id, posicion,
    fecha_documento, fecha_compensacion, monto_moneda_local,
    documento_compensacion, ejercicio_compensacion
)
SELECT
    sociedad, cliente_id, ejercicio, documento_id, posicion,
    fecha_documento, fecha_compensacion, monto_moneda_local,
    documento_compensacion, ejercicio_compensacion
FROM silver.sap_bsad
WHERE clase_documento = 'DZ'
  AND sgtxt = 'Asignación Aut. Deposito'
  AND debe_haber <> 'S'
  AND monto_moneda_local > 0
  AND fecha_compensacion >= '20260101' AND fecha_compensacion < @limite_date;

PRINT 'fact_pagos_compensados - rows inserted 2026 (partial, up to the incremental''s bound): ' + CAST(@@ROWCOUNT AS VARCHAR);

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

PRINT 'fact_facturas_compensadas - rows inserted 2026 (partial, up to the incremental''s bound): ' + CAST(@@ROWCOUNT AS VARCHAR);
GO

-- ========================================================================================
-- Final check: total in gold vs. what's in silver.sap_bsad before the incremental's
-- bound (should match exactly if every chunk ran correctly)
-- ========================================================================================
DECLARE @limite_final DATE = DATEADD(MONTH, DATEDIFF(MONTH, 0, GETDATE()) - 1, 0);

SELECT
    (SELECT COUNT(*) FROM silver.sap_bsad WHERE clase_documento = 'DZ' AND sgtxt = 'Asignación Aut. Deposito' AND debe_haber <> 'S' AND monto_moneda_local > 0 AND fecha_compensacion < @limite_final) AS pagos_silver_antes_del_limite,
    (SELECT COUNT(*) FROM gold.fact_pagos_compensados WHERE fecha_compensacion < @limite_final) AS pagos_gold_antes_del_limite,
    (SELECT COUNT(*) FROM silver.sap_bsad WHERE clase_documento IN ('F1','F2','F3','F4','F5','F6') AND fecha_compensacion < @limite_final) AS facturas_silver_antes_del_limite,
    (SELECT COUNT(*) FROM gold.fact_facturas_compensadas WHERE fecha_compensacion < @limite_final) AS facturas_gold_antes_del_limite;
GO
