SELECT TOP 10
    cliente_id,
    nombre,
    rfc,
    canal_distribucion,
    COUNT(*)                                                                          AS total_facturas_compensadas,
    SUM(CASE WHEN clasificacion_vencimiento = 'YA_VENCIDA' THEN 1 ELSE 0 END)         AS facturas_compensadas_ya_vencidas,
    SUM(CASE WHEN clasificacion_vencimiento = 'VENCE_MISMO_MES' THEN 1 ELSE 0 END)    AS facturas_compensadas_vence_mismo_mes,
    SUM(CASE WHEN clasificacion_vencimiento = 'VENCE_MESES_FUTUROS' THEN 1 ELSE 0 END) AS facturas_compensadas_vence_futuro,

    SUM(monto_moneda_local)                                                            AS monto_total_compensado,
    SUM(CASE WHEN clasificacion_vencimiento = 'YA_VENCIDA' THEN monto_moneda_local ELSE 0 END)          AS monto_compensado_ya_vencido,
    SUM(CASE WHEN clasificacion_vencimiento = 'VENCE_MISMO_MES' THEN monto_moneda_local ELSE 0 END)     AS monto_compensado_vence_mismo_mes,
    SUM(CASE WHEN clasificacion_vencimiento = 'VENCE_MESES_FUTUROS' THEN monto_moneda_local ELSE 0 END) AS monto_compensado_vence_futuro,

    CAST(100.0 * SUM(CASE WHEN clasificacion_vencimiento = 'YA_VENCIDA' THEN 1 ELSE 0 END) / COUNT(*) AS DECIMAL(5,2)) AS pct_facturas_compensadas_ya_vencidas,
    CAST(100.0 * SUM(CASE WHEN clasificacion_vencimiento = 'VENCE_MISMO_MES' THEN 1 ELSE 0 END) / COUNT(*) AS DECIMAL(5,2)) AS pct_facturas_compensadas_vence_mismo_mes,
    CAST(100.0 * SUM(CASE WHEN clasificacion_vencimiento = 'VENCE_MESES_FUTUROS' THEN 1 ELSE 0 END) / COUNT(*) AS DECIMAL(5,2)) AS pct_facturas_compensadas_vence_futuro,

    CAST(100.0 * SUM(CASE WHEN clasificacion_vencimiento = 'YA_VENCIDA' THEN monto_moneda_local ELSE 0 END) / SUM(monto_moneda_local) AS DECIMAL(5,2)) AS pct_monto_compensado_ya_vencido,
    CAST(100.0 * SUM(CASE WHEN clasificacion_vencimiento = 'VENCE_MISMO_MES' THEN monto_moneda_local ELSE 0 END) / SUM(monto_moneda_local) AS DECIMAL(5,2)) AS pct_monto_compensado_vence_mismo_mes,
    CAST(100.0 * SUM(CASE WHEN clasificacion_vencimiento = 'VENCE_MESES_FUTUROS' THEN monto_moneda_local ELSE 0 END) / SUM(monto_moneda_local) AS DECIMAL(5,2)) AS pct_monto_compensado_vence_futuro,
    CAST(SUM(dias_pago * monto_moneda_local) / NULLIF(SUM(monto_moneda_local), 0) AS DECIMAL(9,2)) AS dpp_ponderado
FROM gold.vw_clasificacion_vencimiento_pago
WHERE fecha_compensacion BETWEEN '2026-07-01' AND '2026-07-31'
  AND cliente_id = 10000018
GROUP BY cliente_id, nombre, rfc, canal_distribucion
ORDER BY total_facturas_compensadas DESC;

