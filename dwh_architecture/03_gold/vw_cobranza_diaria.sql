/* ============================================================================
   gold.vw_cobranza_diaria
   Purpose : Actual collections per day (gold.fact_pagos by fecha_documento), in
             the budget's scope: channels 10/40/60, not FUERA_DE_ALCANCE,
             resolved at the payment date.
   Run     : any time; a view, recalculated on every query.
   Notes   : Measures cash. The payment-flow report measures settled invoices
             (fecha_pago_efectiva); they differ by the unlinked payments and by
             invoices paid across two months.
   ============================================================================ */
USE ANALISIS_DATOS;
GO

IF OBJECT_ID('gold.vw_cobranza_diaria') IS NOT NULL
    DROP VIEW gold.vw_cobranza_diaria;
GO

CREATE VIEW gold.vw_cobranza_diaria
AS
SELECT
    g.fecha_documento           AS fecha,
    SUM(g.monto)                AS monto_real,
    COUNT(*)                    AS n_pagos,
    COUNT(DISTINCT g.cliente_id) AS n_clientes
FROM   gold.fact_pagos g
JOIN   gold.dim_cliente_comercial d
       ON  d.cliente_id = g.cliente_id
       AND g.fecha_documento >= d.fecha_inicio_vigencia
       AND (d.fecha_fin_vigencia IS NULL OR g.fecha_documento <= d.fecha_fin_vigencia)
       AND d.estatus_comercial <> 'FUERA_DE_ALCANCE'
       AND d.canal_distribucion IN (10, 40, 60)
GROUP BY g.fecha_documento;
GO
