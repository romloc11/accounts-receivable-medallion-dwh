USE ANALISIS_DATOS;
GO

SELECT clase_documento, debe_haber, COUNT(*) AS num_lineas, SUM(monto_moneda_local) AS suma_monto
FROM silver.sap_bsad
WHERE sociedad = '2000' AND documento_compensacion = '1402594389' AND ejercicio_compensacion = 2026
GROUP BY clase_documento, debe_haber
ORDER BY clase_documento;
GO

-- muestra de 5 facturas de ese grupo para ver si tienen REBZG poblado o no
SELECT TOP 5 documento_id, clase_documento, monto_moneda_local, factura_referencia_documento
FROM silver.sap_bsad
WHERE sociedad = '2000' AND documento_compensacion = '1402594389' AND ejercicio_compensacion = 2026
  AND clase_documento IN ('F1','F2','F3','F4','F5','F6');
GO
