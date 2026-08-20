USE ANALISIS_DATOS;
GO

/*
===============================================================================
PROJECT: Enterprise Data Warehouse (dwh-ciosa)
LAYER: Gold - one-time population script for gold.dim_fecha (2020-01-01 to
2035-12-31). NOT part of the regular gold load cycle - run once after
ddl_gold.sql creates the table, and only re-run (or extend) manually if the
date range ever needs to grow.

Uses a plain WHILE loop instead of a recursive CTE - simplest, most robust
pattern given this SQL Server 2012 instance's history of unexplained syntax
errors on less common constructs (see ddl_bronze.sql / sp_load_bronze.sql
notes). Only ~5,844 rows, performance is a non-issue.

Month/day names are hardcoded in Spanish via CASE, not DATENAME() - DATENAME's
output language depends on server/session locale, which we don't want to
depend on.
===============================================================================
*/

SET DATEFIRST 7;  -- domingo = 1, explicito para no depender de la configuracion del servidor
GO

TRUNCATE TABLE gold.dim_fecha;
GO

DECLARE @fecha_inicio DATE = '2020-01-01';
DECLARE @fecha_fin DATE = '2035-12-31';
DECLARE @fecha_actual DATE = @fecha_inicio;

WHILE @fecha_actual <= @fecha_fin
BEGIN
    INSERT INTO gold.dim_fecha (
        fecha, anio, mes, nombre_mes, trimestre, dia,
        dia_semana, nombre_dia_semana, es_fin_de_semana, semana_anio
    )
    VALUES (
        @fecha_actual,
        YEAR(@fecha_actual),
        MONTH(@fecha_actual),
        CASE MONTH(@fecha_actual)
            WHEN 1 THEN 'Enero' WHEN 2 THEN 'Febrero' WHEN 3 THEN 'Marzo' WHEN 4 THEN 'Abril'
            WHEN 5 THEN 'Mayo' WHEN 6 THEN 'Junio' WHEN 7 THEN 'Julio' WHEN 8 THEN 'Agosto'
            WHEN 9 THEN 'Septiembre' WHEN 10 THEN 'Octubre' WHEN 11 THEN 'Noviembre' WHEN 12 THEN 'Diciembre'
        END,
        DATEPART(QUARTER, @fecha_actual),
        DAY(@fecha_actual),
        DATEPART(WEEKDAY, @fecha_actual),
        CASE DATEPART(WEEKDAY, @fecha_actual)
            WHEN 1 THEN 'Domingo' WHEN 2 THEN 'Lunes' WHEN 3 THEN 'Martes' WHEN 4 THEN 'Miercoles'
            WHEN 5 THEN 'Jueves' WHEN 6 THEN 'Viernes' WHEN 7 THEN 'Sabado'
        END,
        CASE WHEN DATEPART(WEEKDAY, @fecha_actual) IN (1, 7) THEN 1 ELSE 0 END,
        DATEPART(ISO_WEEK, @fecha_actual)
    );
    SET @fecha_actual = DATEADD(DAY, 1, @fecha_actual);
END;
GO

DECLARE @filas INT;
SELECT @filas = COUNT(*) FROM gold.dim_fecha;
PRINT 'gold.dim_fecha poblada: ' + CAST(@filas AS VARCHAR) + ' filas.';
GO
