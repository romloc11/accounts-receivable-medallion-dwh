USE ANALISIS_DATOS;
GO

-- % del portafolio de facturas (2024-hoy) conciliado con certeza
-- (tipo_aplicacion IS NOT NULL) vs. sin conciliar (residuo Nivel 3),
-- en monto Y en numero de facturas - el % en dinero puede ocultar que
-- muchas facturas chicas quedan sin conciliar aunque representen poco dinero.
;WITH por_factura AS (
    SELECT sociedad, cliente_id, documento_factura, ejercicio_factura, posicion_factura,
           MAX(monto_factura) AS monto_factura,
           SUM(CASE WHEN tipo_aplicacion IS NOT NULL THEN monto_aplicado ELSE 0 END) AS monto_resuelto
    FROM gold.fact_aplicacion_pagos
    GROUP BY sociedad, cliente_id, documento_factura, ejercicio_factura, posicion_factura
),
con_saldo AS (
    SELECT *,
        CASE WHEN monto_factura - monto_resuelto > 0 THEN monto_factura - monto_resuelto ELSE 0 END AS saldo_sin_conciliar
    FROM por_factura
)
SELECT
    COUNT(*) AS total_facturas,
    SUM(CASE WHEN saldo_sin_conciliar <= 0.01 THEN 1 ELSE 0 END) AS facturas_totalmente_conciliadas,
    SUM(CASE WHEN saldo_sin_conciliar > 0.01 AND monto_resuelto > 0 THEN 1 ELSE 0 END) AS facturas_parcialmente_conciliadas,
    SUM(CASE WHEN monto_resuelto = 0 THEN 1 ELSE 0 END) AS facturas_sin_ninguna_conciliacion,
    CAST(100.0 * SUM(CASE WHEN saldo_sin_conciliar <= 0.01 THEN 1 ELSE 0 END) / COUNT(*) AS DECIMAL(5,2)) AS pct_facturas_conciliadas,
    SUM(monto_factura) AS monto_total_facturado,
    SUM(monto_factura - saldo_sin_conciliar) AS monto_total_conciliado,
    SUM(saldo_sin_conciliar) AS monto_total_sin_conciliar,
    CAST(100.0 * SUM(monto_factura - saldo_sin_conciliar) / NULLIF(SUM(monto_factura), 0) AS DECIMAL(5,2)) AS pct_monto_conciliado,
    CAST(100.0 * SUM(saldo_sin_conciliar) / NULLIF(SUM(monto_factura), 0) AS DECIMAL(5,2)) AS pct_monto_sin_conciliar
FROM con_saldo;
GO
