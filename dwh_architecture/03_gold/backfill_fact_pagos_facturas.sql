USE ANALISIS_DATOS;
GO

/*
========================================================================================
BACKFILL HISTORICO: gold.fact_pagos / gold.fact_facturas
========================================================================================
PROPOSITO:
gold.load_fact_pagos / gold.load_fact_facturas (MERGE incremental en sp_load_gold.sql)
solo mantienen mes actual + mes anterior, igual que silver.load_silver hace con bsad.
Este script trae el historico completo desde 2022-01-01 (mismo arranque que
silver.sap_bsad, confirmado via MIN(AUGDT) en el backfill original de bronze).

A DIFERENCIA de gold.fact_aplicacion_pagos (que se acoto a 2024+ porque su logica de
matching de 3 niveles era cara por fila), fact_pagos/fact_facturas son un simple filtro
+ INSERT sobre silver.sap_bsad (mismo costo por fila que el propio backfill de
silver.sap_bsad, que ya corrio en 5 chunks anuales sin problema) - no hay razon
computacional para acotar el rango, y gold.vw_pago_factura_simple necesita el historico
completo de AMBAS tablas para contar candidatos por grupo de compensacion correctamente
(si faltara historia en una pero no en la otra, la cuenta de "num_pagos_candidatos" por
grupo quedaria mal para grupos con actividad fuera de la ventana parcial).

FILTRO debe_haber<>'S' en fact_pagos (agregado 2026-08-19, ver ddl_gold.sql seccion 6):
excluye la linea espejo/contrapartida que el documento "hijo" de una compensacion
siempre trae (mismo documento_id=documento_compensacion, mismo monto, mismo
sgtxt='Asignación Aut. Deposito' que el deposito real, pero debe_haber='S') - sin este
filtro se contaba como un segundo pago virgen candidato, inflando falsamente la
ambiguedad en gold.vw_pago_factura_simple.

LIMITE SUPERIOR:
Igual que backfill_bsad_historico.sql: el limite se calcula dinamicamente (primer dia
del mes anterior a hoy) para no pisar la ventana que ya mantiene el incremental diario.

PATRON DE CHUNKS: un chunk por año, DELETE + INSERT (idempotente). Si algun año truena
con "Msg 9002: transaction log full", partir ese año en semestres/trimestres, mismo
metodo que backfill_bsad_historico.sql. No correr dos chunks a la vez en pestañas
distintas - uno por uno, revisando el PRINT antes de seguir.
========================================================================================
*/

DECLARE @limite_check DATE = DATEADD(MONTH, DATEDIFF(MONTH, 0, GETDATE()) - 1, 0);
SELECT @limite_check AS limite_superior_backfill_fecha_compensacion;
GO

-- ========================================================================================
-- 2022 completo
-- ========================================================================================
DELETE FROM gold.fact_pagos
WHERE fecha_compensacion >= '20220101' AND fecha_compensacion < '20230101';

