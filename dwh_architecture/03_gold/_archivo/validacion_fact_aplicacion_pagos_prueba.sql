USE ANALISIS_DATOS;
GO

-- 1. Panorama general: filas, facturas distintas y metodo_match por tipo_aplicacion
SELECT
    tipo_aplicacion,
    metodo_match,
    COUNT(*) AS num_filas,
    COUNT(DISTINCT sociedad + '|' + cliente_id + '|' + CAST(ejercicio_factura AS VARCHAR) + '|' + documento_factura + '|' + CAST(posicion_factura AS VARCHAR)) AS facturas_distintas,
    SUM(monto_aplicado) AS suma_monto_aplicado
FROM gold.fact_aplicacion_pagos
GROUP BY tipo_aplicacion, metodo_match
ORDER BY tipo_aplicacion, metodo_match;
GO

-- 2. De las filas tipo_aplicacion='PAGO', cuantas encontraron su deposito virgen
SELECT
    COUNT(*) AS filas_pago,
    SUM(CASE WHEN documento_pago_virgen IS NOT NULL THEN 1 ELSE 0 END) AS con_virgen_encontrado,
    SUM(CASE WHEN documento_pago_virgen IS NULL THEN 1 ELSE 0 END) AS sin_virgen_encontrado
FROM gold.fact_aplicacion_pagos
WHERE tipo_aplicacion = 'PAGO';
GO

-- 3. Reconciliacion de montos por grupo de compensacion (ya NO deberia haber
-- diferencias gigantes tipo miles de millones)
SELECT TOP 20
    documento_compensacion, ejercicio_compensacion,
    SUM(monto_factura) AS suma_facturas,
    SUM(monto_aplicado) AS suma_aplicado,
    SUM(monto_factura) - SUM(ISNULL(monto_aplicado,0)) AS diferencia
FROM gold.fact_aplicacion_pagos
WHERE documento_compensacion IS NOT NULL
GROUP BY documento_compensacion, ejercicio_compensacion
HAVING ABS(SUM(monto_factura) - SUM(ISNULL(monto_aplicado,0))) > 1
ORDER BY ABS(SUM(monto_factura) - SUM(ISNULL(monto_aplicado,0))) DESC;
GO

-- 4. Total de PAGO: deberia ser un numero razonable ahora (no miles de millones)
SELECT SUM(monto_aplicado) AS total_pago_junio_julio
FROM gold.fact_aplicacion_pagos
WHERE tipo_aplicacion = 'PAGO';
GO
