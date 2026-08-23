USE ANALISIS_DATOS;
GO

/*
===============================================================================
PROJECT: Enterprise Data Warehouse (dwh-ciosa)
LAYER: DQ (Data Quality - BUSINESS data-quality exceptions)

Deliberately separated from 'gold': gold is for reporting/BI (dimensions and
facts ready for consumption), dq is for the data team to know what to fix in
SAP. Also separate from 'control' (load-EXECUTION auditing schema, see
ddl_bronze.sql section 9-11) - control is about "did the load run
correctly," dq is about "the business data is inconsistent." These are
different concepts and shouldn't be mixed.

Each dq.* table is fully recalculated on every run of its corresponding load
procedure (TRUNCATE+INSERT) - it doesn't accumulate a history of already-
fixed cases, it always reflects the current state.
===============================================================================
*/

-- ==========================================================
-- 1. TABLE: dq.clientes_ambiguos
-- Customers with 2+ simultaneous ACTIVO channels in
-- gold.vw_cliente_canal_estatus - contradicts ciosa.py's business rule
-- ("a customer can only be active in one channel"). Does NOT block the
-- gold.dim_cliente_comercial load - that still uses its own tiebreaker
-- (status priority, then lowest channel) to pick a representative anyway.
-- This table exists only so the data team can investigate/fix it in SAP.
-- ==========================================================
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

PRINT 'Table dq.clientes_ambiguos created successfully.';
GO
