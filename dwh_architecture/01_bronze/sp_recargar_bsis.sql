/* ============================================================================
   bronze.recargar_bsis
   Purpose : Full reload of bronze.sap_bsis from P01, one year at a time.
             Recovers what the daily two-step load cannot see: postings into a
             reopened old period and lines archived out of SAP.
   Run     : EXEC bronze.recargar_bsis [@start_year = 2022];
             Not part of the daily load. Outside business hours (~2.9M rows
             from production). Truncates first: do not run silver.load_silver
             until it finishes. @start_year does not keep older years.
   Notes   : Then silver.load_silver, or 02_silver/backfill_bsas_bsis_historico.sql
             for years older than silver's window.
   ============================================================================ */
USE ANALISIS_DATOS;
GO

IF OBJECT_ID('bronze.recargar_bsis', 'P') IS NOT NULL
    DROP PROCEDURE bronze.recargar_bsis;
GO

CREATE PROCEDURE bronze.recargar_bsis
    @start_year INT = 2022
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @proc VARCHAR(128) = 'bronze.recargar_bsis',
            @step VARCHAR(128) = 'start',
            @t0   DATETIME2(0) = SYSDATETIME(),
            @t    DATETIME2(0) = SYSDATETIME(),
            @rows INT,
            @err  VARCHAR(4000),
            @line INT,
            @yr   INT;

    BEGIN TRY
        SET @step = 'bronze.sap_bsis truncate'; SET @t = SYSDATETIME();
        TRUNCATE TABLE bronze.sap_bsis;
        EXEC control.log_step @proc, @step, @t;

        SET @yr = @start_year;

        WHILE @yr <= YEAR(GETDATE())
        BEGIN
            SET @step = 'bronze.sap_bsis ' + CAST(@yr AS VARCHAR(4)); SET @t = SYSDATETIME();

            INSERT INTO bronze.sap_bsis
            SELECT *
            FROM P01.p01.BSIS WITH (NOLOCK)
            WHERE BUDAT BETWEEN CAST(@yr AS NVARCHAR(4)) + '0101'
                            AND CAST(@yr AS NVARCHAR(4)) + '1231'
              AND (HKONT LIKE '0000111%' OR HKONT LIKE '0000113%');
            SET @rows = @@ROWCOUNT;
            EXEC control.log_step @proc, @step, @t, @rows;

            SET @yr = @yr + 1;
        END

        EXEC control.log_step @proc, 'total', @t0;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        SELECT @err = ERROR_MESSAGE(), @line = ERROR_LINE();
        EXEC control.log_step @proc, @step, @t, NULL, @err, @line;
        THROW;
    END CATCH
END;
GO
