USE ANALISIS_DATOS;
GO

-- ¿silver.sap_bsid trae partidas de credito (notas de credito/saldos a favor
-- sin aplicar) mezcladas con las de debito (facturas), y monto_moneda_local
-- viene SIN signo (siempre positivo, con debe_haber indicando la direccion
-- aparte)? Si es asi, SUM(monto_moneda_local) sin usar debe_haber esta
-- sumando notas de credito como si fueran deuda en vez de restarlas.
SELECT
    debe_haber,
    clase_documento,
    COUNT(*) AS num_filas,
    SUM(monto_moneda_local) AS monto_total,
    MIN(monto_moneda_local) AS monto_min,
    MAX(monto_moneda_local) AS monto_max
FROM silver.sap_bsid
GROUP BY debe_haber, clase_documento
ORDER BY debe_haber, num_filas DESC;
GO
