/* ============================================================================
   Data quality tables
   Objects : dq.clientes_ambiguos
   Purpose : Business data inconsistencies the team must fix in SAP. Separate
             from gold (reporting) and from control (load execution).
   Run     : once. Drops and recreates the tables.
   Notes   : Each table is recalculated whole by its load procedure; no history.
   ============================================================================ */
USE ANALISIS_DATOS;
GO

-- ----------------------------------------------------------------------------
-- dq.clientes_ambiguos: customers ACTIVO in 2+ channels at once. Does not block
-- gold.dim_cliente_comercial, which still picks a representative channel.
-- ----------------------------------------------------------------------------
IF OBJECT_ID('dq.clientes_ambiguos', 'U') IS NOT NULL
    DROP TABLE dq.clientes_ambiguos;
GO

CREATE TABLE dq.clientes_ambiguos (
    cliente_id       VARCHAR(10) NOT NULL,
    canales_activos  INT NOT NULL,
    fecha_deteccion  DATETIME DEFAULT GETDATE(),
    CONSTRAINT PK_clientes_ambiguos PRIMARY KEY CLUSTERED (cliente_id)
);
GO
