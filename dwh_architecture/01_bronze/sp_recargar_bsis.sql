USE ANALISIS_DATOS;
GO

/*
========================================================================================
PROJECT: Data Centralization - Medallion Architecture (Bronze Layer)
OBJECT: bronze.recargar_bsis (Stored Procedure)
========================================================================================

PURPOSE:
Full reload of bronze.sap_bsis from P01, year by year. It is NOT part of the daily load.

bronze.load_bronze loads BSIS in two steps (see section 12 of sp_load_bronze.sql): the
accounts that never clear are merged on a BUDAT window, and only the clearing accounts are
reloaded whole. That cut the section from 134 s to a fraction, and it is exact for
everything except two cases that no window can see:

  - a line posted into a period older than the previous month (possible only while that
    period is still open in SAP);
  - a line archived out of SAP, which stays in bronze.

This procedure is the way back from either: it throws bronze.sap_bsis away and reads it
again from P01. Run it when a check shows drift, after a period is reopened for late
postings, or on an empty environment. Then run silver.load_silver - or, for history older
than silver's window, 02_silver/backfill_bsas_bsis_historico.sql.

COST:
~2.9M rows read from production (measured 2026-09-14: 134 s for the same loop inside
bronze.load_bronze). Run it outside business hours.

WHY YEAR BATCHES:
One INSERT of ~2.9M rows is a single transaction against a 2GB log ceiling this instance
has hit before. Year chunks keep each transaction bounded.

WHY TRUNCATE AND NOT DELETE:
Speed and log. The consequence is that the table is empty, then partial, until the loop
ends - do not run silver.load_silver while this is running.

SCOPE:
Same as the daily load: HKONT 111xxx/113xxx, BUDAT from @start_year on.

NOTE ON THE MISSING AUDIT LOG:
Does NOT call control.sp_log_load - calling it from inside another procedure breaks
compilation on this SQL Server 2012 instance (see sp_backfill_bkpf.sql).

USAGE:
  EXEC bronze.recargar_bsis;                      -- from 2022, the project's start
  EXEC bronze.recargar_bsis @start_year = 2024;   -- NOT a partial reload: it still
                                                  -- truncates first, so older years are lost
========================================================================================
*/

IF OBJECT_ID('bronze.recargar_bsis', 'P') IS NOT NULL
    DROP PROCEDURE bronze.recargar_bsis;
GO

CREATE PROCEDURE bronze.recargar_bsis
    @start_year INT = 2022
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @yr         INT,
            @start_time DATETIME2,
            @batch_time DATETIME2,
            @rows_count INT;

    BEGIN TRY

        SET @batch_time = SYSDATETIME();

        PRINT '==================================================';
        PRINT '       bronze.sap_bsis - FULL reload by year      ';
        PRINT '   Years: ' + CAST(@start_year AS NVARCHAR) + ' to ' + CAST(YEAR(GETDATE()) AS NVARCHAR);
        PRINT '==================================================';

        TRUNCATE TABLE bronze.sap_bsis;

        SET @yr = @start_year;

        WHILE @yr <= YEAR(GETDATE())
        BEGIN
            SET @start_time = SYSDATETIME();

            INSERT INTO bronze.sap_bsis
            SELECT *
            FROM P01.p01.BSIS WITH (NOLOCK)
            WHERE BUDAT BETWEEN CAST(@yr AS NVARCHAR(4)) + '0101'
                            AND CAST(@yr AS NVARCHAR(4)) + '1231'
              AND (HKONT LIKE '0000111%' OR HKONT LIKE '0000113%');
            SET @rows_count = @@ROWCOUNT;

            PRINT '>> [' + CAST(@yr AS NVARCHAR) + '] ' + CAST(@rows_count AS NVARCHAR) + ' rows in '
                + CAST(DATEDIFF(second, @start_time, SYSDATETIME()) AS NVARCHAR) + ' sec.';

            SET @yr = @yr + 1;
        END

        PRINT '==================================================';
        PRINT 'Reload complete. Total: ' + CAST(DATEDIFF(second, @batch_time, SYSDATETIME()) AS NVARCHAR) + ' sec.';
        PRINT 'bronze.sap_bsis is complete again - silver.load_silver can run now.';
        PRINT '==================================================';

    END TRY
    BEGIN CATCH

        PRINT '==================================================';
        PRINT 'ERROR IN bronze.recargar_bsis';
        PRINT 'Year: '    + CAST(@yr AS NVARCHAR);
        PRINT 'Message: ' + ERROR_MESSAGE();
        PRINT 'Line: '    + CAST(ERROR_LINE() AS VARCHAR(10));
        PRINT 'bronze.sap_bsis is INCOMPLETE. Run the procedure again from the start:';
        PRINT '  EXEC bronze.recargar_bsis;';
        PRINT '==================================================';

        THROW;

    END CATCH
END;
GO

PRINT 'Procedure bronze.recargar_bsis created successfully.';
GO
