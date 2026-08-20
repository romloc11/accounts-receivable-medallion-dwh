USE ANALISIS_DATOS;
GO

-- Siguientes 3 casos del top 15 de top_residuos_grandes_match_parcial.sql,
-- para confirmar si el patron "candidato del grupo ya consumido por REBZG
-- hacia OTRA factura fuera del grupo" (visto en 8501577332) se repite:
--   #2: cliente 40000099, factura 7503028017, grupo 8501586669, $4,958.60 sin explicar
--   #3: cliente 40000023,  factura 7502989669, grupo 8501563071, $4,200.00 sin explicar (solo $9.25 resuelto - caso raro)
--   #4: cliente 40000025,  factura 7502982567, grupo 8501560768, $3,600.00 sin explicar
SELECT
    'grupo 8501586669 (cliente 40000099)' AS caso,
    documento_id, posicion, ejercicio, clase_documento, debe_haber, sgtxt,
    monto_moneda_local, fecha_documento, fecha_compensacion,
    documento_compensacion, ejercicio_compensacion,
    factura_referencia_documento, factura_referencia_ejercicio, factura_referencia_posicion
FROM silver.sap_bsad
WHERE sociedad = '2000' AND cliente_id = '40000099'
  AND documento_compensacion = '8501586669' AND ejercicio_compensacion = 2026

UNION ALL

SELECT
    'grupo 8501563071 (cliente 40000023)' AS caso,
    documento_id, posicion, ejercicio, clase_documento, debe_haber, sgtxt,
    monto_moneda_local, fecha_documento, fecha_compensacion,
    documento_compensacion, ejercicio_compensacion,
    factura_referencia_documento, factura_referencia_ejercicio, factura_referencia_posicion
FROM silver.sap_bsad
WHERE sociedad = '2000' AND cliente_id = '40000023'
  AND documento_compensacion = '8501563071' AND ejercicio_compensacion = 2026

UNION ALL

SELECT
    'grupo 8501560768 (cliente 40000025)' AS caso,
    documento_id, posicion, ejercicio, clase_documento, debe_haber, sgtxt,
    monto_moneda_local, fecha_documento, fecha_compensacion,
    documento_compensacion, ejercicio_compensacion,
    factura_referencia_documento, factura_referencia_ejercicio, factura_referencia_posicion
FROM silver.sap_bsad
WHERE sociedad = '2000' AND cliente_id = '40000025'
  AND documento_compensacion = '8501560768' AND ejercicio_compensacion = 2026

ORDER BY caso, posicion;
GO
