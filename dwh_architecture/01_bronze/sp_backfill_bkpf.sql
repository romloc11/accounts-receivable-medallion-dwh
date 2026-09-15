/* ============================================================================
   bronze.backfill_bkpf
   Purpose : Historical load of bronze.sap_bkpf (DZ documents), one year at a time.
   Run     : EXEC bronze.backfill_bkpf @start_year = 2022 [, @end_year = 2026];
             On an empty table, before the first bronze.load_bronze. Resumable:
             a year that already has rows in the target is skipped.
   Notes   : Positional INSERT ... SELECT *: bronze.sap_bkpf keeps P01's column
             order (see generar_ddl_desde_p01.sql).
   ============================================================================ */
USE ANALISIS_DATOS;
GO

IF OBJECT_ID('bronze.backfill_bkpf', 'P') IS NOT NULL
    DROP PROCEDURE bronze.backfill_bkpf;
GO

CREATE PROCEDURE bronze.backfill_bkpf
    @start_year INT,
    @end_year   INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @proc VARCHAR(128) = 'bronze.backfill_bkpf',
            @step VARCHAR(128) = 'start',
            @t0   DATETIME2(0) = SYSDATETIME(),
            @t    DATETIME2(0) = SYSDATETIME(),
            @rows INT,
            @err  VARCHAR(4000),
            @line INT,
            @yr             INT,
            @range_start    NVARCHAR(8),
            @range_end      NVARCHAR(8),
            @already_loaded BIT;

    SET @yr = @start_year;
    SET @end_year = ISNULL(@end_year, YEAR(GETDATE()));

    BEGIN TRY
        WHILE @yr <= @end_year
        BEGIN
            SET @range_start = CAST(@yr AS NVARCHAR(4)) + '0101';
            SET @range_end   = CAST(@yr AS NVARCHAR(4)) + '1231';
            SET @step = 'bronze.sap_bkpf ' + CAST(@yr AS VARCHAR(4)); SET @t = SYSDATETIME();

            SET @already_loaded = CASE WHEN EXISTS (
                SELECT TOP 1 1 FROM bronze.sap_bkpf WHERE BUDAT BETWEEN @range_start AND @range_end
            ) THEN 1 ELSE 0 END;

            IF @already_loaded = 1
            BEGIN
                SET @step = @step + ' skipped, already loaded';
                EXEC control.log_step @proc, @step, @t, 0;
            END
            ELSE
            BEGIN
                INSERT INTO bronze.sap_bkpf
                SELECT *
                FROM P01.p01.BKPF WITH (NOLOCK)
                WHERE BLART = 'DZ'
                  AND BUDAT BETWEEN @range_start AND @range_end;
                SET @rows = @@ROWCOUNT;
                EXEC control.log_step @proc, @step, @t, @rows;
            END

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
