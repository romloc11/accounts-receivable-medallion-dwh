USE ANALISIS_DATOS;
GO

-- Separa las facturas "sin match" en dos grupos: las que NUNCA tuvieron
-- ningun match (0 filas resueltas) vs las que tienen match parcial (1+ filas
-- resueltas) pero todavia les falta explicar una parte
;WITH resuelto AS (
    SELECT sociedad, cliente_id, documento_factura, ejercicio_factura, posicion_factura,
           SUM(monto_aplicado) AS monto_resuelto, COUNT(*) AS num_filas_resueltas
    FROM gold.fact_aplicacion_pagos
    WHERE tipo_aplicacion IS NOT NULL
    GROUP BY sociedad, cliente_id, documento_factura, ejercicio_factura, posicion_factura
),
sin_match AS (
    SELECT f.*, r.monto_resuelto, r.num_filas_resueltas
    FROM gold.fact_aplicacion_pagos f
    LEFT JOIN resuelto r
        ON r.sociedad = f.sociedad AND r.cliente_id = f.cliente_id
       AND r.documento_factura = f.documento_factura AND r.ejercicio_factura = f.ejercicio_factura
       AND r.posicion_factura = f.posicion_factura
    WHERE f.tipo_aplicacion IS NULL
)
SELECT
    CASE WHEN monto_resuelto IS NULL THEN 'Nunca tuvo match (0 filas)' ELSE 'Match parcial - le falta explicar el resto' END AS categoria,
    COUNT(*) AS num_facturas,
    SUM(monto_factura) AS monto_total_factura,
    SUM(ISNULL(monto_resuelto, 0)) AS monto_ya_resuelto,
    SUM(monto_factura - ISNULL(monto_resuelto, 0)) AS monto_sin_explicar
FROM sin_match
GROUP BY CASE WHEN monto_resuelto IS NULL THEN 'Nunca tuvo match (0 filas)' ELSE 'Match parcial - le falta explicar el resto' END;
GO
