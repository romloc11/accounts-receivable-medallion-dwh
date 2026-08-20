USE ANALISIS_DATOS;
GO

SELECT documento_id, fecha_documento, dias_plazo, fecha_vencimiento
FROM silver.sap_bsad
WHERE cliente_id = '10019405' AND documento_id = '7404726976';
GO
