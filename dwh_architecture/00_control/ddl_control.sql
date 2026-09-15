/* ============================================================================
   Control: load log
   Objects : control.load_log   one row per logged step of any load procedure
             control.log_step   prints the step and writes it to control.load_log
   Run     : once per server, after init_database.sql and before any load
             procedure is created. Re-running it keeps the logged history.
   Notes   : Every load procedure logs through control.log_step, so they all
             print the same line and leave the same history:
                 <process> | <step> | <rows> rows | <seconds> s
             Pass only variables or constants to EXEC parameters. A function
             call (e.g. @start_time = SYSDATETIME()) is a syntax error in T-SQL
             and fails the calling procedure with "Incorrect syntax near ')'".
   ============================================================================ */
USE ANALISIS_DATOS;
GO

IF OBJECT_ID('control.load_log', 'U') IS NULL
CREATE TABLE control.load_log (
    log_id            INT IDENTITY(1,1) NOT NULL,
    process_name      VARCHAR(128)  NOT NULL,
    step_name         VARCHAR(128)  NOT NULL,
    status            VARCHAR(10)   NOT NULL,   -- OK / FAILED
    rows_affected     INT           NULL,
    start_time        DATETIME2(0)  NOT NULL,
    end_time          DATETIME2(0)  NOT NULL,
    duration_seconds  INT           NOT NULL,
    error_line        INT           NULL,
    error_message     VARCHAR(4000) NULL,
    CONSTRAINT PK_load_log PRIMARY KEY CLUSTERED (log_id)
);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'IX_load_log_process' AND object_id = OBJECT_ID('control.load_log'))
    CREATE INDEX IX_load_log_process ON control.load_log (process_name, start_time);
GO

IF OBJECT_ID('control.log_step', 'P') IS NOT NULL
    DROP PROCEDURE control.log_step;
GO

CREATE PROCEDURE control.log_step
    @process_name  VARCHAR(128),
    @step_name     VARCHAR(128),
    @start_time    DATETIME2(0),
    @rows_affected INT           = NULL,
    @error_message VARCHAR(4000) = NULL,
    @error_line    INT           = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @end_time DATETIME2(0) = SYSDATETIME();
    DECLARE @seconds  INT          = DATEDIFF(SECOND, ISNULL(@start_time, @end_time), @end_time);
    DECLARE @msg      VARCHAR(2047) =
          CASE WHEN @error_message IS NULL THEN '   ' ELSE '!! ' END
        + ISNULL(@process_name, '?') + ' | ' + ISNULL(@step_name, '?')
        + ' | ' + ISNULL(CAST(@rows_affected AS VARCHAR(12)) + ' rows', '-')
        + ' | ' + CAST(@seconds AS VARCHAR(10)) + ' s'
        + ISNULL(' | line ' + CAST(@error_line AS VARCHAR(10)) + ': ' + @error_message, '');

    -- '%s' keeps a % inside the message from being read as a format code.
    RAISERROR('%s', 0, 1, @msg) WITH NOWAIT;

    INSERT INTO control.load_log
        (process_name, step_name, status, rows_affected, start_time, end_time,
         duration_seconds, error_line, error_message)
    VALUES
        (ISNULL(@process_name, '?'), ISNULL(@step_name, '?'),
         CASE WHEN @error_message IS NULL THEN 'OK' ELSE 'FAILED' END,
         @rows_affected, ISNULL(@start_time, @end_time), @end_time,
         @seconds, @error_line, @error_message);
END;
GO
