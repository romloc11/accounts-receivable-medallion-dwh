USE ANALISIS_DATOS;
GO

-- Clientes con dpp_3m o dpp_12m negativo en fact_saldo_cartera - traer un
-- ejemplo y ver las filas PAGO individuales de fact_aplicacion_pagos que
-- component ese promedio, para saber si es un patron sistematico (anticipos
-- reales) o unos pocos casos raros arrastrando el promedio.
SELECT TOP 5 cliente_id, fecha_snapshot, dpp_3m, dpp_12m, dpp_ponderado_3m, dpp_ponderado_12m
FROM gold.fact_saldo_cartera
WHERE dpp_3m < 0 OR dpp_12m < 0
ORDER BY dpp_12m ASC;

-- Detalle de pagos individuales de un cliente con DPP negativo, para ver el
-- patron (reemplaza el cliente_id con uno real del resultado anterior si
-- quieres investigar otro)
;WITH ejemplo AS (
    SELECT TOP 1 cliente_id FROM gold.fact_saldo_cartera WHERE dpp_12m < 0 ORDER BY dpp_12m ASC
)
SELECT f.cliente_id, f.documento_factura, f.fecha_factura, f.fecha_pago,
       DATEDIFF(DAY, f.fecha_factura, f.fecha_pago) AS dias, f.monto_aplicado, f.metodo_match
FROM gold.fact_aplicacion_pagos f
JOIN ejemplo e ON e.cliente_id = f.cliente_id
WHERE f.tipo_aplicacion = 'PAGO' AND f.fecha_pago IS NOT NULL
ORDER BY f.fecha_pago;
GO
