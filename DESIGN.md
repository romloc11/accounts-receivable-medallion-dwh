# Design Decisions — Gold Layer

This document explains the *why* behind every table, view, and modeling decision in the Gold layer — not just what exists, but what alternatives were discarded and why. The code already has extensive inline comments (`dwh_architecture/03_gold/*.sql`); this document organizes them into a coherent narrative for someone who didn't live through the design process.

## General principle: when a table, when a view?

Four questions, in order, decide whether a Gold-layer object should be a physical table or a view:

1. **Will something else store a permanent key pointing to this?** If a fact needs a stable FK that survives even if the source data changes tomorrow (an SCD2 surrogate key), it has to be a table — a view has no memory of its own, it can't preserve "this was March's version" once the source data has changed.
2. **Does the source already retain the history I need, or does it get overwritten and I have to accumulate it myself?** If the source is a complete daily mirror with no history (like `silver.sap_bsid`), and you need a trend over time, it has to be a table — the table is what accumulates what the source doesn't retain.
3. **Is filtering/joining the source expensive on every query, and will something query it often?** Even if the source already has history (like `silver.sap_bsad`, which does retain everything), if the filter/join is expensive and a dashboard is going to hit it repeatedly, materializing it into a table with its own index is a valid performance decision — not architecturally mandatory, but practical.
4. **If none of the three apply** — it's just re-arranging/filtering/joining data that's already materialized somewhere else, with no new identity and no need to accumulate — **it's a view**. Recomputing it on every query is cheap and keeps the business logic (which tends to keep evolving) separate from the heavy physical tables.

A fifth question, mostly for ratios/percentages: **will this only ever be consumed from Power BI?** If so, it shouldn't even be a SQL object — it should be a DAX measure. Averaging a ratio that's already computed per row (instead of summing numerator and denominator separately and dividing at the end) gives a mathematically incorrect result at any grain other than the row's exact grain — DAX solves this natively by respecting the filter context.

---

## Dimensions

### `gold.dim_fecha` — no SCD, growing range
Self-extending calendar: fixed floor at `2022-01-01` (`bronze.sap_bsad`'s real start date), ceiling at `today + 1 year` (a cushion for future due dates, e.g. NET-90 terms), automatically extended on every `gold.load_gold` run. **It used to be static** (2020-01-01 to 2035-12-31, populated once) — redesigned because the Year filter in Power BI offered a full 15 years even though the real data only started in 2022, poor UX. It doesn't need SCD because a date, by definition, never changes its derived attributes (day of week, quarter, etc.).

### `gold.dim_cliente` — SCD Type 1
Customer identity (RFC, name, address). Fully overwritten on every load, **with no version history**, because these attributes almost never change — there's no value in paying the cost of SCD2 (more rows, more temporal-join complexity) for data that is, in practice, static.

### `gold.dim_cliente_comercial` / `gold.dim_cliente_credito` — SCD Type 2, two separate tables (mini-dimensions)

**Why not a single `dim_cliente` with SCD2 for everything**: this is Kimball's **mini-dimension** pattern, applied deliberately. If channel/region/route and credit limit/block lived in the same SCD2 table as customer identity, every time the most volatile attribute changes (`bloqueo_credito`, which changes weekly according to this project's real data) a new row would be generated that also versions the name, RFC, and address — which didn't change. With thousands of customers and weekly changes, the table explodes with near-duplicate rows, and on top of that you can no longer cleanly ask "how did this customer's region change?" without the answer being contaminated by versions that only exist because credit changed.

The rule applied: **group attributes by how often they change together, not by which business entity they conceptually "belong" to**. `dim_cliente_comercial` (channel, region, route, salesperson) changes occasionally; `dim_cliente_credito` (limit, block, risk classification) changes often — each versions at its own pace. The real cost: an analyst needs more joins to put together a complete report — a conscious trade-off, not a free one.

**SCD2 mechanics** (the same in both tables): `id_surrogate` (IDENTITY, the technical key the facts use), business key (`cliente_id`), `hash_atributos` (`HASHBYTES('SHA2_256', ...)` over the tracked columns — supported on SQL Server 2012 SP1, confirmed), `fecha_inicio_vigencia`/`fecha_fin_vigencia`/`es_vigente`, plus a unique filtered index `WHERE es_vigente=1` that guarantees a single active version per customer. Implemented as explicit sequential steps in a temp table (stage → close changed version → insert new version), not a single `MERGE` — easier to debug on this server than compacting everything into one statement.

