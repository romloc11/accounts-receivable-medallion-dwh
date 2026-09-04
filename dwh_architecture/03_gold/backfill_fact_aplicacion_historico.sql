USE ANALISIS_DATOS;
GO

/*
========================================================================================
HISTORICAL BACKFILL: gold.fact_facturas / fact_notas / fact_pagos / fact_aplicacion
========================================================================================
PURPOSE:
The four v2 facts currently hold only the prototype window the daily load maintains
(fecha_compensacion / fecha_aplica >= 2026-07-01). silver.sap_bsad has the complete
history since 2022-01-01. This script loads everything BEFORE that window, so it never
steps on the daily load's work.

WHY THIS IS NOT OPTIONAL: until it runs, every invoice-side metric reads low. In July
2026, 12,658 cleared invoices ($20.57M) have no application row for one reason only -
the document that paid them was posted before the window and is not loaded.

--------------------------------------------------------------------------------------
TWO PHASES, IN THIS ORDER. DO NOT INTERLEAVE THEM.
--------------------------------------------------------------------------------------
The document facts are chunked by fecha_compensacion; fact_aplicacion is chunked by
fecha_aplica (its VEHICLE's posting date). Those are different axes: an application whose
vehicle posted in 2023-12 but cleared in 2024-01 belongs to Phase B chunk 2023H2 while
its payment row belongs to Phase A chunk 2024H1. So:

  PHASE A - fact_facturas, fact_notas, fact_pagos, ALL 5 chunks, 2022 -> 2026H1.
  PHASE B - fact_aplicacion, all 5 chunks, ONLY after Phase A is completely finished.

fact_aplicacion reads all three document facts; the three document facts do not read each
other, so their order inside a chunk is free.

--------------------------------------------------------------------------------------
RULES
--------------------------------------------------------------------------------------
1. OLDEST FIRST, always, and one chunk at a time. Never two SSMS tabs at once. In Phase B
   the cumulative caps (per receiving document, per vehicle, per origin) let the earliest
   applications consume an invoice first - that is the correct accounting order, and it is
   only correct if the chunks run oldest to newest.
2. Read the PRINT output of a chunk before starting the next one. In Phase B the three
   invariants must all be 0. If any is not, STOP and investigate - do not keep loading.
3. Every chunk is idempotent. fact_aplicacion deletes its window and rebuilds it; the
   document facts UPDATE by PK and INSERT what is new. Re-running a chunk that failed
   halfway (or where the VPN dropped) is safe.
4. CHUNK SIZE IS ONE YEAR. Msg 9002 (transaction log full, 2 GB fixed): split THAT year into
   two halves ('2023-01-01','2023-07-01' then '2023-07-01','2024-01-01'), and if a half still
   breaks, into quarters. Re-run each
   separately with the same EXEC and a narrower range. Same discipline as the
   silver.sap_bsad backfill. Recovery model is SIMPLE and the procedures use no explicit
   transactions, so the log truncates between statements.
5. BOUNDED MODE IS DIFFERENT FROM DAILY MODE, BY DESIGN. Passing a non-NULL @fecha_hasta
   makes the loaders skip silver.sap_bsid (open items are a picture of today, they belong
   to no historical window) and skip the REVERTIDO step (a bounded window cannot judge
   whether a document vanished from both sources). Both are correct for a backfill.

--------------------------------------------------------------------------------------
EXPECTED, NOT A BUG
--------------------------------------------------------------------------------------
- The 2022 chunks will show an unusually high unidentified rate. silver.sap_bsad starts at
  2022-01-01, so a 2022 payment that settled a 2021 invoice has no receiving document to
  point at and lands in SIN_DOCUMENTO_EN_GRUPO. The source does not have that invoice; no
  rule can fix it. Expect the rate to normalize from 2023 on.
- Each Phase B chunk is slower than the last. R6 and the cumulative caps read the whole
  fact (a clearing group can span windows - that is deliberate), so the scans grow with
  the table.
- CORRECTION 2026-09-04: an earlier version of this header claimed the caps already read the
  whole fact. They did not - all three were filtered to the load window, so an invoice paid
  across two chunks was capped twice against an empty slate. The first backfill attempt ended
  with 605 over-applied invoices ($1.10M) and 22 over-applied origins, growing with every
  chunk. Fixed in sp_load_fact_aplicacion.sql: the three caps are now global, and the
  per-receiving and per-origin caps order chronologically FIRST so the earliest application
  consumes the document and a later window can never trim a row an earlier one wrote. This
  was a latent bug in daily mode too, not only in the backfill.
- 6.6% of clearing groups (181,128 of 2,760,534) have documents posted in two different
  half-years. That is normal SAP behaviour and the Phase A / Phase B separation handles it.
  The one residual effect: for an early chunk, R6's "what the group has left" cannot see
  applications that later chunks will add, so early chunks may mark slightly more
  IDENTIFICADA_LOTE than a single full-history pass would. Validation query 4 measures it;
  if it looks material, re-run Phase B a second time in the same order.
- AFTER Phase B, re-run the daily window so it is rebuilt under the same global caps:
      EXEC gold.load_fact_aplicacion '2026-07-01';
  Its rows are chronologically last, so they are the ones that must yield to history.

--------------------------------------------------------------------------------------
SIZING (measured 2026-09-04)
--------------------------------------------------------------------------------------
silver.sap_bsad lines per year: 2022 2.20M | 2023 2.62M | 2024 2.87M | 2025 2.82M |
2026 1.95M. Expect roughly 1.1M invoice rows, 0.12M note rows and 0.7M payment rows per
full year, and ~1M application rows per year. The four facts should end near 5-6 GB in
total; the data file has 200 GB with 31 GB used, so space is not the constraint - the
2 GB log is.
========================================================================================
*/

