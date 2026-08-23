USE ANALISIS_DATOS;
GO

-- ==========================================================
-- ONE-TIME MIGRATION: rename gold.fact_pagos -> gold.fact_pagos_compensados
-- and gold.fact_facturas -> gold.fact_facturas_compensadas ON THE REAL SERVER,
-- preserving the data already loaded (2022-2026 backfill).
--
-- DO NOT use ddl_gold.sql for this change: that version already has
-- DROP TABLE + CREATE TABLE for the new names, correct for a from-scratch
-- deployment, but destructive if run against these already-populated
-- tables. sp_rename doesn't touch the data, only the catalog.
--
-- Order: 1) tables, 2) PK (implemented as a constraint/index), 3) non-
-- clustered indexes. After running this, re-run sp_load_gold.sql (the
-- full CREATE PROCEDURE statements) and vw_pago_factura_simple.sql so the
-- procedures/view end up pointing at the new names -- both are DROP+CREATE
-- of objects with no data, no risk there.
-- ==========================================================

EXEC sp_rename 'gold.fact_pagos', 'fact_pagos_compensados';
EXEC sp_rename 'gold.PK_fact_pagos', 'PK_fact_pagos_compensados', 'OBJECT';
EXEC sp_rename 'gold.fact_pagos_compensados.IX_fact_pagos_grupo', 'IX_fact_pagos_compensados_grupo', 'INDEX';

EXEC sp_rename 'gold.fact_facturas', 'fact_facturas_compensadas';
EXEC sp_rename 'gold.PK_fact_facturas', 'PK_fact_facturas_compensadas', 'OBJECT';
EXEC sp_rename 'gold.fact_facturas_compensadas.IX_fact_facturas_grupo', 'IX_fact_facturas_compensadas_grupo', 'INDEX';

-- Quick check: the new names should appear, with the same row counts
-- they had before the rename.
SELECT 'gold.fact_pagos_compensados' AS tabla, COUNT(*) AS filas FROM gold.fact_pagos_compensados
UNION ALL
SELECT 'gold.fact_facturas_compensadas', COUNT(*) FROM gold.fact_facturas_compensadas;
GO
