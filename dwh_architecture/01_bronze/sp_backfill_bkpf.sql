USE ANALISIS_DATOS;
GO

/*
========================================================================================
PROJECT: Data Centralization - Medallion Architecture (Bronze Layer)
OBJECT: bronze.backfill_bkpf (Stored Procedure)
========================================================================================

PURPOSE:
One-time (or resumable) historical load for bronze.sap_bkpf, year by year, for the same
reasons as bronze.backfill_bsad: the daily bronze.load_bronze only merges the current +
previous month, so running it against an empty table restores ~2 months, not history.

WHY THIS TABLE EXISTS AT ALL:
BSAD/BSID hold the payment LINES but not the document header, so there was no way to
know which document reverses which. Reversals had to be matched by guessing on
customer + amount + assignment: 73 of 188 clave-05 reversals came out ambiguous and 46
had no match at all, which left one month $4.16M off depending on the method chosen.
BKPF closes that with STBLG/STJAH (the reversal link) and STGRD (the reason), and adds
TCODE/USNAM - which is what turned "we think key 11 is the automatic deposit" into a
measured fact: in August 2026 all 10,553 key-11 lines came from OS_APPLICATION.

SCOPE - ONLY BLART = 'DZ':
Full BKPF is the accounting journal for the WHOLE company: 35.6M rows x 111 columns,
against ~1.25M rows for DZ alone. Copying all of it to answer a payments question would
be expensive on an instance that already has transaction-log limits, and this table was
dropped from the project once before precisely because nothing consumed it. Widening the
scope is a one-line change in the WHERE below (and the matching one in
bronze.load_bronze) - do it when something concrete needs it, not before.

WHY YEAR BATCHES:
Same reasoning as backfill_bsad - one giant INSERT is a single transaction with no resume
point, and the log grows unbounded. Splitting by BUDAT year keeps each batch small and
makes the whole thing resumable: a year already present in the target is skipped.

WHY THE RESUME CHECK LOOKS AT THE TARGET TABLE:
control.sap_load_control logs the incremental's filter marker, not a completeness marker,
so comparing years against it would skip years that were never actually loaded. This
checks bronze.sap_bkpf directly instead.

USAGE:
  -- DZ documents exist in BSAD/BSID from 2019, with real volume from 2022:
  EXEC bronze.backfill_bkpf @start_year = 2022;

  -- Safe to re-run after a failure: loaded years are detected and skipped.
  EXEC bronze.backfill_bkpf @start_year = 2022;

PARAMETERS:
  @start_year   First calendar year to load (inclusive). Required.
  @end_year     Last calendar year to load (inclusive). Defaults to current year.

NOTE: positional INSERT ... SELECT * with no column list, exactly as in backfill_bsad.
bronze.sap_bkpf was generated from P01.p01.BKPF's own column order for this reason, so
the two line up 1:1. Re-generate the DDL if SAP ever adds a column, or this breaks.

NOTE ON THE MISSING AUDIT LOG - VERIFIED 2026-09-11:
This procedure does NOT call control.sp_log_load, for the same reason bronze.load_bronze
doesn't (see the header of sp_load_bronze.sql): calling it from inside another procedure
breaks compilation on this SQL Server 2012 instance with a misleading "Incorrect syntax
near ')'". Confirmed here by bisection - the identical procedure compiles once the two
EXEC calls are removed and fails with them in.

That same defect is why sp_backfill_bsad.sql has never existed as an object on the
server: sys.objects has no bronze.backfill_bsad, so that file cannot have been deployed
as written. Whoever loads BSAD history again will hit this first. Either strip the two
EXEC calls there as well, or run the INSERT by hand year by year.

There is therefore no persisted audit trail of backfill runs - only the PRINT output
visible while it runs. The resume check does not depend on it: it looks at the target
table directly (see below).

========================================================================================
*/