INSERT INTO gold.fact_pagos (
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

PRINT 'fact_pagos - filas insertadas 2022: ' + CAST(@@ROWCOUNT AS VARCHAR);

DELETE FROM gold.fact_facturas
WHERE fecha_compensacion >= '20220101' AND fecha_compensacion < '20230101';

INSERT INTO gold.fact_facturas (
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

PRINT 'fact_facturas - filas insertadas 2022: ' + CAST(@@ROWCOUNT AS VARCHAR);
GO

-- ========================================================================================
-- 2023 completo
-- ========================================================================================
DELETE FROM gold.fact_pagos
WHERE fecha_compensacion >= '20230101' AND fecha_compensacion < '20240101';

INSERT INTO gold.fact_pagos (
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

PRINT 'fact_pagos - filas insertadas 2023: ' + CAST(@@ROWCOUNT AS VARCHAR);

DELETE FROM gold.fact_facturas
WHERE fecha_compensacion >= '20230101' AND fecha_compensacion < '20240101';

INSERT INTO gold.fact_facturas (
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

PRINT 'fact_facturas - filas insertadas 2023: ' + CAST(@@ROWCOUNT AS VARCHAR);
GO

-- ========================================================================================
-- 2024 completo
-- ========================================================================================
DELETE FROM gold.fact_pagos
WHERE fecha_compensacion >= '20240101' AND fecha_compensacion < '20250101';

INSERT INTO gold.fact_pagos (
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

PRINT 'fact_pagos - filas insertadas 2024: ' + CAST(@@ROWCOUNT AS VARCHAR);

DELETE FROM gold.fact_facturas
WHERE fecha_compensacion >= '20240101' AND fecha_compensacion < '20250101';

INSERT INTO gold.fact_facturas (
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

PRINT 'fact_facturas - filas insertadas 2024: ' + CAST(@@ROWCOUNT AS VARCHAR);
GO

-- ========================================================================================
-- 2025 completo
-- ========================================================================================
DELETE FROM gold.fact_pagos
WHERE fecha_compensacion >= '20250101' AND fecha_compensacion < '20260101';

INSERT INTO gold.fact_pagos (
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

PRINT 'fact_pagos - filas insertadas 2025: ' + CAST(@@ROWCOUNT AS VARCHAR);

DELETE FROM gold.fact_facturas
WHERE fecha_compensacion >= '20250101' AND fecha_compensacion < '20260101';

INSERT INTO gold.fact_facturas (
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

PRINT 'fact_facturas - filas insertadas 2025: ' + CAST(@@ROWCOUNT AS VARCHAR);
GO

-- ========================================================================================
-- 2026 parcial: desde el 1-ene hasta el limite que ya cubre el incremental
-- (limite dinamico - NO toca la ventana de 2 meses que mantienen load_fact_pagos/
-- load_fact_facturas)
-- ========================================================================================
DECLARE @limite_date DATE = DATEADD(MONTH, DATEDIFF(MONTH, 0, GETDATE()) - 1, 0);

DELETE FROM gold.fact_pagos
WHERE fecha_compensacion >= '20260101' AND fecha_compensacion < @limite_date;

INSERT INTO gold.fact_pagos (
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

PRINT 'fact_pagos - filas insertadas 2026 (parcial, hasta limite del incremental): ' + CAST(@@ROWCOUNT AS VARCHAR);

DELETE FROM gold.fact_facturas
WHERE fecha_compensacion >= '20260101' AND fecha_compensacion < @limite_date;

INSERT INTO gold.fact_facturas (
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

PRINT 'fact_facturas - filas insertadas 2026 (parcial, hasta limite del incremental): ' + CAST(@@ROWCOUNT AS VARCHAR);
GO

-- ========================================================================================
-- Verificacion final: total en gold vs. lo que hay en silver.sap_bsad antes del limite
-- del incremental (deberian coincidir exactamente si todos los chunks corrieron bien)
-- ========================================================================================
DECLARE @limite_final DATE = DATEADD(MONTH, DATEDIFF(MONTH, 0, GETDATE()) - 1, 0);

SELECT
    (SELECT COUNT(*) FROM silver.sap_bsad WHERE clase_documento = 'DZ' AND sgtxt = 'Asignación Aut. Deposito' AND debe_haber <> 'S' AND monto_moneda_local > 0 AND fecha_compensacion < @limite_final) AS pagos_silver_antes_del_limite,
    (SELECT COUNT(*) FROM gold.fact_pagos WHERE fecha_compensacion < @limite_final) AS pagos_gold_antes_del_limite,
    (SELECT COUNT(*) FROM silver.sap_bsad WHERE clase_documento IN ('F1','F2','F3','F4','F5','F6') AND fecha_compensacion < @limite_final) AS facturas_silver_antes_del_limite,
    (SELECT COUNT(*) FROM gold.fact_facturas WHERE fecha_compensacion < @limite_final) AS facturas_gold_antes_del_limite;
GO
