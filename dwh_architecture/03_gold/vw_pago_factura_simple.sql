-- ==========================================================
-- gold.vw_pago_factura_simple : raw payment <-> invoice relationship
-- Source: gold.fact_pagos_compensados / gold.fact_facturas_compensadas (formalized in ddl_gold.sql
-- / sp_load_gold.sql 2026-08-19 - replacing the prototype views
-- gold.vw_pago_virgen / gold.vw_factura, now retired).
--
-- Only relates groups where there is EXACTLY 1 candidate raw payment -
-- if 2+ raw payments share the same compensation group, there's no way
-- to know for certain which payment covered which invoice, so it's left
-- out (the same "don't guess" principle already used throughout the
-- project) instead of forcing an arbitrary match.
--
-- DIRECCION_ALTERNA is excluded entirely (confirmed 2026-08-19: 9 of 10
-- accounts of that type within the in-scope channels are technical
-- reconciliation accounts: Kushky/Conekta-Oxxo/Openpay/Mercado Libre/Mercado
-- Pago "INGRESOS TRANSITORIA", SALDO A FAVOR CUENTAS, DEPOSITOS NO
-- IDENTIFICADOS, etc. - none of them represents a real customer).
--
-- GENERICO (RFC XAXX010101000/XEXX010101000) IS included - business
-- decision 2026-08-20: the business process owner was shown the full list
-- of generic customers (Mercado Libre, storefront, employees, tests,
-- foreign customers, etc.) and confirmed they should be considered,
-- "they're part of the flow." This reverts the GENERICO exclusion that
-- existed from 2026-08-19 to 2026-08-20.
--
-- SINGLE-RFC-PER-GROUP FILTER (replaces the GENERICO exclusion as a
-- data-quality safeguard): instead of blocking by customer type, it
-- blocks by compensation group - only payments whose entire compensation
-- group (in silver.sap_bsad, all lines, not just payment+invoice) belongs
-- to a SINGLE real RFC are included. This DOES allow legitimate cliente_id
-- crossovers within the same RFC (the same person/company with several
-- accounts, e.g. 2000388/2001416 = RFC GUGG850717SS6), but excludes
-- batches where genuinely different RFCs get mixed together (marketplace
-- technical accounts mixing with each other, etc.). Measured 2026-08-20
-- over the full historical GENERICO customers in channel 10/40/60: only
-- 430 payments / $315,923 (0.12% of the amount) fall into groups with 2+
-- distinct RFCs - those are the only ones this filter excludes; the other
-- 99.88% ($258M) passes through fine.
--
-- clasificacion_cobranza added 2026-08-19 (first stage of the payment-
-- behavior / budget-compliance report - the "how much came in and which
-- portfolio bucket it belongs to" half, NOT the "expected budget" half,
-- which isn't built yet): classifies each payment by whether the invoice
-- it settled was already overdue before the payment's month, was due that
-- same month, or was due in a future month (early payment) - comparing
-- fecha_vencimiento against fecha_pago's own month (not a fixed month, the
-- view still has no hardcoded date, the period filter is applied at query
-- time).
--
-- CLIENTE_LEGAL RETIRED 2026-08-20: it originally took priority over the
-- due-date classification (a customer in legal status was labeled as such
-- regardless of when their invoice was due). Removed because it isn't
-- reliable looking backward in time: dim_cliente_comercial is SCD2, but
-- each customer's INITIAL version was artificially backdated to
-- 2020-01-01 (fix_vigencia_inicial_scd2.sql) just to allow the temporal
-- join with historical facts - it doesn't represent an actually observed
-- real transition. A customer who became LEGAL only a few months ago, and
-- never had another status transition captured by the SCD2, would show up
-- with LEGAL status since 2020-01-01 in dim_cliente_comercial - the
-- temporal join was labeling 2022-2025 payments as CLIENTE_LEGAL for a
-- customer who was actually paying normally back then. These payments are
-- now classified the same as any other customer (VENCIDA/DEL_MES/
-- ANTICIPADO by real date). estatus_comercial/canal_distribucion are still
-- exposed as columns on the view (the temporal join to dim_cliente_comercial
-- still exists, it just stopped being used for the classification) - the
-- same historical-reliability caveat applies if they're used to
-- filter/group backward in time.
--
-- clasificacion_cobranza validated 2026-08-26: the month-boundary
-- coarseness (comparing fecha_vencimiento's month against fecha_pago's
-- month, not the exact day gap) was checked against dias_pago directly
-- over 2026 data. Two possible distortions were measured and found
-- immaterial when judged against the same 1-16 day grace-period
-- threshold gold.fact_saldo_cartera already uses for "not really
-- overdue" (saldo_1_16):
--   - PAGO_ANTICIPADO inflated by payments 1-3 days early that just
--     happen to cross a month boundary: 3.25% of the bucket's amount
--     ($7.8M of $239.9M).
--   - CARTERA_DEL_MES hiding invoices paid 17+ days late within the
--     same month: 1.9% of the bucket's amount ($11.5M of $616.4M).
-- Both effects are real (the classification IS month-cohort, not
-- day-precise) but too small to justify a redesign. dias_pago is
-- already exposed as a raw column for anyone who needs day-level
-- precision instead of the month-cohort label. Don't re-run this
-- investigation from scratch - re-verify with a fresh date range only
-- if the underlying payment mix changes materially.
--
-- monto_pago_asignado added 2026-08-26 - FAN-OUT WARNING: a single
-- compensation group commonly settles 2+ invoices at once (51.6% of
-- payment groups measured on 2026 data), and this view's grain is
-- 1 row per (pago, factura) pair. That means monto_pago_virgen REPEATS
-- in full on every one of those rows - summing it directly inflates
-- the real cash figure by however many invoices share the group (measured:
-- $853.9M real vs. $97,645.0M if summed naively across all 2026 fan-out
-- groups, a ~95x inflation - the same class of over-attribution bug that
-- got the original fact_aplicacion_pagos deleted 2026-08-19). Power BI's
-- own "Monto Total Recibido" measure already works around this via
-- SUMX(DISTINCT Cobranza[Documento Pago], MIN(...)) - but any direct SQL
-- consumer of monto_pago_virgen falls straight into the trap.
-- monto_pago_asignado is the safe alternative: the payment amount split
-- proportionally across the invoices it settled (weighted by each
-- invoice's own amount within the group), so SUM(monto_pago_asignado)
-- always equals real cash received, with no DISTINCT trick required.
-- monto_pago_virgen is kept as-is (the raw, per-row-repeated deposit
-- amount) for anyone who genuinely needs to see the original payment
-- document's value on each row - just never SUM() it directly.
-- ==========================================================
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
    -- INNER JOIN intencional, no LEFT JOIN: este negocio nunca elimina
    -- clientes de SAP, solo los inactiva (via flags como bloqueo_pedido/
    -- estatus_comercial) - el registro fisico en kna1/knkk siempre persiste,
    -- asi que todo cliente_id de sap_bsad tiene garantizado un match en
    -- dim_cliente. Confirmado con datos reales 2026-08-26 (0 huerfanos) y
    -- con la regla de negocio del usuario. No cambiar a LEFT JOIN sin
    -- evidencia de que esta politica cambio.
    SELECT b.documento_compensacion, b.ejercicio_compensacion
    FROM silver.sap_bsad b
    INNER JOIN gold.dim_cliente k ON k.cliente_id = b.cliente_id
    GROUP BY b.documento_compensacion, b.ejercicio_compensacion
    HAVING COUNT(DISTINCT k.rfc) = 1
),
facturas_por_grupo AS (
    SELECT documento_compensacion, ejercicio_compensacion, SUM(monto_moneda_local) AS suma_facturas_grupo
    FROM gold.fact_facturas_compensadas
    GROUP BY documento_compensacion, ejercicio_compensacion
)
SELECT
    p.cliente_id, -- the PAYER, not the invoice's own owner (f.cliente_id, not exposed) - confirmed 2026-08-26 this is intentional: the report groups by who paid, not by who originally owed the invoice. If that ever needs to change, f.cliente_id is available on the fact_facturas_compensadas join (f) already in this view.
    k.nombre,
    dc.canal_distribucion,
    dc.estatus_comercial,
    p.documento_id        AS documento_pago,
    p.fecha_documento     AS fecha_pago,
    p.monto_moneda_local  AS monto_pago_virgen, -- repeats per row when the group has 2+ facturas - do not SUM() directly, see header warning
    p.monto_moneda_local * f.monto_moneda_local
        / NULLIF(fpg.suma_facturas_grupo, 0)      AS monto_pago_asignado, -- safe to SUM(): payment split proportionally across the invoices it settled
    f.documento_id        AS documento_factura,
    f.fecha_documento     AS fecha_factura,
    f.fecha_vencimiento,
    f.monto_moneda_local  AS monto_factura,
    DATEDIFF(DAY, f.fecha_vencimiento, p.fecha_documento) AS dias_pago, -- negative = paid before due, positive = paid late
    -- No NULL-guard on fecha_vencimiento intentional: every invoice in this
    -- business is required to carry a due date, confirmed with real data
    -- 2026-08-26 (0 rows with fecha_vencimiento IS NULL). If it were ever
    -- NULL, both WHEN comparisons evaluate to UNKNOWN and the CASE falls
    -- through to PAGO_ANTICIPADO by SQL default - don't assume that's still
    -- safe if this business rule ever changes.
    CASE
        WHEN f.fecha_vencimiento < DATEFROMPARTS(YEAR(p.fecha_documento), MONTH(p.fecha_documento), 1) THEN 'CARTERA_VENCIDA'
        WHEN f.fecha_vencimiento <= EOMONTH(p.fecha_documento) THEN 'CARTERA_DEL_MES'
        ELSE 'PAGO_ANTICIPADO'
    END AS clasificacion_cobranza
