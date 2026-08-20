USE ANALISIS_DATOS;
GO

-- Separa los 50,900 casos "id_cliente_comercial_fuera_de_su_vigencia" entre:
--   A) el cliente NO tiene otra fila en dim_cliente_comercial (posible dato
--      legitimamente nuevo, no bug)
--   B) el cliente SI tiene otra(s) fila(s), pero ninguna cubre la fecha de la
--      factura (hueco real de historia - bug de esta sesion)
DECLARE @fecha_inicio DATE = '20240101';
DECLARE @fecha_fin    DATE = CAST(GETDATE() AS DATE);

;WITH fuera_de_vigencia AS (
    SELECT DISTINCT f.cliente_id, f.fecha_compensacion
    FROM gold.fact_aplicacion_pagos f
    JOIN gold.dim_cliente_comercial dc ON dc.id_surrogate = f.id_cliente_comercial
    WHERE f.fecha_compensacion NOT BETWEEN dc.fecha_inicio_vigencia AND ISNULL(dc.fecha_fin_vigencia, '99991231')
),
clasificado AS (
    SELECT
        fv.cliente_id, fv.fecha_compensacion,
        CASE
            WHEN (SELECT COUNT(*) FROM gold.dim_cliente_comercial d2 WHERE d2.cliente_id = fv.cliente_id) = 1
                THEN 'A) cliente tiene 1 sola fila (posible dato nuevo legitimo)'
            WHEN EXISTS (
                SELECT 1 FROM gold.dim_cliente_comercial d3
                WHERE d3.cliente_id = fv.cliente_id
                  AND fv.fecha_compensacion BETWEEN d3.fecha_inicio_vigencia AND ISNULL(d3.fecha_fin_vigencia, '99991231')
            ) THEN 'C) SI existe una version que cubre la fecha (el join de la fact esta mal, no la dimension)'
            ELSE 'B) tiene 2+ filas pero NINGUNA cubre la fecha (hueco real de historia)'
        END AS causa
    FROM fuera_de_vigencia fv
)
SELECT causa, COUNT(*) AS num_casos
FROM clasificado
GROUP BY causa;
GO
