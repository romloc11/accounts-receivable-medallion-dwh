USE ANALISIS_DATOS;
GO

-- 1. Sin match (post-fix propia/externa): por tipo de factura
SELECT tipo_factura, COUNT(*) AS num_facturas, SUM(monto_factura) AS monto_total
FROM gold.fact_aplicacion_pagos
WHERE tipo_aplicacion IS NULL
GROUP BY tipo_factura
ORDER BY num_facturas DESC;
GO

-- 2. Composicion de los grupos sin match: cuantas facturas + cuantas
-- "propias"/"externas" de cada categoria hay en el grupo (para ver si el
-- patron que queda es "grupo con 2+ propias" - genuina ambiguedad multi-pago -
-- o algo mas por investigar)
;WITH sin_match AS (
    SELECT DISTINCT sociedad, cliente_id, documento_compensacion, ejercicio_compensacion
    FROM gold.fact_aplicacion_pagos
    WHERE tipo_aplicacion IS NULL AND documento_compensacion IS NOT NULL
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
           AND b.clase_documento IN ('DZ','CP','ZY')) AS num_pago_en_grupo,
        (SELECT COUNT(*) FROM silver.sap_bsad b
         WHERE b.sociedad = sm.sociedad AND b.cliente_id = sm.cliente_id
           AND b.documento_compensacion = sm.documento_compensacion AND b.ejercicio_compensacion = sm.ejercicio_compensacion
           AND b.clase_documento = 'AB') AS num_ajuste_en_grupo
    FROM sin_match sm
)
SELECT num_facturas_en_grupo, num_pago_en_grupo, num_ajuste_en_grupo, COUNT(*) AS num_grupos
FROM tam_grupo
GROUP BY num_facturas_en_grupo, num_pago_en_grupo, num_ajuste_en_grupo
ORDER BY num_grupos DESC;
GO

-- 3. Un ejemplo concreto de cada patron dominante para revisar
SELECT TOP 5
    sociedad, cliente_id, documento_factura, fecha_factura, monto_factura,
    documento_compensacion, ejercicio_compensacion
FROM gold.fact_aplicacion_pagos
WHERE tipo_aplicacion IS NULL
ORDER BY monto_factura DESC;
GO
