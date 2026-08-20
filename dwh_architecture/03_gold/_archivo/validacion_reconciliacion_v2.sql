USE ANALISIS_DATOS;
GO

-- Reconciliacion correcta: 1 fila por FACTURA UNICA (no por fila del fact,
-- que puede tener varias filas por factura si tiene mas de una aplicacion)
;WITH factura_unica AS (
    SELECT
        sociedad, cliente_id, documento_compensacion, ejercicio_compensacion,
        documento_factura, ejercicio_factura, posicion_factura,
        MAX(monto_factura) AS monto_factura,  -- es el mismo valor en todas sus filas, MAX solo para colapsar
        MAX(CASE WHEN tipo_aplicacion IS NOT NULL THEN 1 ELSE 0 END) AS tiene_algun_match
    FROM gold.fact_aplicacion_pagos
    GROUP BY sociedad, cliente_id, documento_compensacion, ejercicio_compensacion,
             documento_factura, ejercicio_factura, posicion_factura
)
SELECT TOP 20
    documento_compensacion, ejercicio_compensacion,
    COUNT(*) AS num_facturas,
    SUM(CASE WHEN tiene_algun_match = 0 THEN 1 ELSE 0 END) AS num_facturas_sin_match,
    SUM(monto_factura) AS total_facturado,
    SUM(CASE WHEN tiene_algun_match = 0 THEN monto_factura ELSE 0 END) AS monto_sin_match
FROM factura_unica
WHERE documento_compensacion IS NOT NULL
GROUP BY documento_compensacion, ejercicio_compensacion
HAVING SUM(CASE WHEN tiene_algun_match = 0 THEN monto_factura ELSE 0 END) > 1
ORDER BY monto_sin_match DESC;
GO
