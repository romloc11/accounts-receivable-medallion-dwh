# `gold.fact_aplicacion` v2 — retired 2026-09-05 (archived record)

**This design is no longer active.** The five objects it describes
(`gold.dim_tipo_documento`, `gold.fact_facturas`, `gold.fact_notas`,
`gold.fact_pagos`, `gold.fact_aplicacion`) and their five loading procedures were
dropped from the server on 2026-09-05 (script:
`dwh_architecture/03_gold/drop_fact_aplicacion_v2.sql`), and their SQL files were
removed from the working tree. The user decided to re-approach the
application-of-money logic from scratch.

**Why this file still exists.** Most of what follows is *evidence*, not logic: the
BLART investigation, the SAP GUI verifications, real document numbers that
reproduce each shape, the July 2026 reconciliation against
`vw_pago_factura_simple`, and the honest re-examination of the v2 decision. That
research is expensive to recreate and is independent of whatever design replaces
it. The *rules* (R0–R6, the caps, the vehicle/origin/receiver roles) are recorded
here as history — read them as "what was tried and what each gate caught", not as
a specification to follow.

**Where the code went.** The retired SQL is recoverable from git history:
`ddl_fact_aplicacion.sql` and `sp_load_fact_aplicacion.sql` (commits `cf7f105`,
`ae50153`, `f55b6d2`), `backfill_fact_aplicacion_historico.sql` (`8f296d9`,
`7c20170`), `comparacion_fact_aplicacion_vs_vw_simple.sql` (`ae50153`),
`alter_llaves_y_medidas_bi.sql` (`4601142`, never run on the server).

**What survived in silver and is still live**: `clave_contabilizacion` (BSCHL) on
`sap_bsad`/`sap_bsid` and the application fields on `sap_bsid`, added by
`02_silver/alter_bsad_bsid_clave_contabilizacion.sql`. Those are source data, not
v2 logic, and any new design will want them.

---

### `gold.fact_aplicacion` — application-of-money fact, v2 strategy (designed and PROTOTYPED 2026-09-03)

**Status: ADOPTED (user decision 2026-09-04). v2 is the strategy going forward.** `gold.vw_pago_factura_simple` is *not* deleted: it stays as the dashboard's source until the operational work in "What is left before v2 replaces the view" is done, so there is a working reference to fall back on. Built and loaded for the July-2026-onward window, gated, compared against the view (Phase 7), then extended with rules R6 and the bounced-check exclusion (Phase 8). It is a parallel strategy to `gold.vw_pago_factura_simple` / `fact_pagos_compensados` / `fact_facturas_compensadas`, which stay untouched. Objects: `gold.dim_tipo_documento`, `gold.fact_facturas`, `gold.fact_notas`, `gold.fact_pagos`, `gold.fact_aplicacion` (plural names, user decision) — DDL in `03_gold/ddl_fact_aplicacion.sql` (**each section is DROP+CREATE: run only the section you need, never the whole file**), procedures in `03_gold/sp_load_fact_aplicacion.sql` (safe to run whole), comparison in `03_gold/comparacion_fact_aplicacion_vs_vw_simple.sql` (read-only). Phases 1–4 were run against `silver.sap_bsad`/`silver.sap_bsid`/`bronze.sap_bsid`; the numbers in the BLART table come from those queries.

#### Phase 6 — what was built, how it was gated (2026-09-03)

Every object was loaded with `EXEC gold.load_<x> '2026-07-01'` and had to pass a numeric gate before the next one was written:

| Object | Rows (Jul-2026 → today) | Gate |
|---|---:|---|
| `dim_tipo_documento` | 23 | 20 business-catalog types + Z4/ZZ/DI, `T003`/`T003T` values |
| `fact_facturas` | 278,979 | open rows = `silver.sap_bsid` exactly (71,529 / $378.19M); cleared = `bsad` window minus the 47 FBRA-reset duplicates where `bsid` wins; `anulada` = Z1 lines of the window (5,153); SCD2 99.8%; 0 open rows with `AUGBL` |
| `fact_notas` | 25,332 | same checks; `anulada` 6 C1 (Z2) + 12 C5 (Z3) |
| `fact_pagos` | 134,693 | July DZ cash reconciles to `fact_pagos_compensados` **to the cent by PK** once separated: identical money $166.07M; the old fact counts **$1.77M more** (123 child re-application lines = the same deposit twice in the month, 7 re-issues, 21 $0 lines) and **$0.06M of reversed/refund deposits**; v2 counts **$3.15M more** (deposits and direct payments without the validated `sgtxt`) plus **CP $34.64M** the old fact never had. `origen_efectivo` splits re-issued credits: `REEMISION_PAGO_SA` (cash re-issued from an SA 'PAGO%' credit, e.g. 'PAGO ATM-CIOSA' $12.75M) counts; `REEMISION_CREDITO` ($13.6M) and `REEMISION_AJUSTE_SA` ($1.96M, 'COMISIONES MELI') do not. |
| `fact_aplicacion` | 175,645 rows for the window | the three invariants at 0 (over-applied receiving documents, over-applied origins, duplicate pairs); cash conservation per origin (DZ $169,165,324 vs $169,165,263 in `fact_pagos`, $60 of rounding tolerance); the investigation's real cases reproduced (F4 `7404832874` = DZ $7,812.61 + AB17 $1,676.11 with origin C1 `3100754232`; deposit `1402626920` → child `1402626948` → 3 grandchild groups → 3 R1 rows; the 2-hop `1402621305` → `1402621328` → F4 `7404802497`; open partial payments as `BSID` rows) |