IF OBJECT_ID('bronze.backfill_bkpf', 'P') IS NOT NULL
    DROP PROCEDURE bronze.backfill_bkpf;
GO

CREATE PROCEDURE bronze.backfill_bkpf
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
            @current_table    NVARCHAR(128),
            @rows_count       INT,
            @already_loaded   BIT;

    SET @yr = @start_year;
    SET @end_year = ISNULL(@end_year, YEAR(GETDATE()));
    SET @current_table = 'bronze.sap_bkpf';

    BEGIN TRY

        SET @batch_start_time = SYSDATETIME();

        PRINT '==================================================';
        PRINT '        BKPF historical backfill by year           ';
        PRINT '        (BLART = DZ only - see header note)        ';
        PRINT '   Years: ' + CAST(@start_year AS NVARCHAR) + ' to ' + CAST(@end_year AS NVARCHAR);
        PRINT '==================================================';

        WHILE @yr <= @end_year
        BEGIN
            SET @range_start = CAST(@yr AS NVARCHAR(4)) + '0101';
            SET @range_end   = CAST(@yr AS NVARCHAR(4)) + '1231';

            SET @already_loaded = CASE WHEN EXISTS (
                SELECT TOP 1 1 FROM bronze.sap_bkpf WHERE BUDAT BETWEEN @range_start AND @range_end
            ) THEN 1 ELSE 0 END;

            IF @already_loaded = 1
            BEGIN
                PRINT '>> [' + CAST(@yr AS NVARCHAR) + '] bronze.sap_bkpf already has data for that year - skipping.';
            END
            ELSE
            BEGIN
                SET @start_time = SYSDATETIME();
                PRINT '>> [' + CAST(@yr AS NVARCHAR) + '] Loading bronze.sap_bkpf (BUDAT ' + @range_start + ' to ' + @range_end + ')...';

                -- Positional SELECT * (no explicit column list), same as backfill_bsad:
                -- the explicit list inside an INSERT...SELECT is what broke compilation on
                -- this SQL Server 2012 instance. The column order of bronze.sap_bkpf comes
                -- straight from P01.p01.BKPF, so positional is safe here.
                INSERT INTO bronze.sap_bkpf
                SELECT *
                FROM P01.p01.BKPF WITH (NOLOCK)
                WHERE BLART = 'DZ'
                  AND BUDAT BETWEEN @range_start AND @range_end;
                SET @rows_count = @@ROWCOUNT;

                SET @end_time = SYSDATETIME();
                PRINT '   -> ' + CAST(@rows_count AS NVARCHAR) + ' rows in ' + CAST(DATEDIFF(second,@start_time,@end_time) AS NVARCHAR) + ' sec.';

            END

            SET @yr = @yr + 1;
        END

        SET @batch_end_time = SYSDATETIME();
        PRINT '==================================================';
        PRINT 'BKPF backfill complete. Total duration: ' + CAST(DATEDIFF(minute,@batch_start_time,@batch_end_time) AS NVARCHAR) + ' minutes';
        PRINT '==================================================';

    END TRY
    BEGIN CATCH

        PRINT '==================================================';
        PRINT 'ERROR IN BKPF BACKFILL';
        PRINT 'Current year: ' + CAST(@yr AS NVARCHAR);
        PRINT 'Message: ' + ERROR_MESSAGE();
        PRINT 'Line: '    + CAST(ERROR_LINE() AS VARCHAR(10));
        PRINT '==================================================';

        PRINT 'To resume after fixing the issue, run again:';
        PRINT '  EXEC bronze.backfill_bkpf @start_year = ' + CAST(@start_year AS NVARCHAR) + ', @end_year = ' + CAST(@end_year AS NVARCHAR) + ';';
        PRINT '(years already present in the table are detected and skipped automatically)';

        THROW;

    END CATCH
END;
GO

PRINT 'Procedure bronze.backfill_bkpf created successfully.';
GO
