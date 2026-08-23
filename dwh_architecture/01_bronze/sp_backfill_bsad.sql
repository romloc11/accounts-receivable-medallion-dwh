USE ANALISIS_DATOS;
GO

/*
========================================================================================
PROJECT: Data Centralization - Medallion Architecture (Bronze Layer)
OBJECT: bronze.backfill_bsad (Stored Procedure)
========================================================================================

PURPOSE:
One-time (or resumable) historical reload for bronze.sap_bsad, year by year, instead of
a single ~12.2M-row INSERT. Needed because bronze.sap_bsad was dropped and recreated by
re-running ddl_bronze.sql, which wiped the history that was already loaded - the daily
bronze.load_bronze procedure will NOT rebuild that history on its own, because its BSAD
step is an incremental MERGE that only looks at the current + previous month (see
sp_load_bronze.sql). Running it as-is against an empty table only restores ~2 months of
data, not the full history.

WHY YEAR BATCHES (same reasoning as the bkpf/vbrk/vbrp backfill that existed earlier in
this project and was later removed - see ddl_bronze.sql/sp_load_bronze.sql for that note):
  - One ~12.2M-row INSERT is a single giant transaction (transaction log growth) with no
    resume point if it fails partway.
  - Splitting by year (via AUGDT, the same field the daily incremental already uses for
    its lookback window) keeps each batch's transaction small and makes the whole backfill
    resumable: if it fails on a given year, just re-run and already-loaded years are
    skipped automatically.

WHY THE RESUME CHECK IS DIFFERENT FROM A HIGHWATER COMPARISON:
The daily incremental MERGE logs last_loaded_value = start-of-lookback-window (e.g. first
day of last month), NOT the actual max AUGDT present in the table - it's a filter marker,
not a completeness marker. Comparing years against that value would incorrectly skip
years that were never actually loaded. So this procedure checks the TARGET TABLE directly
(does data already exist for this year?) instead of relying on control.sap_load_control.

USAGE:
  -- Full historical reload (adjust @start_year to match how far back your BSAD data goes;
  -- check with: SELECT MIN(AUGDT) FROM P01.p01.BSAD):
  EXEC bronze.backfill_bsad @start_year = 2015;

  -- Resume after a failure/interruption - years already present in bronze.sap_bsad are
  -- detected and skipped automatically, so it's safe to just re-run the same call:
  EXEC bronze.backfill_bsad @start_year = 2015;

PARAMETERS:
  @start_year   First calendar year to load (inclusive). Required.
  @end_year     Last calendar year to load (inclusive). Defaults to current year.

NOTE: Since bronze.sap_bsad is empty at the time this is meant to be run, each year does a
plain INSERT (no MERGE/upsert needed - nothing to reconcile against yet). The daily
bronze.load_bronze MERGE step remains unchanged and picks up the ongoing 2-month
reconciliation window once this backfill has finished.

NOTE ON PERFORMANCE: the existing daily MERGE step already filters P01.p01.BSAD by AUGDT
for its 2-month window and reportedly runs in ~30-60 seconds for that slice, which is a
good sign there is usable index support for AUGDT on the source side already - so this
should batch reasonably well without further tuning. If a given year still runs slow,
apply the same checks used for bkpf/vbrk earlier in this project (verify AUGDT is a
leading index column on P01.p01.BSAD).
========================================================================================
*/

IF OBJECT_ID('bronze.backfill_bsad', 'P') IS NOT NULL
    DROP PROCEDURE bronze.backfill_bsad;
GO

CREATE PROCEDURE bronze.backfill_bsad
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
    SET @current_table = 'bronze.sap_bsad';

    BEGIN TRY

        SET @batch_start_time = SYSDATETIME();

        PRINT '==================================================';
        PRINT '        BSAD historical backfill by year           ';
        PRINT '   Years: ' + CAST(@start_year AS NVARCHAR) + ' to ' + CAST(@end_year AS NVARCHAR);
        PRINT '==================================================';

        WHILE @yr <= @end_year
        BEGIN
            SET @range_start = CAST(@yr AS NVARCHAR(4)) + '0101';
            SET @range_end   = CAST(@yr AS NVARCHAR(4)) + '1231';

            SET @already_loaded = CASE WHEN EXISTS (
                SELECT TOP 1 1 FROM bronze.sap_bsad WHERE AUGDT BETWEEN @range_start AND @range_end
            ) THEN 1 ELSE 0 END;

            IF @already_loaded = 1
            BEGIN
                PRINT '>> [' + CAST(@yr AS NVARCHAR) + '] bronze.sap_bsad already has data for that year - skipping.';
            END
            ELSE
            BEGIN
                SET @start_time = SYSDATETIME();
                PRINT '>> [' + CAST(@yr AS NVARCHAR) + '] Loading bronze.sap_bsad (AUGDT ' + @range_start + ' to ' + @range_end + ')...';

                -- Positional SELECT * (no explicit column list): bronze.sap_bsad and
                -- P01.p01.BSAD have the same verified column order, and the explicit list
                -- of 179 columns repeated twice (INSERT + SELECT) caused a syntax error on
                -- SQL Server 2012 that couldn't be isolated beyond "it's the full list
                -- inside an INSERT...SELECT" - a plain SELECT with the same 179 columns
                -- works fine, so the problem is specific to that combination. Avoiding it
                -- entirely is simpler than continuing to debug it.
                INSERT INTO bronze.sap_bsad
                SELECT *
                FROM P01.p01.BSAD WITH (NOLOCK)
                WHERE AUGDT BETWEEN @range_start AND @range_end;
                SET @rows_count = @@ROWCOUNT;

                SET @end_time = SYSDATETIME();
                PRINT '   -> ' + CAST(@rows_count AS NVARCHAR) + ' rows in ' + CAST(DATEDIFF(second,@start_time,@end_time) AS NVARCHAR) + ' sec.';

                EXEC control.sp_log_load @table_name = @current_table, @load_type = 'BACKFILL', @load_status = 'SUCCESS',
                     @rows_processed = @rows_count, @start_time = @start_time, @end_time = @end_time,
                     @last_loaded_value = @range_end;
            END

            SET @yr = @yr + 1;
        END

        SET @batch_end_time = SYSDATETIME();
        PRINT '==================================================';
        PRINT 'BSAD backfill complete. Total duration: ' + CAST(DATEDIFF(minute,@batch_start_time,@batch_end_time) AS NVARCHAR) + ' minutes';
        PRINT '==================================================';

    END TRY
    BEGIN CATCH

        PRINT '==================================================';
        PRINT 'ERROR IN BSAD BACKFILL';
        PRINT 'Current year: ' + CAST(@yr AS NVARCHAR);
        PRINT 'Message: ' + ERROR_MESSAGE();
        PRINT 'Line: '    + CAST(ERROR_LINE() AS VARCHAR(10));
        PRINT '==================================================';

        EXEC control.sp_log_load @table_name = @current_table, @load_type = 'BACKFILL', @load_status = 'FAILED',
             @rows_processed = NULL, @start_time = @start_time, @end_time = SYSDATETIME(),
             @error_message = ERROR_MESSAGE();

        PRINT 'To resume after fixing the issue, run again:';
        PRINT '  EXEC bronze.backfill_bsad @start_year = ' + CAST(@start_year AS NVARCHAR) + ', @end_year = ' + CAST(@end_year AS NVARCHAR) + ';';
        PRINT '(years already present in the table are detected and skipped automatically)';

        THROW;

    END CATCH
END;
GO

PRINT 'Procedure bronze.backfill_bsad created successfully.';
GO
