USE ANALISIS_DATOS;
GO

/*
========================================================================================
ONE-TIME SCHEMA CHANGE + BACKFILL: posting key and application fields in silver
========================================================================================
PURPOSE (2026-09-03, prerequisite of the fact_aplicacion v2 design - see DESIGN.md,
"Proposals in design" -> "gold.fact_aplicacion"):

  1. silver.sap_bsad  +  clave_contabilizacion (BSCHL)
  2. silver.sap_bsid  +  clave_contabilizacion (BSCHL), sgtxt (SGTXT),
                         factura_referencia_documento/ejercicio/posicion (REBZG/REBZJ/REBZZ)

BSCHL turned out to be the single most informative field for the application logic
(verified against SAP GUI): it separates the DZ virgin deposit (11) from a referenced
payment (15) and from the child mirror (08), decides the role of every AB line, and is
the only signal of an FB08 reversal (paired keys 11<->02, 15<->05, 01<->12) - XSTOV is
blank on all 12.45M bsad rows.

WHY THIS FILE AND NOT ddl_silver.sql:
ddl_silver.sql DROPs and recreates every silver table. Running it would empty
silver.sap_bsad, whose full 2022+ history took a year-chunked backfill to load. This
script ALTERs in place and backfills only the new column. ddl_silver.sql was updated too,
so a fresh environment gets the columns from the CREATE TABLE directly.

ORDER OF EXECUTION (one block at a time, check the output before the next):

  Step 1  - ALTER TABLE (both tables). Instant, no data touched.
  Step 2  - run 02_silver/sp_load_silver.sql in full (recreates silver.load_silver with
            the new columns; safe, a procedure holds no data).
  Step 3  - EXEC silver.load_silver;  -> silver.sap_bsid gets all 5 columns at once
            (truncate + reload), silver.sap_bsad gets clave_contabilizacion populated for
            the current + previous month window through the MERGE's UPDATE branch.
  Step 4  - backfill blocks below, one per fiscal year of fecha_compensacion, oldest first.
            Each is an UPDATE ... FROM joined to bronze on the line-item key. Idempotent:
            re-running a chunk just rewrites the same values.
  Step 5  - final check: silver.sap_bsad rows with clave_contabilizacion IS NULL must be 0.

LOG CEILING:
Each yearly chunk updates ~2.2-2.9M rows with one 2-character column. If a chunk fails
with "Msg 9002: The transaction log for database 'ANALISIS_DATOS' is full", split THAT
year in two halves (fecha_compensacion >= 'YYYY0101' AND < 'YYYY0701', then >= 'YYYY0701'
AND < 'YYYY+1 0101') and run each half separately - same pattern as
backfill_bsad_historico.sql. Don't run two chunks at once in different SSMS tabs.

JOIN KEY:
bronze.sap_bsad's PK is (MANDT, BUKRS, KUNNR, GJAHR, BELNR, BUZEI). silver stores
cliente_id without leading zeros, ejercicio as INT and posicion as INT, so the join
rebuilds bronze's raw formats on the silver side (RIGHT('000...') padding) - that keeps
the bronze side sargable and lets the PK seek work.
========================================================================================
*/

-- ========================================================================================
-- Step 1: ALTER TABLE (both tables)
-- ========================================================================================
IF COL_LENGTH('silver.sap_bsad', 'clave_contabilizacion') IS NULL
    ALTER TABLE silver.sap_bsad ADD clave_contabilizacion VARCHAR(2) NULL;
GO

IF COL_LENGTH('silver.sap_bsid', 'clave_contabilizacion') IS NULL
    ALTER TABLE silver.sap_bsid ADD
        clave_contabilizacion        VARCHAR(2)  NULL,
        sgtxt                        VARCHAR(50) NULL,
        factura_referencia_documento VARCHAR(10) NULL,
        factura_referencia_ejercicio INT         NULL,
        factura_referencia_posicion  INT         NULL;
GO

