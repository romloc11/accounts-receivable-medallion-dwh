USE ANALISIS_DATOS;
GO

IF OBJECT_ID('gold.load_fact_movimientos_compensados', 'P') IS NOT NULL
    DROP PROCEDURE gold.load_fact_movimientos_compensados;
GO

IF OBJECT_ID('gold.fact_movimientos_compensados', 'U') IS NOT NULL
    DROP TABLE gold.fact_movimientos_compensados;
GO

PRINT 'gold.fact_movimientos_compensados y su procedure eliminados.';
GO