FROM gold.fact_pagos_compensados p
INNER JOIN pagos_por_grupo g
    ON g.documento_compensacion = p.documento_compensacion
   AND g.ejercicio_compensacion = p.ejercicio_compensacion
   AND g.num_pagos_candidatos = 1
INNER JOIN grupo_rfc_unico gr
    ON gr.documento_compensacion = p.documento_compensacion
   AND gr.ejercicio_compensacion = p.ejercicio_compensacion
INNER JOIN gold.fact_facturas_compensadas f
    ON f.documento_compensacion = p.documento_compensacion
   AND f.ejercicio_compensacion = p.ejercicio_compensacion
INNER JOIN facturas_por_grupo fpg
    ON fpg.documento_compensacion = p.documento_compensacion
   AND fpg.ejercicio_compensacion = p.ejercicio_compensacion
INNER JOIN gold.dim_cliente_comercial dc
    ON dc.cliente_id = p.cliente_id
   AND p.fecha_documento BETWEEN dc.fecha_inicio_vigencia AND ISNULL(dc.fecha_fin_vigencia, '99991231')
INNER JOIN gold.dim_cliente k
    ON k.cliente_id = p.cliente_id
INNER JOIN gold.dim_cliente kf
    ON kf.cliente_id = f.cliente_id
WHERE dc.canal_distribucion IN ('10', '40', '60')
  AND dc.estatus_comercial <> 'FUERA_DE_ALCANCE'
  AND k.tipo_cliente <> 'DIRECCION_ALTERNA'
  AND kf.tipo_cliente <> 'DIRECCION_ALTERNA';
GO