-- Where things stand before starting (informational)
SELECT 'fact_facturas' AS tabla, MIN(fecha_compensacion) AS min_comp, MAX(fecha_compensacion) AS max_comp, COUNT(*) AS filas FROM gold.fact_facturas
UNION ALL SELECT 'fact_notas',      MIN(fecha_compensacion), MAX(fecha_compensacion), COUNT(*) FROM gold.fact_notas
UNION ALL SELECT 'fact_pagos',      MIN(fecha_compensacion), MAX(fecha_compensacion), COUNT(*) FROM gold.fact_pagos
UNION ALL SELECT 'fact_aplicacion', MIN(fecha_aplica),       MAX(fecha_aplica),       COUNT(*) FROM gold.fact_aplicacion;
GO


-- ########################################################################################
-- PHASE A - document facts. All 5 chunks before touching Phase B.
-- ########################################################################################

-- ---------------------------------------------------------------- 2022
EXEC gold.load_fact_facturas '2022-01-01', '2023-01-01';
GO
EXEC gold.load_fact_notas    '2022-01-01', '2023-01-01';
GO
EXEC gold.load_fact_pagos    '2022-01-01', '2023-01-01';
GO

-- ---------------------------------------------------------------- 2023
EXEC gold.load_fact_facturas '2023-01-01', '2024-01-01';
GO
EXEC gold.load_fact_notas    '2023-01-01', '2024-01-01';
GO
EXEC gold.load_fact_pagos    '2023-01-01', '2024-01-01';
GO

-- ---------------------------------------------------------------- 2024
EXEC gold.load_fact_facturas '2024-01-01', '2025-01-01';
GO
EXEC gold.load_fact_notas    '2024-01-01', '2025-01-01';
GO
EXEC gold.load_fact_pagos    '2024-01-01', '2025-01-01';
GO

-- ---------------------------------------------------------------- 2025
EXEC gold.load_fact_facturas '2025-01-01', '2026-01-01';
GO
EXEC gold.load_fact_notas    '2025-01-01', '2026-01-01';
GO
EXEC gold.load_fact_pagos    '2025-01-01', '2026-01-01';
GO

-- ---------------------------------------------------------------- 2026H1
EXEC gold.load_fact_facturas '2026-01-01', '2026-07-01';
GO
EXEC gold.load_fact_notas    '2026-01-01', '2026-07-01';
GO
EXEC gold.load_fact_pagos    '2026-01-01', '2026-07-01';
GO

-- Gate before Phase B: the three document facts must reach back to 2022-01
SELECT 'fact_facturas' AS tabla, MIN(fecha_compensacion) AS min_comp, COUNT(*) AS filas FROM gold.fact_facturas
UNION ALL SELECT 'fact_notas', MIN(fecha_compensacion), COUNT(*) FROM gold.fact_notas
UNION ALL SELECT 'fact_pagos', MIN(fecha_compensacion), COUNT(*) FROM gold.fact_pagos;
GO


-- ########################################################################################
-- PHASE B - fact_aplicacion. Only after EVERY Phase A chunk is done.
-- Check "invariants -> 0 | 0 | 0" after each chunk before running the next.
-- ########################################################################################

-- ---------------------------------------------------------------- 2022
EXEC gold.load_fact_aplicacion '2022-01-01', '2023-01-01';
GO

