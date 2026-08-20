USE ANALISIS_DATOS;
GO

-- Caso reportado por el usuario: cliente 10000876, 4 facturas F4 cada una en
-- su propio grupo de compensacion individual (8501568949/950/951/952),
-- ninguna resuelta por el fact aunque cada grupo tiene un DZ que aparenta
-- traer REBZG directo a la factura. Columnas explicitas (sin adivinar del
-- grid de SSMS) para ver exactamente por que el Nivel 1 no la tomo:
-- candidatos posibles - debe_haber del DZ = 'S' (excluido por el filtro
-- actual), o un mismatch en factura_referencia_ejercicio/posicion.
SELECT
    documento_id, posicion, ejercicio, clase_documento, debe_haber, sgtxt,
    monto_moneda_local, fecha_documento, fecha_compensacion,
    documento_compensacion, ejercicio_compensacion,
    factura_referencia_documento, factura_referencia_ejercicio, factura_referencia_posicion
FROM silver.sap_bsad
WHERE sociedad = '2000' AND cliente_id = '10000876'
  AND documento_compensacion IN ('8501568949','8501568950','8501568951','8501568952')
  AND ejercicio_compensacion = 2026
ORDER BY documento_compensacion, posicion;
GO