SELECT
    COL_LENGTH('silver.sap_bsad', 'clave_contabilizacion')        AS bsad_clave_contabilizacion,
    COL_LENGTH('silver.sap_bsid', 'clave_contabilizacion')        AS bsid_clave_contabilizacion,
    COL_LENGTH('silver.sap_bsid', 'sgtxt')                        AS bsid_sgtxt,
    COL_LENGTH('silver.sap_bsid', 'factura_referencia_documento') AS bsid_factura_referencia_documento;
-- all four must be non-NULL before continuing
GO

-- ========================================================================================
-- Steps 2 and 3 are NOT in this file:
--   run 02_silver/sp_load_silver.sql in full, then:  EXEC silver.load_silver;
-- Confirm afterwards:
--   SELECT COUNT(*) FROM silver.sap_bsid WHERE clave_contabilizacion IS NULL;  -- expected 0
-- ========================================================================================

-- ========================================================================================
-- Step 4: backfill clave_contabilizacion in silver.sap_bsad, one fiscal year at a time
-- ========================================================================================

-- 2022
UPDATE s
SET s.clave_contabilizacion = NULLIF(LTRIM(RTRIM(b.BSCHL)), '')
FROM silver.sap_bsad s
JOIN bronze.sap_bsad b WITH (NOLOCK)
  ON  b.MANDT = s.mandante
  AND b.BUKRS = s.sociedad
  AND b.KUNNR = RIGHT('0000000000' + s.cliente_id, 10)
  AND b.GJAHR = CAST(s.ejercicio AS NVARCHAR(4))
  AND b.BELNR = s.documento_id
  AND b.BUZEI = RIGHT('000' + CAST(s.posicion AS VARCHAR(3)), 3)
WHERE s.mandante = '400'
  AND s.fecha_compensacion >= '20220101' AND s.fecha_compensacion < '20230101'
  AND s.clave_contabilizacion IS NULL;
PRINT 'Rows updated 2022: ' + CAST(@@ROWCOUNT AS VARCHAR);
GO

-- 2023
UPDATE s
SET s.clave_contabilizacion = NULLIF(LTRIM(RTRIM(b.BSCHL)), '')
FROM silver.sap_bsad s
JOIN bronze.sap_bsad b WITH (NOLOCK)
  ON  b.MANDT = s.mandante
  AND b.BUKRS = s.sociedad
  AND b.KUNNR = RIGHT('0000000000' + s.cliente_id, 10)
  AND b.GJAHR = CAST(s.ejercicio AS NVARCHAR(4))
  AND b.BELNR = s.documento_id
  AND b.BUZEI = RIGHT('000' + CAST(s.posicion AS VARCHAR(3)), 3)
WHERE s.mandante = '400'
  AND s.fecha_compensacion >= '20230101' AND s.fecha_compensacion < '20240101'
  AND s.clave_contabilizacion IS NULL;
PRINT 'Rows updated 2023: ' + CAST(@@ROWCOUNT AS VARCHAR);
GO

-- 2024
UPDATE s
SET s.clave_contabilizacion = NULLIF(LTRIM(RTRIM(b.BSCHL)), '')
FROM silver.sap_bsad s
JOIN bronze.sap_bsad b WITH (NOLOCK)
  ON  b.MANDT = s.mandante
  AND b.BUKRS = s.sociedad
  AND b.KUNNR = RIGHT('0000000000' + s.cliente_id, 10)
  AND b.GJAHR = CAST(s.ejercicio AS NVARCHAR(4))
  AND b.BELNR = s.documento_id
  AND b.BUZEI = RIGHT('000' + CAST(s.posicion AS VARCHAR(3)), 3)
WHERE s.mandante = '400'
  AND s.fecha_compensacion >= '20240101' AND s.fecha_compensacion < '20250101'
  AND s.clave_contabilizacion IS NULL;
PRINT 'Rows updated 2024: ' + CAST(@@ROWCOUNT AS VARCHAR);
GO

