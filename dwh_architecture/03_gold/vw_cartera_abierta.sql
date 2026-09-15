/* ============================================================================
   gold.vw_cartera_abierta
   Purpose : Open invoices line by line (silver.sap_bsid), in scope: channels
             10/40/60, not FUERA_DE_ALCANCE, not SIN_RFC. The customer
             dimensions are joined at today's version.
   Run     : any time; a view.
   Notes   : Sum monto_firmado, never monto_original (unsigned).
             SA documents are excluded; 1-16 days overdue is a grace period.
             It does not reconcile with gold.fact_saldo_cartera on purpose: that
             snapshot keeps the whole company's balance, with no scope filter.
   ============================================================================ */
USE ANALISIS_DATOS;
GO

IF OBJECT_ID('gold.vw_cartera_abierta', 'V') IS NOT NULL DROP VIEW gold.vw_cartera_abierta;
GO
CREATE VIEW gold.vw_cartera_abierta AS
WITH hoy AS (
    SELECT CAST(GETDATE() AS DATE) AS fecha_hoy
)
SELECT
    b.cliente_id,
    k.nombre                    AS cliente_nombre,
    k.tipo_cliente,
    dc.id_surrogate              AS cliente_comercial_sk,
    dc.canal_distribucion,
    dc.estatus_comercial,
    dc.ruta_nombre,
    dc.vendedor_nombre,
    dcr.id_surrogate              AS cliente_credito_sk,
    dcr.cobrador_nombre,
    dcr.analista_credito_nombre,
    dcr.limite_credito,
    dcr.bloqueo_credito,
    b.documento_id,
    b.documento_ventas,
    b.referencia,
    b.clase_documento,
    b.fecha_documento,
    b.fecha_contabilizacion,
    b.fecha_vencimiento,
    b.condicion_pago,
    b.dias_plazo,
    b.moneda,
    b.debe_haber,
    b.monto_moneda_local         AS monto_original,       -- unsigned: do not SUM
    CASE WHEN b.debe_haber = 'H' THEN -b.monto_moneda_local ELSE b.monto_moneda_local END AS monto_firmado,  -- signed: SUM this one
    CASE WHEN b.fecha_vencimiento IS NOT NULL AND b.fecha_vencimiento < h.fecha_hoy
         THEN DATEDIFF(DAY, b.fecha_vencimiento, h.fecha_hoy) END AS dias_vencido,
    CASE
        WHEN b.fecha_vencimiento IS NULL OR b.fecha_vencimiento >= h.fecha_hoy THEN 'NO_VENCIDO'
        WHEN DATEDIFF(DAY, b.fecha_vencimiento, h.fecha_hoy) BETWEEN 1 AND 16 THEN 'GRACIA_1_16'
        WHEN DATEDIFF(DAY, b.fecha_vencimiento, h.fecha_hoy) BETWEEN 17 AND 31 THEN 'VENCIDO_17_31'
        WHEN DATEDIFF(DAY, b.fecha_vencimiento, h.fecha_hoy) BETWEEN 32 AND 180 THEN 'VENCIDO_32_180'
        ELSE 'VENCIDO_181_MAS'
    END AS bucket_vencimiento,
    b.area_reclamacion,
    b.nivel_reclamacion,
    b.clave_reclamacion_legal,
    b.bloqueo_reclamacion_temporal,
    b.fecha_ultima_reclamacion
FROM silver.sap_bsid b
CROSS JOIN hoy h
INNER JOIN gold.dim_cliente k
    ON k.cliente_id = b.cliente_id
INNER JOIN gold.dim_cliente_comercial dc
    ON dc.cliente_id = b.cliente_id
   AND h.fecha_hoy BETWEEN dc.fecha_inicio_vigencia AND ISNULL(dc.fecha_fin_vigencia, '99991231')
LEFT JOIN gold.dim_cliente_credito dcr
    ON dcr.cliente_id = b.cliente_id
   AND h.fecha_hoy BETWEEN dcr.fecha_inicio_vigencia AND ISNULL(dcr.fecha_fin_vigencia, '99991231')
WHERE b.clase_documento <> 'SA'
  AND k.tipo_cliente <> 'SIN_RFC'
  AND dc.canal_distribucion IN ('10', '40', '60')
  AND dc.estatus_comercial <> 'FUERA_DE_ALCANCE';
GO