**What the gates changed in the design (each found by a failing invariant, fixed one at a time):**
- *Vehicle / origin / receiving* are three roles per row. A child's key-15 line, an AB key-17 line or a re-issued credit is the **vehicle**; the deposit or credit behind it is the **origin** (1 or 2 hops); the invoice is the **receiver**. Certainty of the application and certainty of the origin are independent.
- **R4** was added: exactly one candidate vehicle in the group and it covers what R1 left of every receiving document → each receiving document settled in full. Not proration — every row is a whole remainder. R3 keeps the other certain shape (several candidates that all fit in one receiving document).
- **Cumulative caps** per receiving document, per vehicle and per origin (the origin's own rows consume it first), all with a **$1.00 tolerance**: SAP posts rounding lines (AB 07 of $0.01), and chains re-apply $27,645.96 of a $27,645.93 deposit. A row that no longer fits loses its origin (`origen_resuelto=0`, `CADENA_AMBIGUA`) — it is never stretched.
- **Step 2e**: a payment line consumed by another DZ document's key-08 mirror **of the same amount** in the same group is not a candidate there — the mirror's document re-issues it through its own key-15 lines, which are. Only DZ mirrors: an SA 08/15 pair is the POS transit and there the CP line *is* the vehicle. A broader version ("anything cleared into a child-anchored group") was tried and dropped: the most common shape is {deposit, N invoices, child 08 carrying the leftover} and there the deposit is the vehicle.
- **Step 2f**: the anchor document's own key-15 line inside its own group, without `REBZG`, when another candidate exists, is the clearing's payment difference ($0.01 / $7.23), not an applicator (2,490 groups / $36.3M in July would otherwise be "ambiguous").
- **Re-issued credits are vehicles** even when they are not cash (`REEMISION_CREDITO`): their origin is the credit whose amount equals their key-08 sibling (or the single credit), traced one more hop if that credit is itself a child line.
- Cash origins are snapshotted before vehicles are removed, so a deposit that is not a vehicle anywhere still reports its unexplained remainder.

#### Phase 7 — July 2026, same customer scope as the view (canal 10/40/60, no `SIN_RFC`, no `FUERA_DE_ALCANCE`), DZ only

| | `vw_pago_factura_simple` | `fact_aplicacion` v2 |
|---|---:|---:|
| Payments / cash of the month | 12,195 / **$155,068,233** | 12,322 / **$154,851,609** |
| Identified | 11,857 / $144,963,319 (**93.5%**) | 12,045 / $143,588,820 (**92.7%**) |
| Both identify | 11,675 payments / $138.1M — identical invoice sets on 9,950; v2 finds *more* invoices on 1,704 (partial payments, notes, 2nd hops); the view more on 18; disagreement on 3 | |
| View identifies, v2 does not | 36 / $5.11M — 22 are Mercado Libre groups with SA commission netting (v2: `GRUPO_AMBIGUO`), the rest chains with 2+ candidate deposits | |
| v2 identifies, view does not | 284 / $4.68M (2-hop chains, AB re-applications) + 86 / $1.14M deposits the view does not carry at all | |
| Neither | 45 / $5.34M | |
| Counted as cash only by the view | 145 / **$1.69M**: 123 child re-application lines (the deposit already counted in the same month), 7 re-issues, 21 $0 lines | — |
| Reversed deposits counted | 1 identified ($28,942) + 3 not | 0 (excludes 33 more, $3.73M, that the view never had) |
| Unidentified by nature (payment gateways) | in the totals above | Kushky $4.98M (0% identified), Conekta $0.29M — `CADENA_AMBIGUA` / `SIN_DOCUMENTO_EN_GRUPO` |
| v2 unidentified, non-marketplace customers | | $1.06M of $142.4M (**99.3%** identified) |

Reading: both strategies agree on the cash of the month to within the double-counted child lines. Coverage is equivalent (93.5% vs 92.7%) — and the 0.8 points the view has on top are almost entirely Mercado Libre groups where a deposit is prorated across many invoices while SA commission credits sit in the same group, which is a guess the design forbids. v2 adds CP, open partial payments, 2-hop chains, AB credit re-applications, reversal exclusion, and a `regla`/`nivel_certeza`/`origen` on every row. **Recommendation: v2.** What remains before it can replace the view is operational, not analytical: historical backfill (2022→2026, by fiscal year), wiring into `gold.load_gold`, `clasificacion_cobranza` agreed with the business, and the `PASARELA` split (open item 4).

#### Phase 8 — what the residual unidentified population turned out to be (2026-09-04)

Phase 7 left $5.6M of July cash unidentified inside the view's scope. Reading the real documents in SAP (three cases the user pulled up in FB03) split that population into five patterns, and only two of them were worth a rule.

**Bounced checks are not cash.** A DZ carrying `sgtxt LIKE 'CHEQUE DEVUELTO%'` posts a key-11 credit and a key-01/05 charge that net to zero: the money never arrived. It was being counted as a virgin deposit and then reported as unidentified, which is doubly wrong. `tipo_linea='CHEQUE_DEVUELTO'` now takes precedence over every other classification in `fact_pagos`, with `origen_efectivo=NULL` and `es_efectivo=0`; a re-issue of a bounced check is not a vehicle either. July: 21 lines across 5 documents leave the cash (case `1402610262`, $3,287.01).

**Leftovers inside a child are their own motive.** When a deposit's child has applied everything it could and the remainder is sitting in an open line of that same child, the deposit is not ambiguous — it is partly unapplied. `SOBRANTE_EN_HIJO` (28 rows / $38,787 in July) separates that from real ambiguity. Case `1402610486`: $30,835.20 of $32,238.60 identified by R4 across 21 invoices, $1,403.40 still open in the child.

**Lot-level identification (R6).** The genuinely ambiguous cases are Mercado Libre multi-invoice/multi-note groups and merged-deposit children: SAP proves *which set* of invoices took the money, not which invoice took which peso. R6 records the set. It is deliberately a third status (`IDENTIFICADA_LOTE`), not `IDENTIFICADA` — a lot is evidence, not an application, and `monto_aplicado` still never lands on an invoice.

R6 was **wrong on first build and was tightened before adoption**: without a gate it marked $17.67M in July at an average lot size of **667 invoices**, and 426 of its 998 rows covered less than 50% of their lot. "This $300 entered one of 1,400 invoices" is noise wearing the label of a result, and it would have summed as identified in a dashboard — exactly what the "prefer `Pago no identificado`" principle exists to prevent. With the gate (`num_facturas_lote <= 20` **or** coverage `>= 50%`, both `DECLARE`d at the top of the R6 block so they can be re-tuned):

| July 2026, all customers | rows | amount |
|---|---:|---:|
| `IDENTIFICADA` | 85,206 | $190,597,188.98 |
| `IDENTIFICADA_LOTE` / `LOTE_EN_GRUPO` | 572 | $17,117,339.09 |
| `IDENTIFICADA_LOTE` / `LOTE_EN_HIJO` | 14 | $62,931.41 |
| `NO_IDENTIFICADA` / `CADENA_AMBIGUA` | 627 | $9,428,408.77 |
| `NO_IDENTIFICADA` / `GRUPO_AMBIGUO` | 1,786 | $3,350,354.29 |
| `NO_IDENTIFICADA` / `SIN_DOCUMENTO_EN_GRUPO` | 2,251 | $2,700,623.67 |
| `NO_IDENTIFICADA` / `ORIGEN_ABIERTO` | 573 | $820,467.21 |
| `NO_IDENTIFICADA` / `SOBRANTE_EN_HIJO` | 28 | $38,787.20 |

The gate returned $548,411.75 (426 rows) to `GRUPO_AMBIGUO`. Of the $16.3M of large-lot money that survives it, $12.75M is two deposits from a single `PADRE` customer that pay essentially a whole cleared group, and $3.7M is `MARKETPLACE`.

**R6 barely moves the business scorecard, and that is the honest headline.** Inside the view's scope (DZ virgins, channels 10/40/60, no `SIN_RFC`/`FUERA_DE_ALCANCE`) July ends at 10,937 deposits / $135,208,456 identified, 25 / $239,017 at lot level, and **166 deposits / $5,683,948 still unidentified** — the payment-gateway money (Kushky, Conekta) plus Mercado Libre groups, which no strategy can resolve from `bsad` alone. The big lots R6 does capture live outside that scope. R6 earns its place by being correct, not by improving the number.

All three invariants stayed at `0 | 0 | 0` through every iteration of this phase.

#### Re-examination of the decision, and the retirement criterion for the view (2026-09-04)

Designing the payment-behaviour report forced a second look at whether `fact_aplicacion` is
needed at all, and whether v2 really beats `vw_pago_factura_simple`. Two arguments that had
been used in its favour do not survive the data, and are retracted here:

- **"Without v2 you cannot know when the money actually arrived" — false.** The view already
  defines `fecha_pago` as `p.fecha_contabilizacion` of the *virgin* payment, i.e. the real
  deposit date, and already ships `dias_pago` and `clasificacion_cobranza`.
- **"v2 produces a better DPP" — not demonstrated.** Head to head on July 2026: the view gives
  −2.98 days (54,528 rows, weighted by `monto_pago_asignado`), v2 gives −1.09 (75,387 rows,
  weighted by `monto_aplicado`). The 1.9-day gap is driven by different populations, not by
  method — v2 covers 81,246 invoices against the view's 54,204 and includes CP. The gap was
  not decomposed, so neither number is asserted to be the correct one for a shared universe.

Related measurement, which is what makes the *date* matter at all: 90% of July's applied money
clears the same day its deposit was posted, so on the aggregate the choice of date moves DPP by
half a day (−0.55 by `fecha_compensacion` vs −1.05 by `fecha_origen`). At customer grain it is
a different story — 293 customers shift by 2+ days and some flip sign (one customer reads 6.5
days late by clearing date and 3.6 days *early* by deposit date). Aggregate KPIs are safe on
`fecha_compensacion`; anything a collector takes to a customer is not.

**What actually sustains the decision** is coverage and shape, not accuracy:

| | `vw_pago_factura_simple` | `fact_aplicacion` v2 |
|---|---|---|
| Invoices covered (July 2026) | 54,204 | **81,246** |
| Scope | DZ only | DZ + CP + notes + returns + AB credits |
| Open partial payments | no | yes |
| Proportional allocation (a heuristic) | yes | **no** |
| Double-counted child lines | $1.77M/month | none |
| Reversed deposits | included | excluded |
| Per-row traceability | none | rule + certainty + origin |
| Cost to query | recomputed over 4.7M rows | materialised |

An invoice settled by a credit note, or paid in instalments, is invisible in the view — which is
disqualifying for a payment-behaviour report specifically. And the view is a *report*: it answers
one question and cannot be extended. v2 is a *model* that shares dimensions with aging, open
receivables and notes.

**But today the view still does more for the collections report than v2 does**, because it has
five years of history and the derived columns. The decision is right and its timing is not yet.

**RETIREMENT CRITERION — do not drop `vw_pago_factura_simple` until v2 has all three:**

1. The historical backfill 2022→2026 complete (**both phases** — see below).
2. `dias_pago` computed on `fecha_pago_real`, plus `forma_liquidacion` (see the enrichment table).
3. `clasificacion_cobranza` agreed with the business.

Without all three, replacing the view is a functional regression for the only report currently in
production.

#### The enrichment that keeps analysts out of the bridge

Four columns on `fact_facturas`, computed from `fact_aplicacion` during the load. They are what
let the report be built on the document facts alone:

| column | derivation | why |
|---|---|---|
| `fecha_pago_real` | `MIN(fecha_origen)` over its `tipo_aplicacion='PAGO'` rows | correct DPP at customer grain |
| `forma_liquidacion` | `EFECTIVO` / `CREDITO` / `MIXTA` | excludes the 5,792 July invoices ($8.58M) settled with no cash, which otherwise count as payments |
| `monto_liquidado_efectivo` | `SUM(monto_aplicado)` where `tipo_aplicacion='PAGO'` | real collection vs credit |
| `dpp_confiable` | 1 when `fecha_pago_real` exists, else 0 | makes the fallback to `fecha_compensacion` visible instead of hiding it |

`fecha_origen` only exists for identified applications (~95% of cash); the rest falls back to
`fecha_compensacion` with `dpp_confiable = 0`.

Power BI cannot relate on the 5-column composite PKs the document facts carry, so the model also
needs deterministic single-column keys — `factura_key` / `pago_key` on the document facts and
`recibe_key` / `aplica_key` on `fact_aplicacion`, all built as
`sociedad|ejercicio|documento|posicion`. `(sociedad, ejercicio, documento_id, posicion)` was
verified unique without `cliente_id` on all three facts. Relationships stay single-direction from
each document fact to the bridge: `fact_aplicacion` already denormalises both sides, so the
drill-through table needs no bidirectional filtering. Do not `SUM(monto_documento_recibe)` at
application grain — it repeats per row; only `monto_aplicado` is additive there.

#### What is left before v2 replaces the view

1. Historical backfill 2022→2026 of `fact_facturas`, `fact_notas`, `fact_pagos`, `fact_aplicacion`
   — `03_gold/backfill_fact_aplicacion_historico.sql`, two phases, 9 half-year chunks each.
   **Phase B is not optional**: without application history there is no historical
   `fecha_pago_real`, and without that v2 cannot replace the view.
2. The four enrichment columns and the Power BI keys above.
3. Wire the five procedures into `gold.load_gold` (plain `EXEC` lines, in dependency order, only
   after each has run clean alone).
4. Agree `clasificacion_cobranza` with the business (open item 1 below).
5. The `PASARELA` / `MARKETPLACE` split (open item 4 below) — it is what makes "unidentifiable by
   nature" reportable separately from "we failed to identify it".
6. Retire the duplicate family once the above lands: `fact_facturas_compensadas` (4.7M rows),
   `fact_pagos_compensados` (616K) and `vw_pago_factura_simple`. Carrying two parallel families
   for the same question is the gold layer's biggest usability problem today — a newcomer cannot
   tell which to use. Also check `vw_cartera_abierta` for overlap: `fact_facturas` now carries
   open items at line level.
7. Cosmetic: `SIN_REGLA` still appears as a `motivo_no_identificado` value in the R6 filters
   although the loader no longer emits it.

#### How to consume `fact_aplicacion` (read this before building anything on it)

**It is not the collections ledger.** "How much did we collect" is answered by `fact_pagos`, never by summing `monto_aplicado`:

```sql
SELECT SUM(monto_moneda_local)
FROM gold.fact_pagos
WHERE tipo_linea = 'VIRGEN' AND revertido = 0 AND es_reembolso = 0
  AND fecha_contabilizacion >= @desde AND fecha_contabilizacion < @hasta;
```

Every peso that arrived is in that number whether or not we know which invoice took it. `fact_aplicacion` answers only the *next* question — which debt document the money settled — so identification never moves a collection total, only the invoice-level detail.

**The ambiguity is nine accounts, not a spread.** July 2026, by payer:

| `tipo_cliente` | unidentified | of total | share |
|---|---:|---:|---:|
| `MARKETPLACE` (9 customers) | $9,734,589 | $18,256,015 | **53%** |
| `PADRE` (713 of 3,713) | $3,432,565 | $142,739,237 | 2.4% |
| `GENERICO` | $1,707,063 | $36,099,997 | 4.7% |
| `FILIAL` | $1,187,557 | $26,743,985 | 4.4% |

3,234 customers come out **100% identified**; another 540 are under 5% ambiguous; only 61 are over 50%. The top of the unidentified list is Kushky $4.98M, six Mercado Libre accounts ~$4.2M, Conekta $0.29M. Remove the payment gateways and the fact is ~97% clean — which is why the `PASARELA` split (open item 4) is not cosmetic: it turns "ambiguous" (reads as a defect) into "unidentifiable by nature" (a legitimate reportable category). A gateway aggregates end-buyer money that never had a CIOSA invoice; no strategy resolves that from `bsad`.

**Two entry points, by question type.**

- *Money questions* start at `fact_pagos`. Identification is irrelevant there.
- *Invoice questions* (DSO, days-to-pay, payment behaviour) start at `fact_facturas` and join `fact_aplicacion` with an explicit status filter:

```sql
SELECT f.documento_id, f.fecha_vencimiento, MAX(a.fecha_aplica) AS fecha_pago,
       DATEDIFF(DAY, f.fecha_vencimiento, MAX(a.fecha_aplica)) AS dias
FROM gold.fact_facturas f
JOIN gold.fact_aplicacion a
  ON a.sociedad = f.sociedad AND a.documento_recibe = f.documento_id
 AND a.ejercicio_recibe = f.ejercicio AND a.posicion_recibe = f.posicion
WHERE a.estatus_identificacion = 'IDENTIFICADA'
GROUP BY f.documento_id, f.fecha_vencimiento;
```

That drops ~7% of the money and keeps only rows provable against SAP. **Publish the coverage next to the metric**: "DSO 34 days over the 93% of collections that are identified" is an honest claim; "DSO 34 days" alone is not.

**The three statuses are three different promises — never sum across them.** `IDENTIFICADA` = this invoice. `IDENTIFICADA_LOTE` = one of these ≤20 invoices (good for reconciling with the customer, not for DSO). `NO_IDENTIFICADA` = we do not know. A measure that adds them together silently converts evidence into a guess, which is the one thing this whole design exists to prevent.

**`NO_IDENTIFICADA` is a work queue for Credit & Collections, not a defect to hide.** Every `motivo_no_identificado` is actionable in SAP: `SOBRANTE_EN_HIJO` = money left unapplied inside the deposit's own child, `ORIGEN_ABIERTO` = payment still on account, `GRUPO_AMBIGUO` = someone cleared in bulk with no reference, `CADENA_AMBIGUA` = the chain has more than one candidate deposit. That breakdown is a deliverable in its own right.

**Known limitation while the window is only July-2026-onward.** Of the invoices cleared in July, 17,520 ($24.0M) carry no application row — but only 4,862 ($3.46M) are real ambiguity. The other 12,658 ($20.57M) are a pure window artifact: the document that paid them was posted before `2026-07-01` and is therefore not loaded. **Until the historical backfill runs, every invoice-side metric on July reads low.** Money-side metrics are unaffected.

#### Goal and grain

One row = **one monetary application between a document that applies money/credit and a document that receives it**, with the exact amount, the SAP evidence it came from, and the rule that produced it. `DZ001 → F1001 = 50,000` and `DZ001 → F1002 = 30,000` are two rows. A payment SAP cannot tie to a specific debt document with certainty still gets a row, with the receiving side `NULL` and `estatus_identificacion='NO_IDENTIFICADA'` — never a guessed match (same "don't guess" principle as `vw_pago_factura_simple`, kept deliberately).

Named `fact_aplicacion`, not `fact_aplicacion_pago`: the receiving side is settled by cash (DZ/CP) **and** by credit notes, returns, and credit-balance offsets. Restricting the fact to cash makes the "invoice + credit note + payment" case (invoice $100K = DZ $60K + C5 $40K) unexplainable — the C5 side is exactly as traceable in SAP as the DZ side (87% of C5 lines carry `REBZG`). The retired `gold.fact_aplicacion_pagos` (see "Retired objects") had this same taxonomy; **it was removed because of its matching rules, not because of the taxonomy** — the matching rules here are different (see "Application rules").

#### What the data says about each document type (the investigation, summarized)

Full history of `silver.sap_bsad`, 2022-01-01 to 2026-09-02, unless noted. "Self-referencing" = the line's `documento_compensacion` equals its own `documento_id` — i.e. the document is itself the clearing document that anchors the group.

| BLART | Rows | Verdict | Evidence |
|---|---:|---|---|
| F1–F5 | 4.7M | debt (receiving side) | as already modeled; **F6 has 0 rows anywhere** (bronze/silver, bsid/bsad) — catalogued but never used |
| D1 | 827 | **debt**, not a credit note | $2,718,959.70 on `S` vs $1,390.02 on `H`; 0 self-ref, 0 `REBZG`; appears as the *target* of DZ (330 groups), AB (413), C5 (225). It belongs next to invoices, not next to C-types. |
| C1/C3/C4/C5 | 547K | reduce debt (applying side) | `REBZG` on 95% / 100% / 99.7% / 87.5% of lines; **0 self-reference** — they never anchor a group, they always point at the document they affect |
| DZ | 1.69M | cash (applying side) | virgin → child (→ grandchild) chain, already documented under `gold.fact_pagos_compensados` / `vw_pago_factura_simple`. The only type that needs a multi-hop rule; the only place the retired fact over-attributed. |
| CP | 1.62M | cash (applying side), **structurally the cleanest payment type** | 93.8% of lines carry `REBZG` (1,503,392 resolve to F5, 17,477 to C4, 338 to F4, 105 to F1); 5 real samples match the referenced invoice to the cent. No virgin/child chain. **But 99.6% of CP cash ($1,513.9M of $1,519.5M) belongs to channel 20** (`VENTAS DE MOSTRADOR 3xx` counter-sale accounts, `tipo_cliente=GENERICO`) — real cash, almost entirely outside this DWH's mayoreo scope. Decision (2026-09-03): CP goes into the payment fact anyway; scope is applied downstream in views, same rule as `fact_saldo_cartera`. |
| AB | 595K | **the document FB1D creates; its role is given by the posting key (`BSCHL`), not by text** | Verified in SAP GUI 2026-09-03 (`CódT=FB1D` "Compensar deudor", posted by credit executives, e.g. `EJECXC6`). By `BSCHL`: **07/17 with amount $0.00** = 304,446 lines (51%) — the pure clearing anchor (07 on the customer + a $0.00 FX-difference GL line), never money; **07 with amount** (138K / $736M) = consumes an existing credit (clears a C1/C5/DZ-on-account/pool item in its own group); **17 with amount** (142,738 / $730M) = **re-applies that credit** — 65,590 lines / $164.6M carry `REBZG` straight to an invoice (F4 56K, F1 9K), 41,525 / $91.4M are same-customer re-postings (`SOBRANTE DE NC`: 17 + 07 on the same account, net zero, applied later in another group), 647 / $6.4M cross-account transfers, 34,010 / $459.2M without `REBZG` or a same-amount twin (a credit split across several invoices in one document — resolved by group in Phase 6); **15** (3,740 / $3.0M) = credit balance applied from the pool customer account `10006317 SALDO A FAVOR CUENTAS` (`COMPENSACION DE SALDOS A FAVOR`; note this pool account has prefix `1` and is *not* a customer); **01/11/04/14** (232 lines) = manual invoice/credit-memo postings, negligible. Real end-to-end case: F4 `7404832874` $9,488.72 = DZ `1402657848` $7,812.61 (key 15, `REBZG`) + AB `8501607231` line 17 $1,676.11 (`REBZG`), where that AB's line 07 consumed C1 `3100754232` $1,676.11 (a return originally issued against a *different* invoice) — anchored by AB `8501607232` $0.00. Only 9,022 rows / $22.4M are fully opaque. **Not a fact of its own**; enters `fact_aplicacion` through rule R5 below. |
| Z1 / Z2 / Z3 | 100K / 276 / 4K | cancellation, **an attribute of the cancelled document, not a fact** | 99.65% / 96.7% / 99.5% self-referencing; the cancelled document shares the Z-document's own group at the identical amount (Z1↔F5 in 99,121 of 100,214 groups — almost never F1–F4; Z3↔C5 in 4,162 of 4,182; Z2↔C1/C4). Real case: F4 `7402683089` $879.80 and Z1 `9810110193` $879.80, same group. Modeled as `anulada`/`documento_anulacion`/`fecha_anulacion` columns on the cancelled document's fact, so a cancellation can never be mistaken for an invoice or a payment and never produces an application row. |
| ZY | 430 | **excluded — not a customer payment** | 100% of its 30 customers have `cliente_id` prefix `9` (`FUERA_DE_ALCANCE`, "not real customers", business-confirmed 2026-08-27); `sgtxt` = `COMPENSACION TC <person>` (corporate credit-card reconciliation). No rows since 2025-06-30. The catalog's `PAGO` label was wrong for this type. `T003.KOARS='DKS'` explains the name: "D y K" = *Deudores y Kreditoren* — the only payment type allowed to post to vendors, hence its use for card reconciliation. |
| SA | 2.98M | **excluded, except `REEM*`** | 93% self-referencing, 99% no text; co-occurs with CP (1.4M groups) and F5 (1.38M) as a technical transit account inside the POS settlement flow. Where it has text: marketplace commission adjustments (`AJUSTE COMISION MERCADO LIBRE/AMAZON`), balance clean-up (`DEPURACION SALDO …`), refunds (`REEMBOLSO CTE …`, the `REEM*` pattern already handled in `vw_pago_factura_simple`). Same exclusion already applied to `fact_saldo_cartera`/`vw_cartera_abierta`. |
| SI | 0 in bsad, 1 in bsid (2015) | out of the data window | opening balances predate the 2022-01-01 backfill floor; nothing to model |
| ZZ / DI | 194K / 2 | **ZZ = FB08 reversal document of an SA — never touches `fact_aplicacion`** | `T003T`: ZZ = "Doc. Anulacion", DI = "Dist. Ingresos POS". Verified in SAP GUI 2026-09-03: all three sampled ZZ have `CódT=FB08` and "Doc. anulado" filled, and the reversed document is always an SA. At scale, the 97,584 groups anchored by a ZZ contain **only ZZ + SA** (193,924 / 193,840 lines) and **100% balance to zero**. 96,208 of 97,623 ZZ documents are a 05/18 pair on a `VENTAS DE MOSTRADOR` store account posted by the POS interface user (`USRINTERFAC6`) — a cancelled POS receipt; the few with text (`RET MELI` = month-end accrual reversal by `CONTAGENERAL`, `DEUDOR …` = reversal of an "Otros Ingresos" recognition) are manual reuse of the same type. DI is 2 rows, one self-cancelling pair. |

Compensation mechanics, confirmed: `(documento_compensacion, ejercicio_compensacion)` is a shared group key, not a pointer chain, and **which type anchors the group is predictable**: CP/C1–C5/D1 never anchor (they point at their invoice via `REBZG`); AB/Z1/Z3/SA are almost always the anchor; DZ is mixed (the virgin points at its child; the child usually anchors). Sharing `AUGBL` is never, on its own, proof of an exact monetary application.

**Reversal map, from `T003.STBLA` (SAP GUI, 2026-09-03):** F1–F6 → Z1 · C1/C3/C4 → Z2 · C5 → Z3 · D1 → Z4 (0 rows ever: no debit note has been reversed) · SA/SI/ZY → ZZ · **AB → AB · DZ → DZ · CP → CP** · Z1/Z2/Z3 → none. The last three matter: a reversed payment is **not** detectable by "anchor is a Z-type". SAP leaves the signal in the posting key instead — the reversal of a customer line uses the paired key (11→02, 15→05, 01→12, 08→18…), and FB08 clears original + reversal together in a group anchored by the reversal, netting to zero. Verified: DZ `1402655199` (key 05, `CódT=FB08`, reverses `1402654005`) and CP `8903330882` (key 05, `FB08`, POS interface user, reverses `8903330873`). Volume: **DZ reversal-shaped groups 3,907 / $113.8M; CP 99,597 / $122.0M** — real cash that must leave every total, both sides. `XSTOV` is blank on all 12.45M `bsad` lines, so the group + posting-key shape is the only signal available without `BKPF`.

**`REBZG='V'` (F1 help, SAP GUI 2026-09-03):** for credit items ("abonos") carrying `V`, "the due date is determined as if the item were an invoice" — i.e. **no document reference at all**, own due date. The virgin deposit is posted by the in-house program `OS_APPLICATION` (via `BKPFF`, user `COORDCXC3`) as bank debit (key 40) + customer credit (**key 11**, `REBZG='V'`): 561,521 of 567,395 key-11 DZ lines ($8.33B) carry `V`. Rule: `V` is treated as an empty reference (payment on account — the prompt's Case 8, not Case 6). Separately, **325,827 DZ key-15 lines carry a real `REBZG`** — those resolve by R1 directly, with no chain walking; the virgin→child chain is only needed for what has no reference.

#### Source tables

`BSAD` (cleared) and `BSID` (open) are transparent SAP tables, both reachable through `P01`. `BSEG` is a cluster table (`RFBLG`), not readable by SQL on the `p01` replica — see the note in `01_bronze/ddl_bronze.sql`; extracting it would need an ABAP-level extractor. Everything this design needs is in `BSAD`+`BSID`: amounts, clearing key, the native invoice reference (`REBZG`/`REBZJ`/`REBZZ`), line text, document type, dates, customer, currency. No other SAP table is required.

**`BSID` is a source, not just `BSAD` (decision 2026-09-03).** A partial payment in progress lives only in `BSID`: real case, DZ `1401297899` $400,000 open with `REBZG` → F2 `7200000783` $606,818.21, also open — neither exists in `bsad`, so a `bsad`-only fact can never show "$400,000 applied, $206,818.21 pending". `bsid` also holds 5,244 open C1 (4,789 with `REBZG`) and 601 open C5. All three document facts below therefore read `bsid ∪ bsad`, and the receiving side of an application can be an open invoice.

**Silver prerequisites — DONE on the server 2026-09-03** (`02_silver/alter_bsad_bsid_clave_contabilizacion.sql`: ALTER + `silver.load_silver` + year-chunked backfill, 2025 split in halves after a `Msg 9002`; final distribution by posting key matched the bronze counts exactly, 0 NULLs). Original requirement, kept for the record: (1) `silver.sap_bsid` lacks `sgtxt` and `factura_referencia_documento/ejercicio/posicion` (`REBZG/REBZJ/REBZZ`) — both exist in `bronze.sap_bsid`; (2) **neither `silver.sap_bsad` nor `silver.sap_bsid` carries `BSCHL` (posting key)** — after the GUI verification it is the single most informative field for this design (it decides AB's role, detects reversals, and separates the virgin deposit (11) from a referenced payment (15) and from the child mirror (08)). Add `clave_contabilizacion` to both. All additive; `bsid` is truncate+reload (no history), `bsad` needs the column added and backfilled from bronze by fiscal year (same 2GB-log discipline). Touches none of the protected objects. `fecha_registro_sistema` (`CPUDT`) already exists in both and should be carried into the facts: manual clearings are often entered days after their posting date (AB `8501488885`: posted 02.01, entered 19.01).

#### Tables

Names avoid `fact_facturas` / `fact_pagos`: those were the *previous* names of `fact_facturas_compensadas` / `fact_pagos_compensados` (renamed 2026-08-21) and their orphaned load procedures had to be cleaned up once already. The `fact_doc_*` prefix says "every document of this family, open or cleared".

**`gold.dim_tipo_documento`** — small conformed *type* dimension (one row per BLART), **not** one row per document (document numbers stay on the facts as degenerate dimensions; a 12M-row "dim_documento" would be an anti-pattern). Columns: `clase_documento` (PK), `descripcion_sap`, `descripcion_anterior`, `familia` (FACTURA / NOTA_DEBITO / NOTA_CREDITO / DEVOLUCION / PAGO / AJUSTE / ANULACION / TECNICO / SIN_CATALOGAR), `signo_esperado` (S/H), `es_ancla_compensacion` (AB/Z1/Z3/SA = 1), `en_alcance_aplicacion` (ZY/SA/SI/ZZ/DI = 0), `nota` (free text for the findings above). Relates directly to every fact; `dim_cliente` also relates directly to every fact (no snowflake through the type dimension).

**`gold.fact_doc_factura`** — F1, F2, F3, F4, F5, **D1** (debt documents). Grain = 1 `bsid`/`bsad` line. Key: `sociedad, cliente_id, ejercicio, documento_id, posicion`. Columns: `clase_documento`, `estado_sap` (ABIERTO / COMPENSADO / REVERTIDO), `fecha_documento`, `fecha_contabilizacion`, `fecha_vencimiento` (already corrected to `ZFBDT + ZBD1T`), `condicion_pago`, `dias_plazo`, `monto_moneda_local`, `monto_moneda_doc`, `moneda`, `documento_compensacion`, `ejercicio_compensacion`, `fecha_compensacion` (NULL while open), `documento_ventas`, `referencia`, `asignacion`, `anulada` (bit), `documento_anulacion`, `fecha_anulacion` (from Z1, matched by shared group + identical amount), `cliente_comercial_sk`, `cliente_credito_sk` (temporal SCD2 join on `fecha_contabilizacion`, same pattern as `vw_pago_factura_simple`).

**`gold.fact_doc_nota`** — C1, C3, C4, C5 (applying side, all `H`). Same key and state columns as above, plus `factura_referencia_documento/ejercicio/posicion` (`REBZG`), `sgtxt`, `anulada`/`documento_anulacion` (from Z2 for C1/C4, Z3 for C5).

**`gold.fact_doc_pago`** — DZ, CP (cash, applying side). Same key and state columns, plus `clave_contabilizacion`, `sgtxt`, `factura_referencia_*`, `es_pago_virgen` (DZ: posting key 11 — with `sgtxt='Asignación Aut. Deposito' OR sgtxt LIKE 'BB%'` and `debe_haber<>'S'` as the validated text safeguard; CP: every key-15 line is a real receipt), `documento_hijo`/`ejercicio_hijo` (DZ virgin's `documento_compensacion`), `es_reembolso` (the `SA`/`REEM*` exact-amount exclusion, same rule as `vw_pago_factura_simple`), **`revertido`/`documento_reverso`** (see "Reversal map" above: the document's group is exactly itself + one same-type document with the paired reversal key, netting to zero). Includes the DZ child/grandchild lines too (key 08 mirror + key 17/18 applied lines, needed to walk the chain) flagged `es_pago_virgen=0`, so `SUM(monto) WHERE es_pago_virgen=1 AND revertido=0 AND es_reembolso=0` is the real cash figure.

All three `fact_doc_*` tables carry `clave_contabilizacion`, `fecha_registro_sistema`, `revertido` and `documento_reverso`.

**`gold.fact_aplicacion`** — the deliverable. Surrogate `id_aplicacion` (IDENTITY; the natural key has NULLs on unidentified rows). Columns:
- applying side: `documento_aplica`, `ejercicio_aplica`, `posicion_aplica`, `clase_documento_aplica`, `cliente_pagador_id`, `fecha_aplica` (= `fecha_contabilizacion` of the applying document — the field confirmed to match SAP's own period bucketing), `monto_documento_aplica` (full amount of the applying document, repeated per row — **never sum it**)
- receiving side (NULL when unidentified): `documento_recibe`, `ejercicio_recibe`, `posicion_recibe`, `clase_documento_recibe`, `cliente_factura_id`, `fecha_factura`, `fecha_vencimiento`, `monto_documento_recibe`
- measure: **`monto_aplicado`** — the only additive amount
- classification: `tipo_aplicacion` (PAGO / NOTA_CREDITO / DEVOLUCION / CREDITO_REAPLICADO / SALDO_A_FAVOR), `estatus_identificacion` (IDENTIFICADA / NO_IDENTIFICADA), `motivo_no_identificado` (SIN_DOCUMENTO_EN_GRUPO / GRUPO_AMBIGUO / CADENA_AMBIGUA / SALTO_NO_RESUELTO / SIN_REGLA), `documento_origen_credito`/`ejercicio_origen_credito` (R5 only)
- traceability (the whole point): `documento_compensacion`, `ejercicio_compensacion`, `fuente_sap` (BSAD / BSID / BSAD+BSID), `regla` (code from the table below), `nivel_certeza` (1 = SAP's own pointer, 2 = group balances exactly, 3 = chain resolved unambiguously)
- `sociedad`, `moneda`, `cliente_comercial_sk`, `cliente_credito_sk`
- `clasificacion_cobranza` (PAGO_ANTICIPADO / PAGO_A_VENCIMIENTO / PAGO_A_MES) is **not** in this table yet — the prompt of 2026-09-03 explicitly asks to define it with the business first. `fecha_aplica`, `fecha_factura`, `fecha_vencimiento` are all here so it can be a view or added later without changing the grain.

#### Application rules (one per evidence type, in order of certainty)

| Rule | Applies to | How the amount is determined | Never does |
|---|---|---|---|
| **R1 — REBZG direct** (certainty 1) | CP, C1, C3, C4, C5, and any DZ/AB line carrying `REBZG` | `monto_aplicado` = the applying line's own amount, capped at the receiving document's remaining amount. Receiving doc = `(REBZG, REBZJ, REBZZ)`, looked up in `fact_doc_factura` (open or cleared). | never splits one line across several invoices — `REBZG` points at exactly one |
| **R2 — cancellation / reversal** | (a) Z1 / Z2 / Z3 / ZZ anchors; (b) DZ, CP, AB groups made of exactly the original + one same-type document with the paired reversal posting key (02/05/12/18…), netting to zero | not an application: sets `anulada=1` (a) or `revertido=1` (b) on the original, records `documento_anulacion`/`documento_reverso`; both documents are excluded from every amount | never produces a row in `fact_aplicacion`; never applies (b) when the group has a third document |
| **R3 — single-invoice group** (certainty 2) | any group with exactly 1 receiving document and 1+ applying documents (no `REBZG`) | every applying document applies its full amount to that one invoice — there is nothing to mis-attribute (this is the gate already validated on 2026-08-29 in `vw_pago_factura_simple`) | never used when the group has 2+ receiving documents |
| **R4 — DZ virgin → child → invoice** (certainty 3) | DZ virgins whose child group contains receiving documents | walk `documento_hijo`; inside the child group apply R1 if `REBZG` present, else R3. A 2nd hop (child cleared further, exactly one onward group) is followed once, same as the 2026-09-03 `salto_h` logic in `vw_pago_factura_simple`; 3+ hops → `SALTO_NO_RESUELTO` | never allocates proportionally (see below) |
| **R5 — AB credit re-application** (certainty 1 with `REBZG`, 2 by group) | AB lines with **posting key 17 or 15 and amount > 0** (never by text) | R1 if `REBZG` (65,590 lines / $164.6M), else R3 on the line's own group; `tipo_aplicacion='CREDITO_REAPLICADO'` (key 17) or `'SALDO_A_FAVOR'` (key 15, pool account `10006317`). `documento_origen_credito` = the document(s) cleared by the same AB's key-07 twin line in *its* group (C1 `3100754232` in the real case) — recorded when that group has exactly one credit document, else `NULL`; origin certainty is independent of application certainty | never applies a $0.00 line, a key-07 line, or a same-customer 17/07 re-posting pair on its own (that credit applies later, in the group where the 17 line is finally cleared) |
| **R6 — identified at LOT level** (certainty 3, added 2026-09-04) | R0 rows whose money demonstrably entered a *set* of invoices, but whose split per invoice is not unique | two shapes. (a) `LOTE_EN_GRUPO`: the unidentified money of a cleared group fits in what that group's invoices have left after every identified row of the group. (b) `LOTE_EN_HIJO`: K deposits merged into one child whose lines are all applied or still open and together account for those deposits. Both keep `documento_recibe` NULL and record the lot instead (`documento_lote`, `ejercicio_lote`, `num_facturas_lote`, `monto_facturas_lote`), `estatus_identificacion='IDENTIFICADA_LOTE'`. **Bounded-ambiguity gate:** only accepted when `num_facturas_lote <= @lote_max_facturas` (20) **or** the money covers `>= @lote_min_cobertura` (50%) of the lot | never attributes anything to a single invoice; never calls it identified when the ambiguity is unbounded — "$300 somewhere inside 1,400 invoices" goes back to `NO_IDENTIFICADA` |
| **R0 — unidentified** | everything that survives none of the above | row with receiving side NULL, `monto_aplicado` = the applying document's amount, `motivo_no_identificado` set | never invents a match |

**Deliberate difference from `vw_pago_factura_simple`: no proportional allocation.** `monto_pago_asignado` there splits one payment across N invoices by invoice weight — safe for summing, but it is a heuristic, and this fact promises "the amount SAP lets us prove". When a group has M payments and N invoices and no `REBZG` on either side, the correspondence is genuinely unknowable and every payment in it goes to R0 with `GRUPO_AMBIGUO` — less coverage, no invented rows. The 4 July-2026 `LOTE_CONCILIACION` groups ($166K) are exactly this case and stay unidentified here too.

**Invariants R1–R5 rely on, to assert in Phase 6 before trusting any output:**
1. Every cleared group balances: `SUM(S) = SUM(H)` per `(documento_compensacion, ejercicio_compensacion)` in `bsad` — SAP's definition of clearing. Not yet verified on this data; if it fails for some groups, those groups are excluded, not patched.
2. `SUM(monto_aplicado)` per applying document ≤ that document's amount, and per receiving document ≤ its amount (the two "no more money than available" checks from the prompt's section 18).
3. One `(documento_aplica, posicion_aplica, documento_recibe, posicion_recibe)` pair appears at most once.
4. `cliente_pagador_id` and `cliente_factura_id` share an RFC (the single-identity safeguard already in `vw_pago_factura_simple`), otherwise `GRUPO_AMBIGUO`.

#### Load pattern

- The three `fact_doc_*` tables are loaded from `silver.sap_bsid ∪ silver.sap_bsad` with **explicit steps, not `MERGE`** (the only pattern that has been reliable on this SQL Server 2012 instance): (1) stage current+previous month into a temp table, (2) `UPDATE` by PK — a document that moved from `bsid` to `bsad` keeps its PK and gets `estado_sap='COMPENSADO'` plus the clearing columns, (3) `INSERT` new PKs, (4) any row present in the fact as `ABIERTO` but absent from both sources → `estado_sap='REVERTIDO'`, **never deleted** (it may already have rows in `fact_aplicacion`). Historical backfill by fiscal year, separately, same 2GB-log discipline as `silver.sap_bsad`.
- `fact_aplicacion` is rebuilt for the same current+previous-month window from the three document facts, deleting and re-inserting the window (applications change when a partial payment gets its next instalment). Its `BSID`-sourced rows are a picture of today, not history — a trend of "how was this invoice's application 3 months ago" would need a snapshot fact, same argument as `fact_saldo_cartera`.
- One stored procedure per object, none calling another (the `control.sp_log_load` lesson), orchestrated by adding plain `EXEC` lines to `gold.load_gold` only after each procedure has run clean on its own.

#### Reconciliation plan (Phase 7, before anything replaces the current view)

Against SAP: total of DZ+CP virgins per month by `fecha_contabilizacion` = the SAP "pagos del mes" export (the field already proven to match). Against `gold.vw_pago_factura_simple`, read-only, same July-2026 slice used throughout that view's own history ($155,068,233.10 as of 2026-09-03): payments matched by both / only by the view / only by v2, amount and invoice differences, duplicates, partial payments, multi-invoice groups, unidentified payments, and the AB / CP / ZY populations specifically. The goal is stated in the prompt and kept here: decide which strategy represents SAP better, not prove the current view wrong. Expected in advance: v2 identifies **fewer** payments than the view on multi-invoice groups (no proration) and **more** on CP and on open partial payments (the view has neither).

#### Questions resolved in SAP GUI (2026-09-03, FB03 / SE16 T003 / T003T / F1)

1. **AB** — resolved by posting key, see the BLART table and R5. No business decision needed anymore: the anchor lines carry $0.00, the re-application lines carry `REBZG` or resolve by group, and the "saldo a favor" flow is a manual FB1D by credit executives against pool account `10006317`.
2. **ZZ** — FB08 reversal of SA, always; excluded. See the BLART table.
3. **`REBZG='V'`** — "no invoice reference, own due date"; treated as empty. See "Compensation mechanics".
4. **Reversals** — no `BKPF` needed: original + reversal always share a group anchored by the reversal, net zero, paired posting keys. See "Reversal map" and R2(b). `BKPF` (`TCODE`, `USNAM`, `STBLG`) was still the only way to *see* who/what generates each document during this investigation — the note in `01_bronze/ddl_bronze.sql` saying it has no consumer is now only true for the pipeline, not for analysis; sourcing it stays optional.

#### Still open

1. **`clasificacion_cobranza`:** the three labels (`PAGO_ANTICIPADO` / `PAGO_A_VENCIMIENTO` / `PAGO_A_MES`) are deliberately not defined here — the month-cohort vs exact-day question was quantified on 2026-08-26 for the current view (<4% either way) but has to be re-agreed with the business for this fact, which now also covers open partial payments.
2. **Documents that vanish from `bsid` without reaching `bsad`:** with the reversal mechanics now understood (a reversal always lands in `bsad` together with its original), a document missing from both sources is most likely an archived or re-keyed item, not a reversal — confirm with a real case before deciding between `REVERTIDO` and a different status name.
3. ~~**AB key-17 lines without `REBZG` and without a same-amount twin (34,010 / $459.2M):** quantify how many resolve by R3 vs. stay `GRUPO_AMBIGUO`.~~ Resolved in Phase 6: they resolve through R3/R4 in their own group; what remains is in the `GRUPO_AMBIGUO` line of the Phase 8 table.
4. **`PASARELA` vs `MARKETPLACE` in `gold.dim_cliente.tipo_cliente` (backlog, approved 2026-09-03):** the single `MARKETPLACE` value today covers two different behaviours. Payment gateways (Kushky, Conekta, Openpay "INGRESOS TRANSITORIA", Mercado Pago) receive aggregated end-buyer money and clear DZ against DZ or SA with no customer invoice — unidentifiable by nature, for any strategy. Marketplaces proper (Amazon, Mercado Libre and variants, Claro Shop) hold real F4 invoices and their payments are identifiable like anyone else's (with `SA "COMISIONES MELI"` netting in between). Splitting them is a small additive change to `dim_cliente` and its load — deliberately outside this design's scope; until then the Phase 7 scorecard breaks unidentified cash down by account name inside `MARKETPLACE`.
5. **`vw_pago_factura_simple` and reversed deposits (outside this design's scope, flagged only):** its virgin filter (`sgtxt` text + `debe_haber<>'S'`) admits a reversed virgin (key 11, with text) and nothing removes it, because the reversal line (key 02, `S`) is filtered out — the 537 key-02 lines / $17.9M are the upper bound of the effect. Measure before touching that view; not part of this proposal.

Decisions already taken on 2026-09-04: **v2 is adopted**; `vw_pago_factura_simple` is kept, not deleted, until the operational list above is done; ambiguity is reported at lot level (`IDENTIFICADA_LOTE`) only when it is bounded; bounced checks are not cash.

Decisions already taken on 2026-09-03: one general `fact_aplicacion` (not cash-only); CP is included even though 99.6% of it is channel 20; D1 sits on the debt side; `bsid` is a source for all three document families; AB enters only through R5 by posting key; ZY, ZZ, SA (except `REEM*`) and every reversed pair are out.