-- 2025 - split in two halves. The full year (2,817,952 rows) hit Msg 9002 on the real
-- run of 2026-09-03 while 2024 (2,869,838 rows) went through: the ceiling is about the
-- log's headroom at that moment, not a fixed row count. Halves of ~1.4M are well inside it.
UPDATE s
SET s.clave_contabilizacion = NULLIF(LTRIM(RTRIM(b.BSCHL)), '')
FROM silver.sap_bsad s
JOIN bronze.sap_bsad b WITH (NOLOCK)
  ON  b.MANDT = s.mandante
  AND b.BUKRS = s.sociedad
  AND b.KUNNR = RIGHT('0000000000' + s.cliente_id, 10)
  AND b.GJAHR = CAST(s.ejercicio AS NVARCHAR(4))
  AND b.BELNR = s.documento_id
  AND b.BUZEI = RIGHT('000' + CAST(s.posicion AS VARCHAR(3)), 3)
WHERE s.mandante = '400'
  AND s.fecha_compensacion >= '20250101' AND s.fecha_compensacion < '20250701'
  AND s.clave_contabilizacion IS NULL;
PRINT 'Rows updated 2025 H1: ' + CAST(@@ROWCOUNT AS VARCHAR);
GO

UPDATE s
SET s.clave_contabilizacion = NULLIF(LTRIM(RTRIM(b.BSCHL)), '')
FROM silver.sap_bsad s
JOIN bronze.sap_bsad b WITH (NOLOCK)
  ON  b.MANDT = s.mandante
  AND b.BUKRS = s.sociedad
  AND b.KUNNR = RIGHT('0000000000' + s.cliente_id, 10)
  AND b.GJAHR = CAST(s.ejercicio AS NVARCHAR(4))
  AND b.BELNR = s.documento_id
  AND b.BUZEI = RIGHT('000' + CAST(s.posicion AS VARCHAR(3)), 3)
WHERE s.mandante = '400'
  AND s.fecha_compensacion >= '20250701' AND s.fecha_compensacion < '20260101'
  AND s.clave_contabilizacion IS NULL;
PRINT 'Rows updated 2025 H2: ' + CAST(@@ROWCOUNT AS VARCHAR);
GO

-- 2026 (whole year; whatever the MERGE already populated in step 3 is skipped by the IS NULL filter)
UPDATE s
SET s.clave_contabilizacion = NULLIF(LTRIM(RTRIM(b.BSCHL)), '')
FROM silver.sap_bsad s
JOIN bronze.sap_bsad b WITH (NOLOCK)
  ON  b.MANDT = s.mandante
  AND b.BUKRS = s.sociedad
  AND b.KUNNR = RIGHT('0000000000' + s.cliente_id, 10)
  AND b.GJAHR = CAST(s.ejercicio AS NVARCHAR(4))
  AND b.BELNR = s.documento_id
  AND b.BUZEI = RIGHT('000' + CAST(s.posicion AS VARCHAR(3)), 3)
WHERE s.mandante = '400'
  AND s.fecha_compensacion >= '20260101' AND s.fecha_compensacion < '20270101'
  AND s.clave_contabilizacion IS NULL;
PRINT 'Rows updated 2026: ' + CAST(@@ROWCOUNT AS VARCHAR);
GO

-- ========================================================================================
-- Step 5: final checks
-- ========================================================================================
DECLARE @nulos INT, @total INT;
SELECT @nulos = COUNT(*) FROM silver.sap_bsad WHERE clave_contabilizacion IS NULL;
SELECT @total = COUNT(*) FROM silver.sap_bsad;
PRINT 'silver.sap_bsad rows: ' + CAST(@total AS VARCHAR) + ' | clave_contabilizacion IS NULL: ' + CAST(@nulos AS VARCHAR) + ' (expected 0)';

-- Distribution sanity check against what the investigation measured in bronze on 2026-09-03
-- (DZ side H: 15 ~606K, 11 ~567K; AB: 07/17 in $0.00 ~304K lines; ZZ: 05 ~97K, 18 ~96K)
SELECT clase_documento, clave_contabilizacion, debe_haber, COUNT(*) AS filas
FROM silver.sap_bsad
WHERE clase_documento IN ('DZ', 'AB', 'ZZ', 'CP')
GROUP BY clase_documento, clave_contabilizacion, debe_haber
ORDER BY clase_documento, filas DESC;
GO
