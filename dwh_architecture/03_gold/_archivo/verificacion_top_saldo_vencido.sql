USE ANALISIS_DATOS;
GO

-- El top de saldo_vencido de gold.fact_saldo_cartera trae montos y cliente_id
-- que parecen cuentas genericas/tecnicas (mostrador, pasarelas de pago,
-- aseguradoras netadas, caja chica - ver caracterizacion previa del gap
-- id_cliente_credito en fact_aplicacion_pagos). Cruzamos con dim_cliente para
-- confirmar tipo_cliente/nombre/rfc antes de tratar este top como "clientes
-- reales con mas riesgo de cobranza".
SELECT TOP 20
    s.cliente_id, s.saldo_total, s.saldo_vencido, s.dias_vencido_max,
    c.nombre, c.tipo_cliente, c.rfc
FROM gold.fact_saldo_cartera s
LEFT JOIN gold.dim_cliente c ON c.cliente_id = s.cliente_id
ORDER BY s.saldo_vencido DESC;
GO
