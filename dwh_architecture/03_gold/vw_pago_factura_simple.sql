/* ============================================================================
   gold.vw_pago_factura_simple
   Purpose : Legacy payment <-> invoice relationship over the settled facts;
             source of the current collections report in Power BI.
   Run     : any time; a view.
   Notes   : One row per payment and invoice. Sum monto_pago_asignado (payment
             prorated by invoice amount), never monto_pago_virgen (it repeats
             for every invoice of the group).
             Rules: only groups whose lines belong to one identity (RFC); a
             group with 2+ payments and 2+ invoices is LOTE_CONCILIACION, with
             no invoice; a payment whose group has no invoice follows one
             unambiguous second hop; a deposit that matches a single SA 'REEM%'
             line to the cent is a refund and is left out.
             Dates by fecha_contabilizacion. Scope: channels 10/40/60, not
             FUERA_DE_ALCANCE, not SIN_RFC.
   ============================================================================ */
USE ANALISIS_DATOS;
GO

IF OBJECT_ID('gold.vw_pago_factura_simple', 'V') IS NOT NULL DROP VIEW gold.vw_pago_factura_simple;
GO
CREATE VIEW gold.vw_pago_factura_simple AS
WITH pagos_por_grupo AS (
    SELECT
        documento_compensacion,
        ejercicio_compensacion,
        COUNT(*) AS num_pagos_candidatos
    FROM gold.fact_pagos_compensados
    GROUP BY documento_compensacion, ejercicio_compensacion
),
grupo_rfc_unico AS (
    -- INNER JOIN: SAP never deletes customers, so every cliente_id is in dim_cliente.
    -- ISNULL: a customer with no RFC is one identity, not zero.
    SELECT b.documento_compensacion, b.ejercicio_compensacion
    FROM silver.sap_bsad b
    INNER JOIN gold.dim_cliente k ON k.cliente_id = b.cliente_id
    GROUP BY b.documento_compensacion, b.ejercicio_compensacion
    HAVING COUNT(DISTINCT ISNULL(k.rfc, 'SIN_RFC_' + k.cliente_id)) = 1
),
facturas_por_grupo AS (
    SELECT documento_compensacion, ejercicio_compensacion,
           COUNT(*) AS num_facturas_candidatas,
           SUM(monto_moneda_local) AS suma_facturas_grupo
    FROM gold.fact_facturas_compensadas
    GROUP BY documento_compensacion, ejercicio_compensacion
),
-- Two-hop chains: a document's own onward clearing (H line) to another group.
salto_h AS (
    SELECT documento_id AS grupo_intermedio,
           documento_compensacion AS grupo_final,
           ejercicio_compensacion AS ejercicio_grupo_final
    FROM silver.sap_bsad
    WHERE debe_haber = 'H'
      AND documento_compensacion <> documento_id
    GROUP BY documento_id, documento_compensacion, ejercicio_compensacion
),
-- The hop is followed only when it lands in exactly one final group.
grupo_final_unico AS (
    SELECT grupo_intermedio,
           MIN(grupo_final) AS grupo_final,
           MIN(ejercicio_grupo_final) AS ejercicio_grupo_final
    FROM salto_h
    GROUP BY grupo_intermedio
    HAVING COUNT(DISTINCT grupo_final) = 1
),
-- The direct group if it has invoices; otherwise the final group of the hop if that one has.
grupo_resuelto AS (
    SELECT
        g.documento_compensacion,
        g.ejercicio_compensacion,
        CASE
            WHEN fpg_directo.num_facturas_candidatas > 0 THEN g.documento_compensacion
            WHEN fpg_final.num_facturas_candidatas > 0 THEN gfu.grupo_final
            ELSE g.documento_compensacion
        END AS documento_compensacion_resuelto,
        CASE
            WHEN fpg_directo.num_facturas_candidatas > 0 THEN g.ejercicio_compensacion
            WHEN fpg_final.num_facturas_candidatas > 0 THEN gfu.ejercicio_grupo_final
            ELSE g.ejercicio_compensacion
        END AS ejercicio_compensacion_resuelto
    FROM pagos_por_grupo g
    LEFT JOIN facturas_por_grupo fpg_directo
        ON fpg_directo.documento_compensacion = g.documento_compensacion
       AND fpg_directo.ejercicio_compensacion = g.ejercicio_compensacion
    LEFT JOIN grupo_final_unico gfu
        ON gfu.grupo_intermedio = g.documento_compensacion
    LEFT JOIN facturas_por_grupo fpg_final
        ON fpg_final.documento_compensacion = gfu.grupo_final
       AND fpg_final.ejercicio_compensacion = gfu.ejercicio_grupo_final
),
-- SA lines with text REEM...: cash earmarked to be refunded to the customer.
sa_reem_en_grupo AS (
    SELECT documento_compensacion, ejercicio_compensacion,
           SUM(monto_moneda_local) AS monto_sa_reem
    FROM silver.sap_bsad
    WHERE clase_documento = 'SA' AND sgtxt LIKE 'REEM%'
    GROUP BY documento_compensacion, ejercicio_compensacion
),
-- A refund only when the group has one payment candidate matching the SA line to the cent.
reembolso_limpio AS (
    SELECT g.documento_compensacion, g.ejercicio_compensacion
    FROM pagos_por_grupo g
    INNER JOIN gold.fact_pagos_compensados p2
        ON p2.documento_compensacion = g.documento_compensacion
       AND p2.ejercicio_compensacion = g.ejercicio_compensacion
    INNER JOIN sa_reem_en_grupo sr
        ON sr.documento_compensacion = g.documento_compensacion
       AND sr.ejercicio_compensacion = g.ejercicio_compensacion
    WHERE g.num_pagos_candidatos = 1
      AND ABS(p2.monto_moneda_local - sr.monto_sa_reem) < 1.0
)
SELECT
    p.cliente_id,   -- the payer
    k.nombre,
    dc.canal_distribucion,
    dc.estatus_comercial,
    dc.id_surrogate        AS cliente_comercial_sk,
    p.documento_id        AS documento_pago,
    p.fecha_contabilizacion AS fecha_pago,
    p.monto_moneda_local  AS monto_pago_virgen,   -- repeats per invoice: do not SUM
    CASE
        WHEN f.documento_id IS NULL THEN p.monto_moneda_local
        ELSE p.monto_moneda_local * f.monto_moneda_local / NULLIF(fpg_res.suma_facturas_grupo, 0)
    END                                        AS monto_pago_asignado,   -- SUM this one
    f.documento_id        AS documento_factura,
    f.fecha_documento     AS fecha_factura,
    f.fecha_vencimiento,
    f.monto_moneda_local  AS monto_factura,
    DATEDIFF(DAY, f.fecha_vencimiento, p.fecha_contabilizacion) AS dias_pago,   -- negative = paid before due
    dcr.id_surrogate       AS cliente_credito_sk,
    CASE WHEN f.documento_id IS NULL THEN 'FACTURA_NO_IDENTIFICADA' ELSE 'FACTURA_IDENTIFICADA' END AS estatus_identificacion,
    CASE
        WHEN f.documento_id IS NOT NULL THEN NULL
        WHEN g.num_pagos_candidatos > 1 AND ISNULL(fpg.num_facturas_candidatas, 0) > 1 THEN 'LOTE_CONCILIACION'
        ELSE 'SIN_FACTURA_IDENTIFICADA'
    END AS motivo_no_identificado,
    CASE
        WHEN f.documento_id IS NULL THEN NULL
        WHEN f.fecha_vencimiento < DATEFROMPARTS(YEAR(p.fecha_contabilizacion), MONTH(p.fecha_contabilizacion), 1) THEN 'PAGO_A_VENCIMIENTO'
        WHEN f.fecha_vencimiento <= EOMONTH(p.fecha_contabilizacion) THEN 'PAGO_A_MES'
        ELSE 'PAGO_ANTICIPADO'
    END AS clasificacion_cobranza
