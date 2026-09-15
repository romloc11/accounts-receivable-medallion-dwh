/* ============================================================================
   Database schemas
   Purpose : Creates the schemas bronze, silver, gold, control and dq.
   Run     : first, once per server. Safe to re-run.
   ============================================================================ */
USE ANALISIS_DATOS;
GO

IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = 'bronze')  EXEC('CREATE SCHEMA bronze;');
IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = 'silver')  EXEC('CREATE SCHEMA silver;');
IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = 'gold')    EXEC('CREATE SCHEMA gold;');
IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = 'control') EXEC('CREATE SCHEMA control;');
IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = 'dq')      EXEC('CREATE SCHEMA dq;');
GO
