USE ANALISIS_DATOS;
GO

/*
========================================================================================
PROJECT: Data Centralization - Medallion Architecture (Bronze Layer)
OBJECT: bronze.backfill_bsas (Stored Procedure)
========================================================================================

PURPOSE:
One-time (or resumable) historical load for bronze.sap_bsas, year by year, for the same
reason as bronze.backfill_bkpf: bronze.load_bronze only merges the current + previous
month, so running it against an empty table restores ~2 months, not history.

WHY THIS TABLE EXISTS:
The report the company uses to state monthly cash collections is built on BANK lines, not
on customer lines - reproduced exactly for July 2026 ($149,182,258.79, document by
document, two of four bank accounts matching to the cent). BSAD cannot answer this: its
HKONT is the customer reconciliation account (121001), never the bank. BSEG, where the
bank side would normally be read, is an SAP cluster table and does not exist in P01.
BSAS/BSIS are the secondary indexes that make G/L line items readable.

SCOPE - ONLY HKONT 111xxx AND 113xxx:
113xxx are the banks, 111xxx are cash on hand and the payment-gateway transit accounts.
Full BSAS is ~16M rows; this scope is 1,933,853 from 2022 on. The 111xxx half is what
explains the gap between fact_pagos and the report (94% of it is money parked in
Transitoria de Kushki / Conekta), so it is not optional - see the note in ddl_bronze.sql.

THERE IS NO EQUIVALENT FOR BSIS, ON PURPOSE:
bronze.sap_bsis is a full reload on every run of bronze.load_bronze (in year chunks, for
the log), because an open item DISAPPEARS from BSIS the day it is cleared and a merge
would keep it in bronze forever. A full reload needs no historical backfill - the first
normal run already brings all of it.

WHY YEAR BATCHES:
Same reasoning as backfill_bkpf - one giant INSERT is a single transaction with no resume
point and an unbounded log. Splitting by BUDAT year keeps each batch small and makes the
whole thing resumable: a year already present in the target is skipped.

WHY THE RESUME CHECK LOOKS AT THE TARGET TABLE:
control.sap_load_control logs the incremental's filter marker, not a completeness marker,
so comparing years against it would skip years that were never actually loaded. This
checks bronze.sap_bsas directly instead.

BEFORE THE FIRST RUN:
Verify the primary key on one month (the query is at the end of section 12 in
ddl_bronze.sql). The MERGE in bronze.load_bronze depends on
MANDT+BUKRS+HKONT+GJAHR+BELNR+BUZEI being unique, and a duplicate there surfaces as a PK
violation halfway through a year rather than as a clear error.

USAGE:
  EXEC bronze.backfill_bsas @start_year = 2022;

  -- Safe to re-run after a failure: loaded years are detected and skipped.
  EXEC bronze.backfill_bsas @start_year = 2022;

PARAMETERS:
  @start_year   First calendar year to load (inclusive). Required.
  @end_year     Last calendar year to load (inclusive). Defaults to current year.

NOTE ON THE POSITIONAL INSERT:
INSERT ... SELECT * with no column list, exactly as in backfill_bkpf and backfill_bsad.
bronze.sap_bsas was generated from P01.p01.BSAS's own column order for this reason, so the
two line up 1:1. Re-generate the DDL (01_bronze/generar_ddl_desde_p01.sql) if SAP ever
adds a column, or this silently writes each value into the wrong column.

NOTE ON THE MISSING AUDIT LOG:
This procedure does NOT call control.sp_log_load. Calling it from inside another procedure
breaks compilation on this SQL Server 2012 instance with a misleading "Incorrect syntax
near ')'" - verified by bisection on backfill_bkpf 2026-09-11, and the reason
bronze.backfill_bsad has never existed as an object on the server. There is therefore no
persisted audit trail of backfill runs, only the PRINT output visible while it runs. The
resume check does not depend on it.

NOTE ON LOAD AGAINST PRODUCTION:
Each year batch is a single scan of P01.p01.BSAS filtered by BUDAT. Run it outside peak
hours. If a year is too heavy, split it: the resume check is per-year, so narrowing
@start_year/@end_year to one year at a time is the supported way to pace it.

========================================================================================
*/

