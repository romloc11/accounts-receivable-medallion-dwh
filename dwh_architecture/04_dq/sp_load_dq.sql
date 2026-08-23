USE ANALISIS_DATOS;
GO

/*
===============================================================================
PROJECT: Enterprise Data Warehouse (dwh-ciosa)
LAYER: DQ - load procedures.

STYLE: independent procedures, NOT called from within gold's load procedures
(and vice versa) - calling one stored procedure from inside another is the
exact pattern that broke control.sp_log_load on this SQL Server 2012 instance
(see ddl_bronze.sql section 10 / sp_load_bronze.sql for the full story). So
even though dq.load_clientes_ambiguos and gold.load_dim_cliente_comercial
both read from gold.vw_cliente_canal_estatus, they are run as two SEPARATE
EXEC statements, never one calling the other.
===============================================================================
*/

-- ==========================================================
-- dq.load_clientes_ambiguos
-- ==========================================================
IF OBJECT_ID('dq.load_clientes_ambiguos', 'P') IS NOT NULL
    DROP PROCEDURE dq.load_clientes_ambiguos;
GO

CREATE PROCEDURE dq.load_clientes_ambiguos
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @start_time DATETIME, @end_time DATETIME, @rows_count INT;

    BEGIN TRY
        SET @start_time = GETDATE();
        PRINT '>> Loading dq.clientes_ambiguos...';

        TRUNCATE TABLE dq.clientes_ambiguos;

        INSERT INTO dq.clientes_ambiguos (cliente_id, canales_activos)
        SELECT cliente_id, COUNT(*)
        FROM gold.vw_cliente_canal_estatus
        WHERE estatus_comercial = 'ACTIVO'
        GROUP BY cliente_id
        HAVING COUNT(*) > 1;

        SET @rows_count = @@ROWCOUNT;

        SET @end_time = GETDATE();
        PRINT 'Rows: ' + CAST(@rows_count AS NVARCHAR) + ' | Duration: ' + CAST(DATEDIFF(SECOND, @start_time, @end_time) AS NVARCHAR) + ' s';
    END TRY
    BEGIN CATCH
        PRINT 'ERROR in dq.clientes_ambiguos: ' + ERROR_MESSAGE();
        THROW;
    END CATCH;
END;
GO

PRINT 'Procedure dq.load_clientes_ambiguos created successfully.';
GO
