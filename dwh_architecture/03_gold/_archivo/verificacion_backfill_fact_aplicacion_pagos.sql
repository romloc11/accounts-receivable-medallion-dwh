USE ANALISIS_DATOS;
GO

-- Reconciliacion final del backfill (2024-01-01 a hoy): toda factura de
-- silver.sap_bsad en el rango debe tener AL MENOS una fila en la fact
-- (resuelta o residuo NULL) - si faltan, algo se salio del backfill.

DECLARE @fecha_inicio DATE = '20240101';
DECLARE @fecha_fin    DATE = '20260817';

SELECT
    (SELECT COUNT(*) FROM silver.sap_bsad
     WHERE clase_documento IN ('F1','F2','F3','F4','F5','F6')
       AND fecha_compensacion BETWEEN @fecha_inicio AND @fecha_fin) AS facturas_en_silver,
    (SELECT COUNT(DISTINCT CONCAT(sociedad,'|',cliente_id,'|',documento_factura,'|',ejercicio_factura,'|',posicion_factura))
     FROM gold.fact_aplicacion_pagos
     WHERE fecha_compensacion BETWEEN @fecha_inicio AND @fecha_fin) AS facturas_distintas_en_fact,
    (SELECT COUNT(*) FROM gold.fact_aplicacion_pagos
     WHERE fecha_compensacion BETWEEN @fecha_inicio AND @fecha_fin) AS total_filas_fact;
GO
