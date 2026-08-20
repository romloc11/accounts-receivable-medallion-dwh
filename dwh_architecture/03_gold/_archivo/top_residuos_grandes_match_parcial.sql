USE ANALISIS_DATOS;
GO

-- Top facturas del bucket ">$1,000" de distribucion_residuo_match_parcial.sql
-- (262 facturas, $465,177.01) - para ver si es el mismo patron ya conocido
-- (grupo batch grande, 2+ candidatos reales sin REBZG) o algo nuevo que
-- valga la pena investigar a fondo.

DECLARE @fecha_inicio DATE = '20260601';
DECLARE @fecha_fin    DATE = '20260731';
DECLARE @top_n INT = 15;

;WITH resuelto AS (
    SELECT sociedad, cliente_id, documento_factura, ejercicio_factura, posicion_factura,
           SUM(monto_aplicado) AS monto_resuelto
    FROM gold.fact_aplicacion_pagos
    WHERE fecha_compensacion BETWEEN @fecha_inicio AND @fecha_fin AND tipo_aplicacion IS NOT NULL
    GROUP BY sociedad, cliente_id, documento_factura, ejercicio_factura, posicion_factura
)
SELECT TOP (@top_n)
    f.cliente_id, f.documento_factura, f.documento_compensacion, f.ejercicio_compensacion,
    f.monto_factura, r.monto_resuelto, f.monto_factura - r.monto_resuelto AS monto_sin_explicar
FROM gold.fact_aplicacion_pagos f
JOIN resuelto r
    ON r.sociedad = f.sociedad AND r.cliente_id = f.cliente_id
   AND r.documento_factura = f.documento_factura AND r.ejercicio_factura = f.ejercicio_factura
   AND r.posicion_factura = f.posicion_factura
WHERE f.tipo_aplicacion IS NULL
  AND f.monto_factura - r.monto_resuelto > 1000
ORDER BY (f.monto_factura - r.monto_resuelto) DESC;
GO