**`dim_cliente_comercial` keeps `organizacion_ventas`/`canal_distribucion`/`sector`** even though the primary key is just `cliente_id`, so `dim_cliente_credito` can reuse "which channel was already chosen as the customer's representative" when looking up the credit analyst/collector — a single source of truth for that decision, not re-resolved in the second table.

**Facts relate to these two by surrogate key (`Cliente Comercial Sk`/`Cliente Credito Sk`), never directly by `cliente_id`** — the surrogate key is already resolved by date in the ETL to the correct version. A direct relationship by `cliente_id` would apply the customer's *current* attribute to their entire transaction history — the same mistake that led to retiring the `CLIENTE_LEGAL` classification (see below).

---

## Facts

### `gold.fact_saldo_cartera` — periodic snapshot, customer + date
**Why it's a table and not a view**: its source, `silver.sap_bsid`, is a **complete** daily mirror with no history retained (fully reloaded on every run). A view over `bsid` would only ever show "today" — never a trend. The table exists specifically to accumulate a new snapshot every day that the source doesn't retain on its own. **Real consequence of this**: it can't be backfilled historically — it only starts accumulating from the first day its load ran.

**Customer+date grain** (not invoice line): with ~91,593 line items / ~4,568 customers with a balance, line grain would have grown ~33M rows/year on a server with an already-known 2GB log ceiling; customer grain grows ~1.67M rows/year, manageable.

### `gold.fact_pagos_compensados` / `gold.fact_facturas_compensadas` — filtered mirror of `bsad`
**Names**: renamed from `fact_pagos`/`fact_facturas` (2026-08-21) — the original names over-promised scope. They only contain documents that are already **compensated** (settled), not every payment/invoice that exists — the name now says so explicitly.