FROM gold.fact_pagos_compensados p
INNER JOIN pagos_por_grupo g
    ON g.documento_compensacion = p.documento_compensacion
   AND g.ejercicio_compensacion = p.ejercicio_compensacion
INNER JOIN grupo_rfc_unico gr
    ON gr.documento_compensacion = p.documento_compensacion
   AND gr.ejercicio_compensacion = p.ejercicio_compensacion
LEFT JOIN facturas_por_grupo fpg
    ON fpg.documento_compensacion = p.documento_compensacion
   AND fpg.ejercicio_compensacion = p.ejercicio_compensacion
LEFT JOIN grupo_resuelto gres
    ON gres.documento_compensacion = p.documento_compensacion
   AND gres.ejercicio_compensacion = p.ejercicio_compensacion
LEFT JOIN facturas_por_grupo fpg_res
    ON fpg_res.documento_compensacion = gres.documento_compensacion_resuelto
   AND fpg_res.ejercicio_compensacion = gres.ejercicio_compensacion_resuelto
LEFT JOIN gold.fact_facturas_compensadas f
    ON f.documento_compensacion = gres.documento_compensacion_resuelto
   AND f.ejercicio_compensacion = gres.ejercicio_compensacion_resuelto
   -- LOTE_CONCILIACION groups get no invoice: one row per payment.
   AND NOT (g.num_pagos_candidatos > 1 AND ISNULL(fpg.num_facturas_candidatas, 0) > 1)
INNER JOIN gold.dim_cliente_comercial dc
    ON dc.cliente_id = p.cliente_id
   AND p.fecha_documento BETWEEN dc.fecha_inicio_vigencia AND ISNULL(dc.fecha_fin_vigencia, '99991231')
LEFT JOIN gold.dim_cliente_credito dcr
    ON dcr.cliente_id = p.cliente_id
   AND p.fecha_documento BETWEEN dcr.fecha_inicio_vigencia AND ISNULL(dcr.fecha_fin_vigencia, '99991231')
INNER JOIN gold.dim_cliente k
    ON k.cliente_id = p.cliente_id
LEFT JOIN gold.dim_cliente kf
    ON kf.cliente_id = f.cliente_id
LEFT JOIN reembolso_limpio rl
    ON rl.documento_compensacion = p.documento_compensacion
   AND rl.ejercicio_compensacion = p.ejercicio_compensacion
WHERE rl.documento_compensacion IS NULL
  AND dc.canal_distribucion IN ('10', '40', '60')
  AND dc.estatus_comercial <> 'FUERA_DE_ALCANCE'
  AND k.tipo_cliente <> 'SIN_RFC'
  AND (kf.tipo_cliente IS NULL OR kf.tipo_cliente <> 'SIN_RFC');
GO
