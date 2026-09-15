/* ============================================================================
   dq.load_clientes_ambiguos
   Purpose : Recalculates dq.clientes_ambiguos from gold.vw_cliente_canal_estatus.
   Run     : EXEC dq.load_clientes_ambiguos;   after gold.load_gold
   ============================================================================ */
USE ANALISIS_DATOS;
GO

IF OBJECT_ID('dq.load_clientes_ambiguos', 'P') IS NOT NULL
    DROP PROCEDURE dq.load_clientes_ambiguos;
GO

CREATE PROCEDURE dq.load_clientes_ambiguos
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @proc VARCHAR(128) = 'dq.load_clientes_ambiguos',
            @step VARCHAR(128) = 'start',
            @t0   DATETIME2(0) = SYSDATETIME(),
            @t    DATETIME2(0) = SYSDATETIME(),
            @rows INT,
            @err  VARCHAR(4000),
            @line INT;

    BEGIN TRY
        SET @step = 'dq.clientes_ambiguos full'; SET @t = SYSDATETIME();

        TRUNCATE TABLE dq.clientes_ambiguos;

        INSERT INTO dq.clientes_ambiguos (cliente_id, canales_activos)
        SELECT cliente_id, COUNT(*)
        FROM gold.vw_cliente_canal_estatus
        WHERE estatus_comercial = 'ACTIVO'
        GROUP BY cliente_id
        HAVING COUNT(*) > 1;

        SET @rows = @@ROWCOUNT;
        EXEC control.log_step @proc, @step, @t, @rows;

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
