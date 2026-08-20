USE ANALISIS_DATOS;
GO

-- Sin el filtro "tipo_aplicacion IS NULL" - para ver TODAS las filas que el
-- fact genero para esta factura, no solo el residuo. Hipotesis: hay una fila
-- resuelta via REBZG (~$5,462.28, el DZ) y una fila NULL aparte por los
-- $0.44 restantes (explicados por los 2 AB del grupo, que son ambiguos entre
-- si - ninguno tiene REBZG que los distinga).
SELECT
    documento_factura, tipo_aplicacion, documento_aplicado, clase_documento_aplicado,
    monto_aplicado, metodo_match, monto_factura,
    monto_factura - ISNULL((
        SELECT SUM(f2.monto_aplicado) FROM gold.fact_aplicacion_pagos f2
        WHERE f2.documento_factura = f.documento_factura AND f2.ejercicio_factura = f.ejercicio_factura
          AND f2.posicion_factura = f.posicion_factura AND f2.tipo_aplicacion IS NOT NULL
    ), 0) AS saldo_pendiente_total
FROM gold.fact_aplicacion_pagos f
WHERE cliente_id = '10000876'
  AND documento_factura IN ('7404602049','7404602326','7404611650','7404612130')
ORDER BY documento_factura, tipo_aplicacion;
GO