IF OBJECT_ID('bronze.backfill_bsas', 'P') IS NOT NULL
    DROP PROCEDURE bronze.backfill_bsas;
GO

CREATE PROCEDURE bronze.backfill_bsas
    @start_year INT,
    @end_year   INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @yr               INT,
            @range_start      NVARCHAR(8),
            @range_end        NVARCHAR(8),
            @start_time       DATETIME2,
            @end_time         DATETIME2,
            @batch_start_time DATETIME2,
            @batch_end_time   DATETIME2,
            @rows_count       INT,
            @already_loaded   BIT;

    SET @yr = @start_year;
    SET @end_year = ISNULL(@end_year, YEAR(GETDATE()));

    BEGIN TRY

        SET @batch_start_time = SYSDATETIME();

        PRINT '==================================================';
        PRINT '        BSAS historical backfill by year          ';
        PRINT '     (HKONT 111xxx + 113xxx - see header note)    ';
        PRINT '   Years: ' + CAST(@start_year AS NVARCHAR) + ' to ' + CAST(@end_year AS NVARCHAR);
        PRINT '==================================================';

        WHILE @yr <= @end_year
        BEGIN
            SET @range_start = CAST(@yr AS NVARCHAR(4)) + '0101';
            SET @range_end   = CAST(@yr AS NVARCHAR(4)) + '1231';

            SET @already_loaded = CASE WHEN EXISTS (
                SELECT TOP 1 1 FROM bronze.sap_bsas WHERE BUDAT BETWEEN @range_start AND @range_end
            ) THEN 1 ELSE 0 END;

            IF @already_loaded = 1
            BEGIN
                PRINT '>> [' + CAST(@yr AS NVARCHAR) + '] bronze.sap_bsas already has data for that year - skipping.';
            END
            ELSE
            BEGIN
                SET @start_time = SYSDATETIME();
                PRINT '>> [' + CAST(@yr AS NVARCHAR) + '] Loading bronze.sap_bsas (BUDAT ' + @range_start + ' to ' + @range_end + ')...';

                INSERT INTO bronze.sap_bsas
                SELECT *
                FROM P01.p01.BSAS WITH (NOLOCK)
                WHERE BUDAT BETWEEN @range_start AND @range_end
                  AND (HKONT LIKE '0000111%' OR HKONT LIKE '0000113%');
                SET @rows_count = @@ROWCOUNT;

                SET @end_time = SYSDATETIME();
                PRINT '   -> ' + CAST(@rows_count AS NVARCHAR) + ' rows in ' + CAST(DATEDIFF(second,@start_time,@end_time) AS NVARCHAR) + ' sec.';

            END

            SET @yr = @yr + 1;
        END

        SET @batch_end_time = SYSDATETIME();
        PRINT '==================================================';
        PRINT 'BSAS backfill complete. Total duration: ' + CAST(DATEDIFF(minute,@batch_start_time,@batch_end_time) AS NVARCHAR) + ' minutes';
        PRINT '==================================================';

    END TRY
    BEGIN CATCH

        PRINT '==================================================';
        PRINT 'ERROR IN BSAS BACKFILL';
        PRINT 'Current year: ' + CAST(@yr AS NVARCHAR);
        PRINT 'Message: ' + ERROR_MESSAGE();
        PRINT 'Line: '    + CAST(ERROR_LINE() AS VARCHAR(10));
        PRINT '==================================================';

        PRINT 'To resume after fixing the issue, run again:';
        PRINT '  EXEC bronze.backfill_bsas @start_year = ' + CAST(@start_year AS NVARCHAR) + ', @end_year = ' + CAST(@end_year AS NVARCHAR) + ';';
        PRINT '(years already present in the table are detected and skipped automatically)';

        THROW;

    END CATCH
END;
GO

PRINT 'Procedure bronze.backfill_bsas created successfully.';
GO
