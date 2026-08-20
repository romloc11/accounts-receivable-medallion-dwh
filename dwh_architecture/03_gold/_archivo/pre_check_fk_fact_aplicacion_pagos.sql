USE ANALISIS_DATOS;
GO

-- Antes de agregar FK a gold.fact_aplicacion_pagos: verificar contra TODO
-- silver.sap_bsad (no solo el rango de prueba jun-jul 2026), porque el
-- backfill historico (2022 en adelante) todavia no se ha hecho - si hay un
-- valor sucio en el historico completo, agregar el FK ahora "pasaria" (solo
-- 2 meses limpios cargados) y reventaria despues al backfillear. Ya paso
-- una vez en este proyecto con fecha_vencimiento (ZFBDT corrupto,
-- 2204-09-26) - mejor confirmar antes que despues.

-- 1. fecha_compensacion fuera del rango de gold.dim_fecha (2020-01-01 a 2035-12-31)
SELECT 'fecha_compensacion fuera de rango' AS chequeo, COUNT(*) AS num_filas,
       MIN(fecha_compensacion) AS min_fecha, MAX(fecha_compensacion) AS max_fecha
FROM silver.sap_bsad
WHERE fecha_compensacion IS NOT NULL
  AND (fecha_compensacion < '20200101' OR fecha_compensacion > '20351231');

-- 2. cliente_id en bsad que NO existe en silver.sap_kna1 (romperia el FK a dim_cliente)
SELECT 'cliente_id sin kna1' AS chequeo, COUNT(DISTINCT b.cliente_id) AS num_clientes_distintos
FROM silver.sap_bsad b
WHERE NOT EXISTS (SELECT 1 FROM silver.sap_kna1 k WHERE k.cliente_id = b.cliente_id);
GO
