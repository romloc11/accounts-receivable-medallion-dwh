IF OBJECT_ID('gold.vw_clasificacion_vencimiento_pago', 'V') IS NOT NULL
    DROP VIEW gold.vw_clasificacion_vencimiento_pago;
GO

CREATE VIEW gold.vw_clasificacion_vencimiento_pago AS
SELECT
    b.cliente_id,
    k.nombre,
    k.rfc,
    dc.canal_distribucion,
    dc.condicion_pago,
    b.documento_id,
    b.posicion,
    b.fecha_documento,
    b.fecha_vencimiento,
    b.fecha_compensacion,
    b.documento_compensacion,
    b.monto_moneda_local,
    DATEDIFF(DAY, b.fecha_vencimiento, b.fecha_compensacion) AS dias_pago, -- negativo = pago antes de vencer, positivo = pago tarde
    CASE
        WHEN b.fecha_vencimiento < b.fecha_compensacion THEN 'YA_VENCIDA'
        WHEN b.fecha_vencimiento <= EOMONTH(b.fecha_compensacion) THEN 'VENCE_MISMO_MES'
        ELSE 'VENCE_MESES_FUTUROS'
    END AS clasificacion_vencimiento
FROM silver.sap_bsad b
INNER JOIN gold.dim_cliente_comercial dc
    ON dc.cliente_id = b.cliente_id
   AND b.fecha_compensacion BETWEEN dc.fecha_inicio_vigencia AND ISNULL(dc.fecha_fin_vigencia, '99991231')
INNER JOIN gold.dim_cliente k
    ON k.cliente_id = b.cliente_id
WHERE b.clase_documento IN ('F1', 'F2', 'F3', 'F4', 'F5', 'F6')
  AND dc.canal_distribucion IN ('10', '20', '40', '60')
  AND k.tipo_cliente <> 'GENERICO';
GO

SELECT  TOP 100 * FROM gold.vw_clasificacion_vencimiento_pago
WHERE fecha_compensacion BETWEEN '2026-07-01' AND '2026-07-31'
AND cliente_id = 10000018