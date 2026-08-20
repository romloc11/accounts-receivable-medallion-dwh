USE ANALISIS_DATOS;
GO

SELECT
    clase_documento_aplicado,
    COUNT(*) AS filas,
    SUM(CASE WHEN documento_pago_virgen IS NOT NULL THEN 1 ELSE 0 END) AS con_virgen,
    SUM(CASE WHEN documento_pago_virgen IS NULL THEN 1 ELSE 0 END) AS sin_virgen
FROM gold.fact_aplicacion_pagos
WHERE tipo_aplicacion = 'PAGO'
GROUP BY clase_documento_aplicado
ORDER BY filas DESC;
GO
