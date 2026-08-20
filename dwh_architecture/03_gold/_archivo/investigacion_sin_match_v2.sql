USE ANALISIS_DATOS;
GO

-- 1. Las facturas sin match (post-fix): por tipo de factura
SELECT tipo_factura, COUNT(*) AS num_facturas, SUM(monto_factura) AS monto_total
FROM gold.fact_aplicacion_pagos
WHERE tipo_aplicacion IS NULL
GROUP BY tipo_factura
ORDER BY num_facturas DESC;
GO

-- 2. Tamaño real del grupo de compensacion (facturas + aplicaciones POR
-- CATEGORIA) para las facturas sin match - para ver si el patron sigue siendo
-- "lotes grandes ambiguos" o hay algo especifico de AJUSTE
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
           AND b.clase_documento = 'AB') AS num_ajuste_en_grupo,
        (SELECT COUNT(*) FROM silver.sap_bsad b
         WHERE b.sociedad = sm.sociedad AND b.cliente_id = sm.cliente_id
           AND b.documento_compensacion = sm.documento_compensacion AND b.ejercicio_compensacion = sm.ejercicio_compensacion
           AND b.clase_documento IN ('DZ','CP','ZY')) AS num_pago_en_grupo
    FROM sin_match sm
)
SELECT num_facturas_en_grupo, num_ajuste_en_grupo, num_pago_en_grupo, COUNT(*) AS num_grupos
FROM tam_grupo
GROUP BY num_facturas_en_grupo, num_ajuste_en_grupo, num_pago_en_grupo
ORDER BY num_grupos DESC;
GO

-- 3. Ejemplo concreto: una factura sin match cuyo grupo tiene AB (ajuste) para
-- revisar en SAP
SELECT TOP 3
    f.sociedad, f.cliente_id, f.documento_factura, f.fecha_factura, f.monto_factura,
    f.documento_compensacion, f.ejercicio_compensacion
FROM gold.fact_aplicacion_pagos f
WHERE f.tipo_aplicacion IS NULL
  AND EXISTS (
      SELECT 1 FROM silver.sap_bsad b
      WHERE b.sociedad = f.sociedad AND b.cliente_id = f.cliente_id
        AND b.documento_compensacion = f.documento_compensacion AND b.ejercicio_compensacion = f.ejercicio_compensacion
        AND b.clase_documento = 'AB'
  )
ORDER BY f.monto_factura DESC;
GO
