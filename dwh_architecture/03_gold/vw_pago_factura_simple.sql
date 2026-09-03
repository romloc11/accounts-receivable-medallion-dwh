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
-- SIN_RFC (renamed from DIRECCION_ALTERNA 2026-08-27) is excluded entirely
-- (confirmed 2026-08-19: 9 of 10 accounts of that type within the in-scope
-- channels were technical reconciliation accounts, and confirmed again
-- 2026-08-27 by a business-process owner as a general rule: customers with
-- no RFC are not real customers for cartera purposes). MARKETPLACE added
-- 2026-08-27 as its own tipo_cliente, carved out BEFORE this exclusion -
-- named payment-gateway/marketplace clearing accounts (Kushky, Conekta,
-- Openpay's "INGRESOS TRANSITORIA" account specifically, Mercado Libre,
-- Mercado Pago, Amazon, Claro Shop) used to be caught by this exclusion
-- (most have RFC NULL) but are now deliberately let through, tagged
-- MARKETPLACE in clasificacion_cobranza instead of excluded - see
-- gold.dim_cliente's tipo_cliente CASE (sp_load_gold.sql) for the exact
-- name-pattern identification.
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
--
-- AMBIGUITY GATE REDEFINED 2026-08-29 (same day, later session): "don't guess"
-- now means num_pagos_candidatos>1 AND num_facturas_candidatas>1 together (a
-- true many-to-many group), not just num_pagos_candidatos>1 alone. Found from
-- a real SAP screenshot (customer group 1402614232): 2 payment candidates
-- (a $10,403.21 deposit + a $0.10 leftover, both self-referencing/direct,
-- neither excluded by the self-canceling-pair fix since there's no matching
-- opposite-side line) but only 1 invoice ($10,403.31 - the two payments sum
-- to it exactly). With only 1 invoice in the group there's nothing to
-- mis-attribute: every payment candidate necessarily applies to that same
-- invoice, whether there's 1 or 5 of them - the risk this gate protects
-- against (2+ payments each possibly matching a DIFFERENT invoice) simply
-- doesn't exist when there's at most 1 invoice. Validated against real July
-- data before implementing: of the 27 groups the OLD gate still excluded
-- after the self-canceling-pair fix, 23 have exactly 1 invoice ($120,710.99
-- - the exact pattern above, now resolved) and only 4 have many invoices
-- (5/7/10/13 - genuinely ambiguous many-to-many, $166,221.23, correctly still
-- excluded). monto_pago_asignado's existing proration math already handles
-- this correctly with no formula change: with exactly 1 invoice,
-- suma_facturas_grupo equals that invoice's own amount, so
-- p.monto*f.monto/suma_facturas_grupo simplifies to p.monto - each payment
-- counts in full, nothing double-counted or dropped.
--
-- LOTE_CONCILIACION added 2026-08-29 (same day, later session): the AMBIGUITY
-- GATE note above still left 4 real July groups excluded even after allowing
-- single-invoice groups through - all 4 are genuine many-to-many batches
-- (2-3 payment candidates against 5-13 invoices each, spanning several
-- months). Found from a second real SAP screenshot (customer 10002440,
-- group 8501588763: 2 deposits totaling $25,099.70 against 5 invoices
-- totaling $25,446.69, balanced by an AB adjustment line). Checked whether
-- any deposit amount subset-sums to a specific invoice or invoice subset -
-- no clean match in any of the 4 groups, so per-invoice attribution here
-- would be exactly the kind of guess that got the original
-- fact_aplicacion_pagos deleted 2026-08-19 (a $137 document once appeared to
-- "explain" $2.5M of invoices in a similarly large group).
--
-- The real, validated signal: all 4 groups carry a document with
-- clase_documento='AB' (SAP's manual adjustment/reclassification type) as
-- their own self-referencing document - confirmed against ALL of July's
-- data, 100% correlation (the 23 groups resolved by the single-invoice rule
-- above have ZERO AB documents; these 4 have exactly one each). AB presence
-- is SAP's own signal that this compensation was manually reconciled as a
-- batch, not automatically matched - structurally different from every
-- other pattern this project has resolved so far.
--
-- Resolution: these groups are now INCLUDED (previously excluded entirely),
-- one row per payment (not fanned out per invoice - the invoice join is
-- suppressed specifically for these groups, see the JOIN condition below),
-- tagged 'LOTE_CONCILIACION' in clasificacion_cobranza with NO factura
-- columns populated (documento_factura/fecha_factura/fecha_vencimiento/
-- monto_factura/dias_pago all NULL - same treatment as SIN_FACTURA_
-- IDENTIFICADA, since there genuinely isn't one specific invoice to report
-- per payment). monto_pago_asignado falls back to the full payment amount
-- (same CASE branch already used for the no-invoice-at-all case) - the cash
-- now counts in any measure that sums monto_pago_asignado, without
-- pretending to know which invoice(s) each specific deposit covered.
-- Validated before implementing: recovers $166,221.23 across the 4 groups.
--
-- INNER JOIN -> LEFT JOIN on gold.fact_facturas_compensadas, 2026-08-29:
-- a payment with no matching invoice in its compensation group ("pago a
-- cuenta", confirmed with real July data: 1,411 of 1,426 such cases have
-- NO invoice or any other document at all sharing the group - genuine
-- cash with no due date to compare against) used to disappear from this
-- view entirely via the INNER JOIN, even when it was a real, fully valid
-- payment (same root investigation that led to the sgtxt fix in
-- gold.load_fact_pagos_compensados - see dwh-ciosa-project-status.md in
-- memory). Now it stays, tagged 'SIN_FACTURA_IDENTIFICADA' in
-- clasificacion_cobranza (MARKETPLACE still resolves to 'MARKETPLACE'
-- regardless of invoice presence, same as before). monto_pago_asignado
-- falls back to the full payment amount when there's no invoice to
-- prorate against (nothing to split).
--
-- REDESIGN 2026-08-30 (Power BI report rediseño, see powerbi/_brief/
-- pagos-cobranza-rediseno-analisis.md for the full architecture discussion):
--
-- 1. estatus_identificacion + motivo_no_identificado ADDED, replacing the
--    old approach of overloading clasificacion_cobranza with non-behavior
--    values (MARKETPLACE/CONTADO/SIN_FACTURA_IDENTIFICADA/LOTE_CONCILIACION
--    all lived in that one column). Named "identificacion", not
--    "conciliacion", on the user's explicit instruction: every payment in
--    this view already comes from silver.sap_bsad (already compensated/
--    cleared in SAP), never from bsid (open/not-yet-applied) - calling it
--    "no conciliado" reads as "still pending", which is never true here.
--    "No identificada" means only that THIS project couldn't attribute the
--    payment to one specific invoice with certainty - the cash itself is
--    never in question. A 2-physical-table design (separate fact_pagos vs
--    fact_conciliacion) was evaluated and explicitly rejected: real July
--    numbers (82.0% identificada/$137.4M, 10.4% no identificada/$17.5M,
--    7.6% correctly out of scope/$12.75M) showed monto_pago_asignado
--    already makes the mixed grain numerically safe (no fan-out risk) -
--    splitting into 2 tables would only add 2 SQL views + 2 Power BI
--    tables to keep in sync forever, for zero additional numeric benefit.
--
-- 2. clasificacion_cobranza renamed (CARTERA_VENCIDA->PAGO_A_VENCIMIENTO,
--    CARTERA_DEL_MES->PAGO_A_MES, PAGO_ANTICIPADO unchanged) - a pure
--    rename, the month-cohort date logic itself does NOT change (still
--    validated 2026-08-26, see the note further up). MARKETPLACE/CONTADO
--    are REMOVED as clasificacion_cobranza values entirely - tipo_cliente
--    is a customer attribute, not a payment-behavior classification, and
--    now lives only on gold.dim_cliente (imported directly into Power BI's
--    dim_cliente table, not through this view). A Marketplace/Contado
--    payment that DOES have an identified invoice now gets a real
--    PAGO_A_VENCIMIENTO/PAGO_A_MES/PAGO_ANTICIPADO value like any other
--    payment; one that doesn't gets NULL here (via estatus_identificacion
--    instead), exactly like any other unidentified payment.
--
-- 3. cliente_credito_sk ADDED (LEFT JOIN, same temporal-SCD2 pattern as
--    cliente_comercial_sk) so Power BI can relate this view to
--    gold.dim_cliente_credito for Ejecutivo de Crédito/Cobrador analysis -
--    this relationship never existed before (dim_cliente_credito was only
--    wired to fact_cartera). LEFT JOIN, not INNER: not every cliente_id has
--    a silver.sap_knkk record (documented gap in gold.fact_movimientos_
--    compensados's own history - ~135 cliente_ids, mostly non-credit
--    account types), so cliente_credito_sk can be legitimately NULL.
--
-- FECHA_PAGO / DIAS_PAGO / CLASIFICACION_COBRANZA rebased to fecha_contabilizacion
-- 2026-08-31: these 3 date-dependent outputs used p.fecha_documento since the
-- view's creation - a bug flagged during the 2026-08-30 redesign but deliberately
-- left unfixed that day. fecha_contabilizacion is the field already validated
-- (2026-08-29, see gold.fact_pagos_compensados's own column comment and
-- dwh-ciosa-project-status.md in memory) as the one that actually matches SAP's
-- own monthly payment report period - fecha_documento and fecha_compensacion were
-- both tried and ruled out for that same purpose. Validated against real July
-- 2026 data before applying: of the 12,177 payments that fall in July under BOTH
-- date bases, 0 change clasificacion_cobranza - the only effect is 43 payments
-- moving across the month boundary (22 leave July, 21 enter), a +$1.43M/+0.93%
-- shift in July's total (fan-out on those 43 payments' compensation groups
-- explains the larger +5.2% row-count shift). This is a pure relabeling: the
-- view's total row count and total monto_pago_asignado across all history are
-- unchanged, only which period-bucket each payment falls into shifts at the
-- margins.
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
    --
    -- ISNULL(k.rfc, 'SIN_RFC_'+k.cliente_id) agregado 2026-08-29: COUNT(DISTINCT k.rfc)
    -- ignora los NULL, asi que un grupo compuesto solo por un cliente MARKETPLACE
    -- (RFC NULL por diseno - Kushky, etc.) daba COUNT(DISTINCT rfc)=0, no 1, y la
    -- condicion HAVING =1 fallaba - excluyendo pagos reales de marketplace que se
    -- compensan solos, sin ninguna ambiguedad real. Confirmado con datos reales:
    -- $1,338,328.31 recuperados en julio (9 pagos), $0 perdido de lo que ya estaba
    -- bien (validado antes de implementar). El fallback por cliente_id preserva el
    -- proposito original de la regla: sigue excluyendo grupos que mezclan 2+
    -- identidades reales distintas, solo deja de tratar "un mismo cliente sin RFC"
    -- como si fueran 0 identidades. Ver dwh-ciosa-project-status.md en memoria.
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
)
SELECT
    p.cliente_id, -- the PAYER, not the invoice's own owner (f.cliente_id, not exposed) - confirmed 2026-08-26 this is intentional: the report groups by who paid, not by who originally owed the invoice. If that ever needs to change, f.cliente_id is available on the fact_facturas_compensadas join (f) already in this view.
    k.nombre,
    dc.canal_distribucion,
    dc.estatus_comercial,
    dc.id_surrogate        AS cliente_comercial_sk, -- added 2026-08-26: lets Power BI relate to gold.dim_cliente_comercial by key (star schema) instead of embedding canal_distribucion/estatus_comercial as plain text columns
    p.documento_id        AS documento_pago,
    p.fecha_contabilizacion AS fecha_pago, -- cambiado de fecha_documento 2026-08-31: fecha_contabilizacion es el campo validado contra SAP para el reporte mensual de pagos (ni fecha_documento ni fecha_compensacion coinciden con el periodo real de SAP - ver dwh-ciosa-project-status.md en memoria). Validado antes de aplicar: 0 de 12,177 pagos que se quedan en julio bajo ambas fechas cambian de clasificacion_cobranza; el efecto es solo 43 pagos moviendose por el borde del mes (+$1.43M / +0.93% en el total de julio).
    p.monto_moneda_local  AS monto_pago_virgen, -- repeats per row when the group has 2+ facturas - do not SUM() directly, see header warning
    CASE
        WHEN f.documento_id IS NULL THEN p.monto_moneda_local -- no factura to prorate against - nothing to split, the full payment counts once
        ELSE p.monto_moneda_local * f.monto_moneda_local / NULLIF(fpg.suma_facturas_grupo, 0)
    END                                        AS monto_pago_asignado, -- safe to SUM(): payment split proportionally across the invoices it settled
    f.documento_id        AS documento_factura,
    f.fecha_documento     AS fecha_factura,
    f.fecha_vencimiento,
    f.monto_moneda_local  AS monto_factura,
    DATEDIFF(DAY, f.fecha_vencimiento, p.fecha_contabilizacion) AS dias_pago, -- NULL when there's no factura (nothing to compare against) - negative = paid before due, positive = paid late. Base fecha cambiada a fecha_contabilizacion 2026-08-31 junto con fecha_pago, misma razon.
    dcr.id_surrogate       AS cliente_credito_sk, -- added 2026-08-30: LEFT JOIN, resolved by SCD2 in the ETL same as cliente_comercial_sk - lets Power BI relate Ejecutivo de Crédito/Cobrador to this view. NULL for cliente_ids with no silver.sap_knkk record (documented gap, see note above).
    -- estatus_identificacion/motivo_no_identificado added 2026-08-30 -
    -- see "REDESIGN 2026-08-30" note above for why these are named
    -- "identificacion", not "conciliacion".
    CASE WHEN f.documento_id IS NULL THEN 'FACTURA_NO_IDENTIFICADA' ELSE 'FACTURA_IDENTIFICADA' END AS estatus_identificacion,
    CASE
        WHEN f.documento_id IS NOT NULL THEN NULL
        WHEN g.num_pagos_candidatos > 1 AND ISNULL(fpg.num_facturas_candidatas, 0) > 1 THEN 'LOTE_CONCILIACION'
        ELSE 'SIN_FACTURA_IDENTIFICADA'
    END AS motivo_no_identificado,
    -- No NULL-guard on fecha_vencimiento for the PAGO_A_VENCIMIENTO/A_MES/
    -- ANTICIPADO branches: every invoice in this business is required to
    -- carry a due date, confirmed with real data 2026-08-26 (0 rows with
    -- fecha_vencimiento IS NULL). The only way f.fecha_vencimiento is NULL
    -- here is f.documento_id also being NULL (no factura identificada),
    -- already handled by the first branch below before these run.
    -- MARKETPLACE/CONTADO removed as values here 2026-08-30 - see
    -- "REDESIGN 2026-08-30" note above, that's tipo_cliente now (dim_cliente).
    CASE
        WHEN f.documento_id IS NULL THEN NULL -- no factura identificada - nothing to classify (see estatus_identificacion/motivo_no_identificado above)
        WHEN f.fecha_vencimiento < DATEFROMPARTS(YEAR(p.fecha_contabilizacion), MONTH(p.fecha_contabilizacion), 1) THEN 'PAGO_A_VENCIMIENTO' -- base fecha cambiada a fecha_contabilizacion 2026-08-31, misma razon que fecha_pago
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
LEFT JOIN gold.fact_facturas_compensadas f
    ON f.documento_compensacion = p.documento_compensacion
   AND f.ejercicio_compensacion = p.ejercicio_compensacion
   -- Suppressed for LOTE_CONCILIACION groups (see note above): forces
   -- f.* to NULL for these rows, which also means the LEFT JOIN produces
   -- exactly 1 row per payment here instead of fanning out per invoice.
   -- fpg (joined above, so it's already in scope here) still reflects the
   -- real invoice count for the clasificacion_cobranza CASE even though
   -- this join doesn't surface the invoice rows themselves.
   AND NOT (g.num_pagos_candidatos > 1 AND ISNULL(fpg.num_facturas_candidatas, 0) > 1)
INNER JOIN gold.dim_cliente_comercial dc
    ON dc.cliente_id = p.cliente_id
   AND p.fecha_documento BETWEEN dc.fecha_inicio_vigencia AND ISNULL(dc.fecha_fin_vigencia, '99991231')
LEFT JOIN gold.dim_cliente_credito dcr -- added 2026-08-30, see "REDESIGN 2026-08-30" note above - LEFT JOIN, not every cliente_id has a silver.sap_knkk record
    ON dcr.cliente_id = p.cliente_id
   AND p.fecha_documento BETWEEN dcr.fecha_inicio_vigencia AND ISNULL(dcr.fecha_fin_vigencia, '99991231')
INNER JOIN gold.dim_cliente k
    ON k.cliente_id = p.cliente_id
LEFT JOIN gold.dim_cliente kf
    ON kf.cliente_id = f.cliente_id
WHERE dc.canal_distribucion IN ('10', '40', '60')  -- '20' (menudeo) agregado y luego REVERTIDO 2026-08-27, mismo día: este DWH es explícitamente para mayoreo - canal 20 SÍ son clientes reales (por eso NO se tocó FUERA_DE_ALCANCE en vw_cliente_canal_estatus), simplemente están fuera de la misión de este reporte. Revertir esto también evitó tener que investigar CP (Cobranza POS) - ver dwh-ciosa-project-status.md en memoria para el hallazgo completo de por qué canal 20 casi no tiene DZ.
  AND dc.estatus_comercial <> 'FUERA_DE_ALCANCE'
  AND k.tipo_cliente <> 'SIN_RFC'  -- confirmado 2026-08-27 por un usuario clave del negocio: clientes sin RFC no son clientes reales, no deben entrar en análisis de cartera. Renombrado de DIRECCION_ALTERNA a SIN_RFC el mismo día (misma condición, solo cambia el nombre) - y las cuentas de marketplace/pasarela de pago que antes caían aquí (RFC nulo) ahora son tipo_cliente='MARKETPLACE' en vez de 'SIN_RFC', así que dejan de excluirse por esta condición.
  AND (kf.tipo_cliente IS NULL OR kf.tipo_cliente <> 'SIN_RFC');  -- kf.tipo_cliente es NULL cuando no hay factura (LEFT JOIN, 2026-08-29) - no debe excluir el pago por eso. Nota: ya NO hay exclusion por ambiguedad aqui - los grupos many-to-many (2+ pagos Y 2+ facturas) ahora se incluyen, etiquetados LOTE_CONCILIACION (ver nota arriba) en vez de excluirse por completo.
GO