**Why they're a table and not a view, applying criterion 3 (not 1 or 2)**: unlike `fact_saldo_cartera`, here no other table stores a surrogate key pointing to them (criterion 1 doesn't apply), and their source (`silver.sap_bsad`) **does** retain complete history since 2022 — it's never overwritten (criterion 2 doesn't apply either). The real reason for materializing them is **performance**: full `bsad` has ~11.9M rows across every document type; filtering live (`clase_documento='DZ' AND sgtxt='Asignación Aut. Deposito' AND debe_haber<>'S' AND monto>0` for payments, `clase_documento IN (F1-F6)` for invoices) on every dashboard query would be much slower than querying 611K/4.6M already-filtered rows with their own index (`IX_..._grupo` over `documento_compensacion`+`ejercicio_compensacion`, added after confirming that `vw_pago_factura_simple`'s join without it scanned the full table every time). It's a conscious performance decision, not a hard architectural requirement.

**Raw-payment filters, iterated with real evidence**: `debe_haber<>'S'` was added after finding that 4 of 5 sample "ambiguous" groups were actually a single real payment duplicated by its own mirror/offsetting line (same document, same amount, same text) — applying the filter reduced July's ambiguous residual from $1.52M to $249K. `monto_moneda_local>0` was added afterward after finding that 6 of the remaining 14 groups were the child's own "H" line with a $0.00 amount (a technical residual) inflating the candidate count.

**Backfill kept separate from the incremental load**: `backfill_fact_pagos_facturas_compensados.sql` (complete history since 2022, run once) vs. `gold.load_fact_pagos_compensados`/`load_fact_facturas_compensadas` (incremental, current + previous month) — the same pattern `silver.load_silver` uses for `bsad`, so as not to reprocess 11.9M rows on every daily refresh.

---

## Views

### `gold.vw_cliente_canal_estatus`
Classifies each customer+channel row from `silver.sap_knvv` as ACTIVO/LEGAL/INACTIVO/REVISAR/FUERA_DE_ALCANCE, ported from a Python script already in use (`ciosa.py`) and validated against real data. **A view, not a table**, because it's pure filter/CASE logic over a table that already exists — nothing is going to reference it by key, it doesn't accumulate anything the source doesn't have. `gold.dim_cliente_comercial` loads *on top of* this view, reducing it to 1 row per customer with the priority criterion ACTIVO > LEGAL > REVISAR > INACTIVO > FUERA_DE_ALCANCE.

### `gold.vw_pago_factura_simple` — the reporting view
Relates payment↔invoice only when the compensation group has **exactly 1 candidate payment** — if 2+ payments share the same group, there's no way to know for certain which one covered which invoice, so it's left out rather than forcing an arbitrary match (the same "don't guess" principle applied throughout the project).

**Single-RFC-per-group safeguard**: only includes payments whose entire compensation group (all lines, not just payment+invoice) belongs to a single real RFC — this allows legitimate `cliente_id` crossovers within the same RFC (the same person/company with several accounts), but excludes batches where genuinely different RFCs get mixed together (marketplace technical accounts, etc.). Measured: only 0.12% of GENERICO customers' amount falls into groups with 2+ distinct RFCs — the filter excludes exactly that, lets the remaining 99.88% through.

**`CLIENTE_LEGAL` was retired (2026-08-20)** from the classification for a historical-reliability reason, not a matter of preference: `dim_cliente_comercial` is SCD2, but each customer's initial version was artificially backdated to `2020-01-01` (just to allow the temporal join with historical facts) — it doesn't represent an actually observed real transition. A customer who became LEGAL a few months ago, with no other captured transition, would show up as LEGAL since 2020 in the temporal join — labeling 2022-2025 payments as `CLIENTE_LEGAL` when that customer was actually paying normally back then. **Lesson that applies to any future SCD2 attribute**: a classification that depends on projecting a *current* attribute backward in time is only as reliable as how far back real transitions have actually been observed.

**GENERICO is included** (reverting a one-day exclusion): the business process owner was shown the full list of generic customers (Mercado Libre, storefront, employees, tests) and confirmed they should be considered — "they're part of the flow."

---

## Retired objects (and why they're still documented here)

- **`gold.fact_aplicacion_pagos`** (removed 2026-08-19) — the 3-tier matching design (`REBZG`/unambiguous-group/no-match) had real over-attribution bugs: a $137 document could "explain" $2.5M in invoices within a massive compensation group, confirmed in several real cases. Replaced by the deliberately simpler design of `fact_pagos_compensados`/`fact_facturas_compensadas` + `vw_pago_factura_simple` — it only relates groups with exactly 1 candidate, with no match tiers or partial application. Less coverage, but without the risk of incorrect attribution.
- **`gold.fact_movimientos_compensados`** (removed 2026-08-13) — a complete line-level mirror of ALL of `bsad`. Explicit decision not to carry a whole silver table into gold undifferentiated — instead, build facts focused on specific business questions (the origin of `fact_aplicacion_pagos`, and later of `fact_pagos_compensados`/`fact_facturas_compensadas`).
- **`gold.vw_pago_virgen` / `gold.vw_factura` / `gold.vw_clasificacion_vencimiento_pago`** — prototypes from the design stage of `fact_aplicacion_pagos` and `clasificacion_cobranza`. The code already said "retired," but the actual `DROP` on the server was never run — found and cleaned up in the 2026-08-21 orphaned-object audit.
- **`gold.load_fact_pagos` / `gold.load_fact_facturas`** — procedures with the pre-rename name, internal body still pointing at tables that no longer exist. Orphaned for the same reason: the rename created the new objects but never `DROP`ped the old ones.

---

## Proposals in design — not yet implemented

Documented here because the full design was already discussed, but building them is still pending work:

- **`gold.vw_cartera_abierta`** — line-by-line detail of currently open invoices (`silver.sap_bsid`, same column/join pattern as `vw_pago_factura_simple`). Today only the per-customer aggregate exists in `fact_saldo_cartera`. Useful for: seeing exactly which invoices make up a customer's overdue balance, drill-down from Power BI, day-to-day collections queries.
- **`gold.dim_empleado`** — conforms `vendedor`/`gerente`/`analista_credito`/`cobrador` (today repeated plain text in `dim_cliente_comercial`/`dim_cliente_credito`) into a single shared role dimension, sourced from `bronze.sap_pa0001`. Doesn't replace the existing IDs, just adds the dimension for "by person" reporting.
- **Credit utilization** — **not as a SQL view, as a DAX measure** (`DIVIDE(SUM(saldo_total), SUM(limite_credito))`) directly in Power BI, since `fact_saldo_cartera` and `dim_cliente_credito` are already related in the model. A precomputed view or column would invite someone to average it incorrectly (averaging already-computed ratios is mathematically incorrect at any grain other than the row's exact grain).
- **Stage 2 of the collections report** ("expected budget" — overdue/upcoming balance at the start of the month) — `vw_cartera_abierta` only solves the *forward-looking* half (from today onward). Retroactively reconstructing past months requires combining `bsid` (what's still open today and was already open on that date) with `bsad` (what was open on that date but has since been settled) — a non-trivial design, still unresolved.
- **Collections management, write-offs/bad debt, credit-limit approval** — real business processes with no confirmed data source yet. Not designed until confirming with the team where that information lives (SAP, Excel, another system).