-- ---------------------------------------------------------------- 2023
EXEC gold.load_fact_aplicacion '2023-01-01', '2024-01-01';
GO

-- ---------------------------------------------------------------- 2024
EXEC gold.load_fact_aplicacion '2024-01-01', '2025-01-01';
GO

-- ---------------------------------------------------------------- 2025
EXEC gold.load_fact_aplicacion '2025-01-01', '2026-01-01';
GO

-- ---------------------------------------------------------------- 2026H1
EXEC gold.load_fact_aplicacion '2026-01-01', '2026-07-01';
GO


-- ########################################################################################
-- VALIDATION - run after Phase B is complete
-- ########################################################################################

-- 1. Continuity: no month between 2022-01 and today may be missing or suspiciously small
SELECT YEAR(fecha_aplica) AS anio, MONTH(fecha_aplica) AS mes, COUNT(*) AS filas,
       CAST(SUM(monto_aplicado) AS DECIMAL(18,2)) AS monto
FROM gold.fact_aplicacion
GROUP BY YEAR(fecha_aplica), MONTH(fecha_aplica)
ORDER BY 1, 2;
GO

-- 2. The invariants over the whole history. Both queries must return 0 rows.
SELECT TOP 20 documento_recibe, ejercicio_recibe, posicion_recibe,
       monto_documento_recibe, SUM(monto_aplicado) AS aplicado
FROM gold.fact_aplicacion WHERE documento_recibe IS NOT NULL
GROUP BY documento_recibe, ejercicio_recibe, posicion_recibe, monto_documento_recibe
HAVING SUM(monto_aplicado) > monto_documento_recibe + 1.00;

SELECT TOP 20 documento_aplica, ejercicio_aplica, posicion_aplica,
       documento_recibe, ejercicio_recibe, posicion_recibe, COUNT(*) AS veces
FROM gold.fact_aplicacion WHERE documento_recibe IS NOT NULL
GROUP BY documento_aplica, ejercicio_aplica, posicion_aplica,
         documento_recibe, ejercicio_recibe, posicion_recibe
HAVING COUNT(*) > 1;
GO

-- 3. Identification rate by year - 2022 is expected to be the worst (invoices predating bsad)
SELECT YEAR(fecha_aplica) AS anio, estatus_identificacion,
       COUNT(*) AS filas, CAST(SUM(monto_aplicado) AS DECIMAL(18,2)) AS monto
FROM gold.fact_aplicacion
GROUP BY YEAR(fecha_aplica), estatus_identificacion
ORDER BY 1, 2;
GO

-- 4. Chunk-boundary effect on R6 (see "EXPECTED, NOT A BUG"): lot rows whose clearing group
--    also has rows in another half-year. A large count argues for a second Phase B pass.
SELECT YEAR(a.fecha_aplica) AS anio, COUNT(*) AS filas_lote_en_grupo_partido
FROM gold.fact_aplicacion a
WHERE a.motivo_no_identificado = 'LOTE_EN_GRUPO'
  AND EXISTS (SELECT 1 FROM gold.fact_aplicacion b
              WHERE b.documento_compensacion = a.documento_compensacion
                AND b.ejercicio_compensacion = a.ejercicio_compensacion
                AND (YEAR(b.fecha_aplica) <> YEAR(a.fecha_aplica)
                     OR CASE WHEN MONTH(b.fecha_aplica) <= 6 THEN 1 ELSE 2 END
                        <> CASE WHEN MONTH(a.fecha_aplica) <= 6 THEN 1 ELSE 2 END))
GROUP BY YEAR(a.fecha_aplica) ORDER BY 1;
GO

-- 5. The invoice-side gap that motivated all this. Re-run the July check: the
--    "no application row" population should collapse from 17,520 invoices / $24.0M to
--    roughly the 4,862 / $3.46M that are real ambiguity.
SELECT COUNT(*) AS facturas_sin_aplicacion,
       CAST(SUM(ff.monto_moneda_local) AS DECIMAL(18,2)) AS monto
FROM gold.fact_facturas ff
WHERE ff.estado_sap = 'COMPENSADO' AND ff.anulada = 0
  AND ff.fecha_compensacion >= '2026-07-01' AND ff.fecha_compensacion < '2026-08-01'
  AND NOT EXISTS (SELECT 1 FROM gold.fact_aplicacion a
                  WHERE a.sociedad = ff.sociedad AND a.documento_recibe = ff.documento_id
                    AND a.ejercicio_recibe = ff.ejercicio AND a.posicion_recibe = ff.posicion);
GO
