USE ANALISIS_DATOS;
GO

SELECT
    documento_id, posicion, clase_documento, debe_haber, sgtxt,
    monto_moneda_local, documento_compensacion, ejercicio_compensacion,
    factura_referencia_documento, factura_referencia_ejercicio, factura_referencia_posicion
FROM silver.sap_bsad
WHERE (sociedad = '2000' AND documento_compensacion = '1402590156' AND ejercicio_compensacion = 2026)
   OR (sociedad = '2000' AND documento_compensacion = '1402634982' AND ejercicio_compensacion = 2026)
   OR (sociedad = '2000' AND documento_compensacion = '1402634811' AND ejercicio_compensacion = 2026)
ORDER BY documento_compensacion, documento_id, posicion;
GO
