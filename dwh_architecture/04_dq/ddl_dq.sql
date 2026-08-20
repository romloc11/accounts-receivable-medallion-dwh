USE ANALISIS_DATOS;
GO

/*
===============================================================================
PROJECT: Enterprise Data Warehouse (dwh-ciosa)
LAYER: DQ (Data Quality - excepciones de calidad de dato de NEGOCIO)

Separado deliberadamente de 'gold': gold es para reportes/BI (dimensiones y
hechos listos para consumo), dq es para que el equipo de datos sepa que
corregir en SAP. Tambien separado de 'control' (esquema de auditoria de
EJECUCION de cargas, ver ddl_bronze.sql seccion 9-11) - control es sobre
"corrio bien la carga", dq es sobre "el dato de negocio es inconsistente".
Son conceptos distintos y no se mezclan.

Cada tabla dq.* se recalcula completa en cada corrida de su procedimiento de
carga correspondiente (TRUNCATE+INSERT) - no acumula historico de casos ya
corregidos, siempre refleja el estado actual.
===============================================================================
*/

-- ==========================================================
-- 1. TABLE: dq.clientes_ambiguos
-- Clientes con 2+ canales ACTIVO simultaneos en gold.vw_cliente_canal_estatus
-- - contradice la regla de negocio de ciosa.py ("un cliente solo puede estar
-- activo en un canal"). NO bloquea la carga de gold.dim_cliente_comercial -
-- esa sigue usando su propio desempate (prioridad de estatus, luego canal
-- mas bajo) para elegir un representante de todas formas. Esta tabla es solo
-- para que el equipo de datos investigue/corrija en SAP.
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
