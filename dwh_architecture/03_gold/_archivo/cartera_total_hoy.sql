USE ANALISIS_DATOS;
GO

-- Cartera total del snapshot mas reciente, filtrado a clientes reales
-- (canal 10/20/40/60, excluye estatus_comercial='LEGAL'). Ya no hace falta
-- recalcular signo/SA/periodo de gracia a mano - gold.fact_saldo_cartera ya
-- los aplica desde el rediseño 2026-08-18 (ver ddl_gold.sql).
SELECT
    s.fecha_snapshot,
    COUNT(*) AS num_clientes_con_saldo,
    SUM(s.saldo_total) AS cartera_total,
    SUM(s.saldo_no_vencido) AS cartera_no_vencida,
    SUM(s.saldo_1_16) AS cartera_periodo_gracia,
    SUM(s.saldo_vencido) AS cartera_vencida_real,
    CAST(100.0 * SUM(s.saldo_vencido) / NULLIF(SUM(s.saldo_total), 0) AS DECIMAL(5,2)) AS pct_vencido_real
FROM gold.fact_saldo_cartera s
JOIN gold.dim_cliente_comercial dc
    ON dc.id_surrogate = s.id_cliente_comercial
   AND dc.canal_distribucion IN ('10','20','40','60')
   AND dc.estatus_comercial <> 'LEGAL'
WHERE s.fecha_snapshot = (SELECT MAX(fecha_snapshot) FROM gold.fact_saldo_cartera)
GROUP BY s.fecha_snapshot;
GO
