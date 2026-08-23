USE ANALISIS_DATOS;
GO

-- Create Bronze schema if it doesn't exist
IF NOT EXISTS (SELECT * FROM sys.schemas WHERE name = 'bronze')
BEGIN
    EXEC('CREATE SCHEMA bronze;');
    PRINT 'Schema [bronze] created successfully.';
END
GO

-- Create Silver schema if it doesn't exist
IF NOT EXISTS (SELECT * FROM sys.schemas WHERE name = 'silver')
BEGIN
    EXEC('CREATE SCHEMA silver;');
    PRINT 'Schema [silver] created successfully.';
END
GO

-- Create Gold schema if it doesn't exist
IF NOT EXISTS (SELECT * FROM sys.schemas WHERE name = 'gold')
BEGIN
    EXEC('CREATE SCHEMA gold;');
    PRINT 'Schema [gold] created successfully.';
END
GO

-- Create Control schema (load auditing) if it doesn't exist
IF NOT EXISTS (SELECT * FROM sys.schemas WHERE name = 'control')
BEGIN
    EXEC('CREATE SCHEMA control;');
    PRINT 'Schema [control] created successfully.';
END
GO

-- Create DQ schema (business data-quality exceptions, distinct from
-- "control" which is load-execution auditing) if it doesn't exist
IF NOT EXISTS (SELECT * FROM sys.schemas WHERE name = 'dq')
BEGIN
    EXEC('CREATE SCHEMA dq;');
    PRINT 'Schema [dq] created successfully.';
END
GO
