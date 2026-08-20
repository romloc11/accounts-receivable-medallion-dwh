USE ANALISIS_DATOS;
GO

-- Cobertura de factura_referencia_documento (REBZG) por categoria de documento,
-- para confirmar si es igual de confiable en NC/ND/DEVO/AJUSTE como ya sabiamos
-- que lo era en PAGO (DZ/CP)
SELECT
    CASE
        WHEN clase_documento IN ('DZ','CP','ZY') THEN 'PAGO'
        WHEN clase_documento = 'C5' THEN 'NOTA_CREDITO'
        WHEN clase_documento = 'D1' THEN 'NOTA_DEBITO'
        WHEN clase_documento IN ('C1','C2','C3','C4') THEN 'DEVOLUCION'
        WHEN clase_documento = 'AB' THEN 'AJUSTE'
        ELSE 'OTRO'
    END AS categoria,
    clase_documento,
    COUNT(*) AS total_filas,
    SUM(CASE WHEN factura_referencia_documento IS NOT NULL THEN 1 ELSE 0 END) AS con_rebzg,
    CAST(100.0 * SUM(CASE WHEN factura_referencia_documento IS NOT NULL THEN 1 ELSE 0 END) / COUNT(*) AS DECIMAL(5,2)) AS pct_con_rebzg
FROM silver.sap_bsad
WHERE clase_documento IN ('DZ','CP','ZY','C5','D1','C1','C2','C3','C4','AB')
GROUP BY
    CASE
        WHEN clase_documento IN ('DZ','CP','ZY') THEN 'PAGO'
        WHEN clase_documento = 'C5' THEN 'NOTA_CREDITO'
        WHEN clase_documento = 'D1' THEN 'NOTA_DEBITO'
        WHEN clase_documento IN ('C1','C2','C3','C4') THEN 'DEVOLUCION'
        WHEN clase_documento = 'AB' THEN 'AJUSTE'
        ELSE 'OTRO'
    END,
    clase_documento
ORDER BY categoria, clase_documento;
GO
