USE ANALISIS_DATOS;
GO

-- ==========================================================
-- gold.vw_cartera_abierta : line-by-line detail of currently open invoices,
-- SCOPED to real wholesale/legitimate customers.
-- Source: silver.sap_bsid (Proposals in design list, DESIGN.md, built
-- 2026-08-27; scope filters added 2026-08-27 same day, see below).
--
-- PURPOSE: gold.fact_saldo_cartera only carries the customer+day AGGREGATE
-- open balance - there's no way to see which specific invoices make up
-- that number. This view is the drill-down: same source table, same core
-- business rules (sign, aging thresholds), but at line grain, for
-- day-to-day collections queries and Power BI drill-through - AND scoped to
-- "cartera que sí debe considerarse" (the user's own words), not the whole
-- company's raw open balance.
--
-- IT'S A VIEW, NOT A TABLE (criterion 4 of DESIGN.md's table-vs-view
-- rule): silver.sap_bsid is a complete daily mirror with no history to
-- preserve at line grain, and this view only ever needs "as of right now"
-- (recomputed on every query). Nothing stores a surrogate key pointing at
-- a row here.
--
-- SCOPE FILTERS added 2026-08-27, all 3 confirmed with the business owner
-- while validating this same view (not guesses):
--   - canal_distribucion IN ('10','40','60') - real WHOLESALE customer
--     channels. Channel '20' (menudeo/retail) was tried in this filter and
--     the same day REVERTED: this DWH is explicitly scoped to mayoreo -
--     channel 20 customers ARE real customers (that's why gold.vw_cliente_canal_estatus's
--     FUERA_DE_ALCANCE was deliberately NOT touched for them), they're just
--     outside this DWH's mission. Reverting this also sidesteps a real
--     finding: channel 20 pays almost exclusively via clase_documento='CP'
--     (Cobranza POS), which gold.fact_pagos_compensados never covers (only
--     'DZ') - see dwh-ciosa-project-status.md in memory for the full
--     investigation. Don't re-add '20' here without deciding CP support
--     first, or it'll silently show near-zero coverage again.
--   - estatus_comercial <> 'FUERA_DE_ALCANCE' - excludes accounts
--     gold.vw_cliente_canal_estatus already flags as not real customers
--     (wrong channel, or cliente_id prefix 5/6/7/9 - see that view's own
--     header for the full catalog, prefix 9 added same day as this).
--   - tipo_cliente <> 'DIRECCION_ALTERNA' - customers with no RFC.
--     Confirmed 2026-08-27 by a business-process owner: these are not real
--     customers and should never be counted in cartera analysis (echoes
--     the same exclusion gold.vw_pago_factura_simple already had since
--     2026-08-19, now confirmed rather than just inferred from a 10-account
--     sample).
--
-- DELIBERATE ARCHITECTURAL CHOICE - this view NO LONGER reconciles against
-- gold.fact_saldo_cartera.saldo_total, and that's intentional, not a
-- regression. fact_saldo_cartera was deliberately LEFT UNCHANGED (still
-- broad, no scope filter) for 2 reasons: (1) it's the only place that
-- answers "how much does the WHOLE company owe, any channel/type" - scoping
-- it in place would delete that number from the DWH entirely; (2) it's a
-- periodic snapshot that CANNOT be backfilled - narrowing it in place would
-- create a permanent discontinuity between already-accumulated broad-scope
-- history and future narrow-scope snapshots, with no way to fix it after
-- the fact. Putting the scope filter here instead (a view, recomputed
-- live, zero risk to any accumulated history) gets the same practical
-- result - SUM(monto_firmado) grouped by cliente_id here is the correct
-- "real, in-scope cartera" number - without touching fact_saldo_cartera at
-- all. If a DAILY TREND of this same scoped number is ever needed (not
-- just "as of today"), that requires a NEW separate snapshot fact - a view
-- can't accumulate history bsid itself doesn't retain - don't try to bolt
-- that onto this object.
--
-- Business rules replicated from gold.load_fact_saldo_cartera Step 1
-- (still identical, only the scope changed):
--   - clase_documento = 'SA' excluded (GL journal entries).
--   - monto_moneda_local signed by debe_haber before anything else.
--   - dias_vencido / bucket thresholds: 1-16 days = grace period, 17+ =
--     real vencido, aging cut at 17-31/32-180/181+.
--
-- SCD2 DIMENSIONS JOINED AT "TODAY" (@hoy): silver.sap_bsid has no "as of"
-- concept of its own, it's always a mirror of right now, so "which
-- commercial/credit profile applies" can only mean "the customer's CURRENT
-- profile" - same temporal join fact_saldo_cartera's own Step 3 uses.
-- dim_cliente_comercial is now an INNER JOIN (was LEFT JOIN before the
-- scope filters): a customer with no comercial record can never satisfy
-- canal_distribucion/estatus_comercial anyway, so INNER JOIN says that
-- honestly instead of relying on an accidental LEFT JOIN + WHERE
-- combination. dim_cliente_credito stays LEFT JOIN - credit profile is
-- enrichment, not a scope condition (a customer with no credit record yet
-- can still be legitimately in scope).
--
-- cobrador_nombre/analista_credito_nombre/vendedor_nombre exposed for
-- collections drill-down - sourced from the existing plain-text columns on
-- dim_cliente_comercial/dim_cliente_credito, not from gold.dim_empleado
-- (a role-playing dimension conforms the IDENTITY, it doesn't replace
-- these existing resolved-name columns).
-- ==========================================================
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
    b.monto_moneda_local         AS monto_original,       -- raw, unsigned - see header warning, don't SUM() this directly
    CASE WHEN b.debe_haber = 'H' THEN -b.monto_moneda_local ELSE b.monto_moneda_local END AS monto_firmado,  -- safe to SUM(): the correct "cartera en alcance" total
    CASE WHEN b.fecha_vencimiento IS NOT NULL AND b.fecha_vencimiento < h.fecha_hoy
         THEN DATEDIFF(DAY, b.fecha_vencimiento, h.fecha_hoy) END AS dias_vencido,
    CASE
        WHEN b.fecha_vencimiento IS NULL OR b.fecha_vencimiento >= h.fecha_hoy THEN 'NO_VENCIDO'
        WHEN DATEDIFF(DAY, b.fecha_vencimiento, h.fecha_hoy) BETWEEN 1 AND 16 THEN 'GRACIA_1_16'
        WHEN DATEDIFF(DAY, b.fecha_vencimiento, h.fecha_hoy) BETWEEN 17 AND 31 THEN 'VENCIDO_17_31'
        WHEN DATEDIFF(DAY, b.fecha_vencimiento, h.fecha_hoy) BETWEEN 32 AND 180 THEN 'VENCIDO_32_180'
        ELSE 'VENCIDO_181_MAS'
    END AS bucket_vencimiento,
    -- dunning (line level, same columns fact_saldo_cartera aggregates from)
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
  AND k.tipo_cliente <> 'DIRECCION_ALTERNA'
  AND dc.canal_distribucion IN ('10', '40', '60')
  AND dc.estatus_comercial <> 'FUERA_DE_ALCANCE';
GO

PRINT 'View gold.vw_cartera_abierta created successfully.';
GO
