USE ANALISIS_DATOS;
GO

-- Top 1 del bucket ">$1,000" de distribucion_residuo_match_parcial.sql:
-- cliente 40000272, factura 7503011679, grupo 8501577332 - $10,786.01 sin
-- explicar de $12,318.60. Detalle completo del grupo para ver el patron.
SELECT
    documento_id, posicion, ejercicio, clase_documento, debe_haber, sgtxt,
    monto_moneda_local, fecha_documento, fecha_compensacion,
    documento_compensacion, ejercicio_compensacion,
    factura_referencia_documento, factura_referencia_ejercicio, factura_referencia_posicion
FROM silver.sap_bsad
WHERE sociedad = '2000' AND cliente_id = '40000272'
  AND documento_compensacion = '8501577332' AND ejercicio_compensacion = 2026
ORDER BY posicion;
GO
