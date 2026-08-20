USE ANALISIS_DATOS;
GO

SELECT
    documento_id, posicion, clase_documento, debe_haber, sgtxt,
    monto_moneda_local, documento_compensacion, ejercicio_compensacion,
    factura_referencia_documento
FROM silver.sap_bsad
WHERE sociedad = '2000' AND documento_compensacion = '1402633560' AND ejercicio_compensacion = 2026
ORDER BY clase_documento, documento_id, posicion;
GO

-- Resumen: cuantas lineas de cada tipo hay en este grupo
SELECT clase_documento, debe_haber, COUNT(*) AS num_lineas, SUM(monto_moneda_local) AS suma_monto
FROM silver.sap_bsad
WHERE sociedad = '2000' AND documento_compensacion = '1402633560' AND ejercicio_compensacion = 2026
GROUP BY clase_documento, debe_haber
ORDER BY clase_documento;
GO
