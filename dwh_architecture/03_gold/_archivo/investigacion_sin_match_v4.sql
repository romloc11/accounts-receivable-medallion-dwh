USE ANALISIS_DATOS;
GO

-- Desglose completo del residuo sin match: cuantos candidatos reales tenia el
-- grupo para PAGO (la categoria dominante), para ver si el patron es
-- consistentemente "2+ candidatos sin REBZG" (ambiguedad genuina) o hay algo mas
;WITH sin_match AS (
    SELECT DISTINCT sociedad, cliente_id, documento_compensacion, ejercicio_compensacion, monto_factura
    FROM gold.fact_aplicacion_pagos
    WHERE tipo_aplicacion IS NULL AND documento_compensacion IS NOT NULL
),
candidatos AS (
    SELECT
        sm.sociedad, sm.cliente_id, sm.documento_compensacion, sm.ejercicio_compensacion, sm.monto_factura,
        (SELECT COUNT(*) FROM silver.sap_bsad b
         WHERE b.sociedad = sm.sociedad AND b.cliente_id = sm.cliente_id
           AND b.documento_compensacion = sm.documento_compensacion AND b.ejercicio_compensacion = sm.ejercicio_compensacion
           AND b.clase_documento IN ('DZ','CP','ZY')
           AND NOT (b.clase_documento = 'DZ' AND b.debe_haber = 'S')) AS num_candidatos_pago,
        (SELECT COUNT(*) FROM silver.sap_bsad b
         WHERE b.sociedad = sm.sociedad AND b.cliente_id = sm.cliente_id
           AND b.documento_compensacion = sm.documento_compensacion AND b.ejercicio_compensacion = sm.ejercicio_compensacion
           AND b.clase_documento IN ('DZ','CP','ZY')
           AND NOT (b.clase_documento = 'DZ' AND b.debe_haber = 'S')
           AND b.factura_referencia_documento IS NOT NULL) AS num_candidatos_pago_con_rebzg,
        (SELECT COUNT(*) FROM silver.sap_bsad b
         WHERE b.sociedad = sm.sociedad AND b.cliente_id = sm.cliente_id
           AND b.documento_compensacion = sm.documento_compensacion AND b.ejercicio_compensacion = sm.ejercicio_compensacion
           AND b.clase_documento = 'SA') AS num_sa_en_grupo
    FROM sin_match sm
)
SELECT
    CASE
        WHEN num_candidatos_pago = 0 THEN '0 candidatos PAGO'
        WHEN num_candidatos_pago = 1 THEN '1 candidato (raro - deberia haber resuelto)'
        WHEN num_candidatos_pago >= 2 AND num_candidatos_pago_con_rebzg = num_candidatos_pago THEN '2+ candidatos, TODOS con REBZG (deberian resolver via REBZG)'
        WHEN num_candidatos_pago >= 2 THEN '2+ candidatos PAGO, ambiguo'
    END AS patron,
    SUM(CASE WHEN num_sa_en_grupo > 0 THEN 1 ELSE 0 END) AS de_estos_con_SA_tambien,
    COUNT(*) AS num_facturas,
    SUM(monto_factura) AS monto_total
FROM candidatos
GROUP BY
    CASE
        WHEN num_candidatos_pago = 0 THEN '0 candidatos PAGO'
        WHEN num_candidatos_pago = 1 THEN '1 candidato (raro - deberia haber resuelto)'
        WHEN num_candidatos_pago >= 2 AND num_candidatos_pago_con_rebzg = num_candidatos_pago THEN '2+ candidatos, TODOS con REBZG (deberian resolver via REBZG)'
        WHEN num_candidatos_pago >= 2 THEN '2+ candidatos PAGO, ambiguo'
    END
ORDER BY num_facturas DESC;
GO
