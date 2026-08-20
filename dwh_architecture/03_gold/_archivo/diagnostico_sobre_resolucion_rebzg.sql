USE ANALISIS_DATOS;
GO

-- Ejemplo real de sobre-resolucion SOLO via REBZG (el bucket que no se movio
-- con el fix de #virgen) - trae el detalle completo de la fact Y de las
-- lineas crudas de silver.sap_bsad involucradas, para ver si son REBZG
-- legitimamente distintos (varias notas de credito parciales reales que
-- entre todas suman mas que la factura - posible inconsistencia real de SAP,
-- no bug nuestro) o si hay duplicados de alguna otra forma.
;WITH sobre_resueltas_rebzg_solo AS (
    SELECT sociedad, cliente_id, documento_factura, ejercicio_factura, posicion_factura
    FROM gold.fact_aplicacion_pagos
    WHERE tipo_aplicacion IS NOT NULL
    GROUP BY sociedad, cliente_id, documento_factura, ejercicio_factura, posicion_factura, monto_factura
    HAVING SUM(monto_aplicado) > monto_factura + 1.00
       AND COUNT(DISTINCT metodo_match) = 1
       AND MIN(metodo_match) = 'REBZG'
)
SELECT TOP 1 * INTO #ejemplo FROM sobre_resueltas_rebzg_solo;

SELECT f.*
FROM gold.fact_aplicacion_pagos f
JOIN #ejemplo e
    ON e.sociedad = f.sociedad AND e.cliente_id = f.cliente_id
   AND e.documento_factura = f.documento_factura AND e.ejercicio_factura = f.ejercicio_factura
   AND e.posicion_factura = f.posicion_factura
ORDER BY f.documento_aplicado, f.posicion_aplicado;

-- Lineas crudas de silver.sap_bsad de los documentos aplicados, para
-- confirmar si son documentos REALMENTE distintos o el mismo documento
-- repetido
SELECT b.documento_id, b.posicion, b.ejercicio, b.clase_documento, b.debe_haber,
       b.monto_moneda_local, b.documento_compensacion, b.ejercicio_compensacion,
       b.factura_referencia_documento, b.factura_referencia_ejercicio, b.factura_referencia_posicion
FROM silver.sap_bsad b
JOIN gold.fact_aplicacion_pagos f
    ON f.documento_aplicado = b.documento_id AND f.posicion_aplicado = b.posicion
   AND f.cliente_id = b.cliente_id AND f.sociedad = b.sociedad
JOIN #ejemplo e
    ON e.sociedad = f.sociedad AND e.cliente_id = f.cliente_id
   AND e.documento_factura = f.documento_factura AND e.ejercicio_factura = f.ejercicio_factura
   AND e.posicion_factura = f.posicion_factura
ORDER BY b.documento_id, b.posicion;

DROP TABLE #ejemplo;
GO
