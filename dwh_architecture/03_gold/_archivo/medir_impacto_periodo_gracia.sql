USE ANALISIS_DATOS;
GO

-- ¿Cuanto de nuestra cartera_vencida cae en la ventana de 1-16 dias
-- (periodo de gracia que el negocio trata como "saldo sano")? Filtrado a
-- clientes reales (canal 10/20/40/60, sin LEGAL), sin SA (ver diagnostico anterior).
DECLARE @hoy DATE = CAST(GETDATE() AS DATE);
;WITH bsid_firmado_sin_sa AS (
    SELECT b.*,
        CASE WHEN b.debe_haber = 'H' THEN -b.monto_moneda_local ELSE b.monto_moneda_local END AS monto_firmado
    FROM silver.sap_bsid b
    WHERE b.clase_documento <> 'SA'
),
con_dias AS (
    SELECT f.*,
        CASE WHEN f.fecha_vencimiento IS NOT NULL AND f.fecha_vencimiento < @hoy
             THEN DATEDIFF(DAY, f.fecha_vencimiento, @hoy) END AS dias_vencido
    FROM bsid_firmado_sin_sa f
    JOIN gold.dim_cliente_comercial dc
        ON dc.cliente_id = f.cliente_id AND dc.es_vigente = 1
       AND dc.canal_distribucion IN ('10','20','40','60')
       AND dc.estatus_comercial <> 'LEGAL'
)
SELECT
    CASE
        WHEN dias_vencido IS NULL THEN 'No vencido'
        WHEN dias_vencido BETWEEN 1 AND 16 THEN '1-16 dias (posible periodo de gracia)'
        ELSE '17+ dias (vencido real)'
    END AS categoria,
    SUM(monto_firmado) AS monto,
    COUNT(*) AS num_documentos
FROM con_dias
GROUP BY
    CASE
        WHEN dias_vencido IS NULL THEN 'No vencido'
        WHEN dias_vencido BETWEEN 1 AND 16 THEN '1-16 dias (posible periodo de gracia)'
        ELSE '17+ dias (vencido real)'
    END;
GO
