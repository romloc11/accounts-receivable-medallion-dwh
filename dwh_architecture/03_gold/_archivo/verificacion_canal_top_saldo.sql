USE ANALISIS_DATOS;
GO

-- Canal (10=mayoreo/20=menudeo/40/60) y estatus comercial de los clientes del
-- top de saldo_vencido, para ver si los mas grandes son mayoreo, menudeo, o
-- las cuentas tecnicas/genericas ya identificadas (Mercado Libre, KUSHKY, etc.)
SELECT
    s.cliente_id, s.saldo_total, s.saldo_vencido, s.dias_vencido_max,
    c.nombre, c.tipo_cliente,
    dc.canal_distribucion, dc.estatus_comercial, dc.ruta_nombre
FROM gold.fact_saldo_cartera s
LEFT JOIN gold.dim_cliente c ON c.cliente_id = s.cliente_id
LEFT JOIN gold.dim_cliente_comercial dc ON dc.cliente_id = s.cliente_id AND dc.es_vigente = 1
ORDER BY s.saldo_vencido DESC
OFFSET 0 ROWS FETCH NEXT 20 ROWS ONLY;
GO
