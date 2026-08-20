USE ANALISIS_DATOS;
GO

-- 1. Las 114,660 facturas sin match: por tipo de factura
SELECT tipo_factura, COUNT(*) AS num_facturas, SUM(monto_factura) AS monto_total
FROM gold.fact_aplicacion_pagos
WHERE tipo_aplicacion IS NULL
GROUP BY tipo_factura
ORDER BY num_facturas DESC;
GO

-- 2. Tamaño del grupo de compensacion al que pertenecen (cuantas facturas +
-- cuantas aplicaciones de CUALQUIER tipo hay en ese mismo grupo) - confirma si
-- son lotes grandes ambiguos o algo mas simple que se nos esta escapando
;WITH sin_match AS (
    SELECT DISTINCT sociedad, cliente_id, documento_compensacion, ejercicio_compensacion
    FROM gold.fact_aplicacion_pagos
    WHERE tipo_aplicacion IS NULL
      AND documento_compensacion IS NOT NULL
),
tam_grupo AS (
    SELECT
        sm.sociedad, sm.cliente_id, sm.documento_compensacion, sm.ejercicio_compensacion,
        (SELECT COUNT(*) FROM silver.sap_bsad b
         WHERE b.sociedad = sm.sociedad AND b.cliente_id = sm.cliente_id
           AND b.documento_compensacion = sm.documento_compensacion AND b.ejercicio_compensacion = sm.ejercicio_compensacion
           AND b.clase_documento IN ('F1','F2','F3','F4','F5','F6')) AS num_facturas_en_grupo,
        (SELECT COUNT(*) FROM silver.sap_bsad b
         WHERE b.sociedad = sm.sociedad AND b.cliente_id = sm.cliente_id
           AND b.documento_compensacion = sm.documento_compensacion AND b.ejercicio_compensacion = sm.ejercicio_compensacion
           AND b.clase_documento NOT IN ('F1','F2','F3','F4','F5','F6')) AS num_no_facturas_en_grupo
    FROM sin_match sm
)
SELECT
    num_facturas_en_grupo,
    num_no_facturas_en_grupo,
    COUNT(*) AS num_grupos
FROM tam_grupo
GROUP BY num_facturas_en_grupo, num_no_facturas_en_grupo
ORDER BY num_grupos DESC;
GO

-- 3. Cinco ejemplos concretos de facturas sin match, con su fecha y monto,
-- para revisar a mano
SELECT TOP 5
    sociedad, cliente_id, documento_factura, fecha_factura, monto_factura,
    documento_compensacion, ejercicio_compensacion, fecha_compensacion
FROM gold.fact_aplicacion_pagos
WHERE tipo_aplicacion IS NULL
ORDER BY monto_factura DESC;
GO
