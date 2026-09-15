/* ============================================================================
   Collections budget model (v2, by aging)
   Purpose : Estimates recovery rates per aging bucket on TRAIN months
             (2024-2025) and backtests the budget on TEST months (2026).
   Run     : any time; read-only analysis. Production load:
             sp_load_presupuesto.sql.
   Notes   : Budget = T1 + T2 + T3
               T1  portfolio open at the cut-off x its bucket's recovery rate
               T2  collected from day 1 to the cut-off (observed, not predicted)
               T3  invoiced-and-collected within the month plus unlinked
                   payments, as a factor k over T1
             Out-of-sample error 3.53% (manual method 23.4%). History of the
             model, rates and robustness tests in DESIGN.md.
   ============================================================================ */
USE ANALISIS_DATOS;
GO

SET NOCOUNT ON;

-- ----------------------------------------------------------------------------
-- 1. Calendar: the cut-off is the 4th business day, when the number is issued.
-- ----------------------------------------------------------------------------
IF OBJECT_ID('tempdb..#mes') IS NOT NULL DROP TABLE #mes;
SELECT DATEFROMPARTS(anio, mes, 1)              AS ini,
       EOMONTH(DATEFROMPARTS(anio, mes, 1))     AS fin,
       MIN(CASE WHEN dia_habil_del_mes = 4 THEN fecha END) AS corte,
       CASE WHEN anio < 2026 THEN 'TRAIN' ELSE 'TEST' END  AS uso
INTO   #mes
FROM   gold.dim_fecha
WHERE  fecha >= '2024-01-01' AND fecha < '2026-09-01'
GROUP BY anio, mes;

-- ----------------------------------------------------------------------------
-- 2. Portfolio open at the cut-off: issued before the month, still open on the
--    cut-off day, channel resolved at the cut-off (SCD2).
-- ----------------------------------------------------------------------------
IF OBJECT_ID('tempdb..#cartera') IS NOT NULL DROP TABLE #cartera;
SELECT m.ini, m.uso, f.monto,
       CASE
         WHEN DATEDIFF(DAY, f.fecha_vencimiento, m.corte) <  0
              AND f.fecha_vencimiento <= m.fin                  THEN 'A1'
         WHEN DATEDIFF(DAY, f.fecha_vencimiento, m.corte) <  0   THEN 'A2'
         WHEN DATEDIFF(DAY, f.fecha_vencimiento, m.corte) <=  30 THEN 'B'
         WHEN DATEDIFF(DAY, f.fecha_vencimiento, m.corte) <=  60 THEN 'C'
         WHEN DATEDIFF(DAY, f.fecha_vencimiento, m.corte) <=  90 THEN 'D'
         WHEN DATEDIFF(DAY, f.fecha_vencimiento, m.corte) <= 180 THEN 'E'
         WHEN DATEDIFF(DAY, f.fecha_vencimiento, m.corte) <= 365 THEN 'F'
         ELSE 'G'
       END AS bucket,
       -- Only used to estimate rates on TRAIN; never enters the forecast.
       CASE WHEN f.fecha_pago_efectiva BETWEEN m.corte AND m.fin
            THEN f.monto ELSE 0 END AS cobrado
INTO   #cartera
FROM   #mes m
JOIN   gold.fact_facturas f
       ON  f.fecha_documento < m.ini
       AND (f.fecha_compensacion IS NULL OR f.fecha_compensacion >= m.corte)
       AND f.fecha_vencimiento IS NOT NULL
JOIN   gold.dim_cliente_comercial d
       ON  d.cliente_id = f.cliente_id
       AND m.corte >= d.fecha_inicio_vigencia
       AND (d.fecha_fin_vigencia IS NULL OR m.corte <= d.fecha_fin_vigencia)
       AND d.canal_distribucion IN (10, 40, 60);

-- ----------------------------------------------------------------------------
-- 3. Rates, TRAIN only, weighted by amount
-- ----------------------------------------------------------------------------
IF OBJECT_ID('tempdb..#tasa') IS NOT NULL DROP TABLE #tasa;
SELECT bucket, SUM(cobrado) / NULLIF(SUM(monto), 0) AS tasa
INTO   #tasa
FROM   #cartera
WHERE  uso = 'TRAIN'
GROUP BY bucket;

-- ----------------------------------------------------------------------------
-- 4. T1, T2 and actual cash per month
-- ----------------------------------------------------------------------------
IF OBJECT_ID('tempdb..#term') IS NOT NULL DROP TABLE #term;
SELECT m.ini, m.uso, t1.v AS t1, t2.v AS t2, caja.v AS real_caja
INTO   #term
FROM   #mes m
CROSS APPLY (SELECT SUM(c.monto * t.tasa) AS v
             FROM #cartera c JOIN #tasa t ON t.bucket = c.bucket
             WHERE c.ini = m.ini) t1
CROSS APPLY (SELECT SUM(g.monto) AS v FROM gold.fact_pagos g
             WHERE g.fecha_documento >= m.ini AND g.fecha_documento < m.corte) t2
CROSS APPLY (SELECT SUM(g.monto) AS v FROM gold.fact_pagos g
             WHERE g.fecha_documento >= m.ini AND g.fecha_documento <= m.fin) caja;

-- ----------------------------------------------------------------------------
-- 5. T3 factor
-- ----------------------------------------------------------------------------
DECLARE @k DECIMAL(10,6) =
    (SELECT SUM(real_caja - t1 - t2) / SUM(t1) FROM #term WHERE uso = 'TRAIN');

-- ----------------------------------------------------------------------------
-- 6. Backtest
-- ----------------------------------------------------------------------------
SELECT ini AS mes,
       CAST(t1        /1000000.0 AS DECIMAL(10,1)) AS T1_cartera_mm,
       CAST(t2        /1000000.0 AS DECIMAL(10,1)) AS T2_ya_en_banco_mm,
       CAST(t1*@k     /1000000.0 AS DECIMAL(10,1)) AS T3_del_mes_mm,
       CAST((t1+t2+t1*@k)/1000000.0 AS DECIMAL(10,1)) AS presupuesto_mm,
       CAST(real_caja /1000000.0 AS DECIMAL(10,1)) AS real_mm,
       CAST(100.0*(real_caja-(t1+t2+t1*@k))/NULLIF(t1+t2+t1*@k,0) AS DECIMAL(6,1)) AS err_pct
FROM   #term WHERE uso = 'TEST' ORDER BY ini;

SELECT CAST(AVG(ABS(100.0*(real_caja-(t1+t2+t1*@k))/NULLIF(t1+t2+t1*@k,0))) AS DECIMAL(6,2)) AS error_abs_medio_pct,
       CAST(AVG(    100.0*(real_caja-(t1+t2+t1*@k))/NULLIF(t1+t2+t1*@k,0))  AS DECIMAL(6,2)) AS sesgo_pct
FROM   #term WHERE uso = 'TEST';
