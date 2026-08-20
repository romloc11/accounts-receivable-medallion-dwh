USE ANALISIS_DATOS;
GO

-- Investigacion del desfase 2,902,956 (silver) vs 2,900,207 (fact) hallado en
-- la reconciliacion del backfill. Hipotesis: la tolerancia de $1 (agregada
-- 2026-08-14 para suprimir residuos de centavos) tambien esta excluyendo del
-- Nivel 3 a facturas de monto muy chico (<=$1) que NUNCA tuvieron ningun
-- match - no solo sobrantes de facturas ya resueltas.

DECLARE @fecha_inicio DATE = '20240101';
DECLARE @fecha_fin    DATE = '20260817';

;WITH en_fact AS (
    SELECT DISTINCT sociedad, cliente_id, documento_factura, ejercicio_factura, posicion_factura
    FROM gold.fact_aplicacion_pagos
    WHERE fecha_compensacion BETWEEN @fecha_inicio AND @fecha_fin
),
faltantes AS (
    SELECT b.sociedad, b.cliente_id, b.documento_id, b.ejercicio, b.posicion, b.monto_moneda_local, b.clase_documento
    FROM silver.sap_bsad b
    WHERE b.clase_documento IN ('F1','F2','F3','F4','F5','F6')
      AND b.fecha_compensacion BETWEEN @fecha_inicio AND @fecha_fin
      AND NOT EXISTS (
          SELECT 1 FROM en_fact e
          WHERE e.sociedad = b.sociedad AND e.cliente_id = b.cliente_id
            AND e.documento_factura = b.documento_id AND e.ejercicio_factura = b.ejercicio
            AND e.posicion_factura = b.posicion
      )
)
SELECT
    CASE WHEN monto_moneda_local <= 1.00 THEN '<= $1 (confirma hipotesis)' ELSE '> $1 (algo mas esta pasando)' END AS categoria,
    COUNT(*) AS num_facturas,
    SUM(monto_moneda_local) AS monto_total,
    MIN(monto_moneda_local) AS monto_min,
    MAX(monto_moneda_local) AS monto_max
FROM faltantes
GROUP BY CASE WHEN monto_moneda_local <= 1.00 THEN '<= $1 (confirma hipotesis)' ELSE '> $1 (algo mas esta pasando)' END;
GO
