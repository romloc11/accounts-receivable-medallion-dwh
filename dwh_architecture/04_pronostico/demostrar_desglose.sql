/* ============================================================================
   Monthly breakdown: supporting queries
   Purpose : One query per question about desglose_cobranza_mes.sql.
   Run     : any time; read-only. Run one batch at a time; change @ini in each.
   Notes   : Settled invoices (face value) and the month's cash measure different
             things; query 6 splits payments instead of invoices and adds up to
             the cash exactly.
   ============================================================================ */
USE ANALISIS_DATOS;
GO

-- ----------------------------------------------------------------------------
-- 1. The same payments by three dates: payment, clearing and posting.
-- ----------------------------------------------------------------------------
DECLARE @ini DATE = '2026-07-01';
DECLARE @fin DATE = EOMONTH(@ini);

SELECT 'fecha_documento      (cuando pago el cliente)' AS criterio,
       COUNT(*) AS n_pagos, CAST(SUM(monto)/1000000.0 AS DECIMAL(12,2)) AS monto_mm
FROM   gold.fact_pagos WHERE fecha_documento BETWEEN @ini AND @fin
UNION ALL
SELECT 'fecha_compensacion   (cuando se aplico)  <- los "149"',
       COUNT(*), CAST(SUM(monto)/1000000.0 AS DECIMAL(12,2))
FROM   gold.fact_pagos WHERE fecha_compensacion BETWEEN @ini AND @fin
UNION ALL
SELECT 'fecha_contabilizacion (cuando lo capturo contabilidad)',
       COUNT(*), CAST(SUM(monto)/1000000.0 AS DECIMAL(12,2))
FROM   gold.fact_pagos WHERE fecha_contabilizacion BETWEEN @ini AND @fin;
GO

-- ----------------------------------------------------------------------------
-- 2. Each slice with the dates that define it in view.
-- ----------------------------------------------------------------------------
DECLARE @ini DATE = '2026-07-01';
DECLARE @fin DATE = EOMONTH(@ini);

SELECT CASE
         WHEN f.fecha_documento >= @ini                    THEN '2. Facturado y cobrado dentro del mes'
         WHEN f.fecha_vencimiento BETWEEN @ini AND @fin    THEN '1. Cartera del mes'
         WHEN f.fecha_vencimiento >  @fin                  THEN '3. Anticipado'
         ELSE                                                   '4. Cartera vencida'
       END AS categoria,
       COUNT(*)                                        AS facturas,
       COUNT(DISTINCT f.cliente_id)                    AS clientes,
       CAST(SUM(f.monto)/1000000.0 AS DECIMAL(12,2))   AS monto_mm,
       CAST(100.0*SUM(f.monto)/SUM(SUM(f.monto)) OVER () AS DECIMAL(5,1)) AS pct,
       MIN(f.fecha_documento)   AS factura_mas_vieja,
       MIN(f.fecha_vencimiento) AS vencimiento_mas_viejo
FROM   gold.fact_facturas f
WHERE  f.fecha_pago_efectiva BETWEEN @ini AND @fin
GROUP BY CASE
         WHEN f.fecha_documento >= @ini                    THEN '2. Facturado y cobrado dentro del mes'
         WHEN f.fecha_vencimiento BETWEEN @ini AND @fin    THEN '1. Cartera del mes'
         WHEN f.fecha_vencimiento >  @fin                  THEN '3. Anticipado'
         ELSE                                                   '4. Cartera vencida'
       END
ORDER BY categoria;
GO

-- ----------------------------------------------------------------------------
-- 3. Partition test: every invoice in one slice, total matches. Expect SI / 0 / 0.
-- ----------------------------------------------------------------------------
DECLARE @ini DATE = '2026-07-01';
DECLARE @fin DATE = EOMONTH(@ini);

IF OBJECT_ID('tempdb..#cat') IS NOT NULL DROP TABLE #cat;
SELECT f.sociedad, f.ejercicio, f.documento_id, f.posicion, f.monto,
       CASE
         WHEN f.fecha_documento >= @ini                 THEN 2
         WHEN f.fecha_vencimiento BETWEEN @ini AND @fin THEN 1
         WHEN f.fecha_vencimiento >  @fin               THEN 3
         ELSE                                                4
       END AS cat
INTO   #cat
FROM   gold.fact_facturas f
WHERE  f.fecha_pago_efectiva BETWEEN @ini AND @fin;

SELECT 'Suma de las 4 categorias = total de facturas liquidadas' AS prueba,
       CASE WHEN (SELECT SUM(monto) FROM #cat)
               = (SELECT SUM(monto) FROM gold.fact_facturas
                  WHERE fecha_pago_efectiva BETWEEN @ini AND @fin)
            THEN 'SI' ELSE 'NO' END AS resultado
UNION ALL
SELECT 'Facturas contadas en mas de una categoria',
       CAST(COUNT(*) AS VARCHAR(20)) FROM (
         SELECT sociedad, ejercicio, documento_id, posicion
         FROM #cat GROUP BY sociedad, ejercicio, documento_id, posicion
         HAVING COUNT(*) > 1) d
UNION ALL
SELECT 'Facturas sin categoria (NULL)',
       CAST(COUNT(*) AS VARCHAR(20)) FROM #cat WHERE cat IS NULL;
GO

-- ----------------------------------------------------------------------------
-- 4. Invoices of one slice. @categoria: 1 cartera del mes, 2 facturado y cobrado
--    en el mes, 3 anticipado, 4 cartera vencida.
-- ----------------------------------------------------------------------------
DECLARE @ini DATE = '2026-07-01';
DECLARE @fin DATE = EOMONTH(@ini);
DECLARE @categoria INT = 1;

SELECT TOP 100
       f.cliente_id, c.nombre AS cliente,
       f.documento_id AS factura,
       f.fecha_documento      AS emitida,
       f.fecha_vencimiento    AS vence,
       f.fecha_pago_efectiva  AS pagada,
       f.dias_pago            AS dias_vs_vencimiento,
       CAST(f.monto AS DECIMAL(14,2)) AS monto
FROM   gold.fact_facturas f
LEFT JOIN gold.dim_cliente c ON c.cliente_id = f.cliente_id
WHERE  f.fecha_pago_efectiva BETWEEN @ini AND @fin
  AND  CASE
         WHEN f.fecha_documento >= @ini                 THEN 2
         WHEN f.fecha_vencimiento BETWEEN @ini AND @fin THEN 1
         WHEN f.fecha_vencimiento >  @fin               THEN 3
         ELSE                                                4
       END = @categoria
ORDER BY f.monto DESC;
GO

-- ----------------------------------------------------------------------------
-- 5. Payments that settle no invoice, one by one.
-- ----------------------------------------------------------------------------
DECLARE @ini DATE = '2026-07-01';
DECLARE @fin DATE = EOMONTH(@ini);

SELECT s.motivo, p.cliente_id, c.nombre AS cliente,
       p.documento_id AS pago, p.fecha_documento AS pagado,
       CAST(p.monto AS DECIMAL(14,2)) AS monto, p.texto
FROM   gold.fact_pagos_sin_aplicacion s
JOIN   gold.fact_pagos p ON p.sociedad=s.sociedad AND p.cliente_id=s.cliente_id
       AND p.ejercicio=s.ejercicio AND p.documento_id=s.documento_id AND p.posicion=s.posicion
LEFT JOIN gold.dim_cliente c ON c.cliente_id = p.cliente_id
WHERE  p.fecha_documento BETWEEN @ini AND @fin
ORDER BY s.motivo, p.monto DESC;
GO

-- ----------------------------------------------------------------------------
-- 6. The difference against cash, splitting payments instead of invoices: each
--    payment counts once, so the classes add up to the month's cash.
--    Most of the gap is payments bringing more or less than the face value of
--    the invoices they settled, not payments to invoices of another month.
--    Crosses the whole bridge (~1 minute).
-- ----------------------------------------------------------------------------
DECLARE @ini DATE = '2026-07-01';
DECLARE @fin DATE = EOMONTH(@ini);

IF OBJECT_ID('tempdb..#p') IS NOT NULL DROP TABLE #p;
SELECT p.sociedad, p.ejercicio, p.documento_id, p.posicion, p.monto
INTO   #p FROM gold.fact_pagos p
WHERE  p.fecha_documento BETWEEN @ini AND @fin;
CREATE UNIQUE CLUSTERED INDEX ix_p ON #p(sociedad, ejercicio, documento_id, posicion);

IF OBJECT_ID('tempdb..#lig') IS NOT NULL DROP TABLE #lig;
SELECT p.sociedad, p.ejercicio, p.documento_id, p.posicion,
       COUNT(*) AS n_fact,
       SUM(CASE WHEN f.fecha_pago_efectiva BETWEEN @ini AND @fin THEN 0 ELSE 1 END) AS n_fuera
INTO   #lig
FROM   #p p
JOIN   gold.fact_aplicacion_pagos b
       ON  b.sociedad = p.sociedad AND b.ejercicio_pago = p.ejercicio
       AND b.pago_id = p.documento_id AND b.posicion_pago = p.posicion
JOIN   gold.fact_facturas f
       ON  f.sociedad = b.sociedad AND f.ejercicio = b.ejercicio_factura
       AND f.documento_id = b.factura_id AND f.posicion = b.posicion_factura
GROUP BY p.sociedad, p.ejercicio, p.documento_id, p.posicion
OPTION (RECOMPILE);

SELECT CASE WHEN l.n_fact IS NULL       THEN 'D. no liga a ninguna factura'
            WHEN l.n_fuera = 0          THEN 'A. todas sus facturas se liquidaron en el mes'
            WHEN l.n_fuera = l.n_fact   THEN 'C. sus facturas se liquidaron en otro mes'
            ELSE                             'B. mezcla de las dos' END AS clase,
       COUNT(*) AS n_pagos,
       CAST(SUM(p.monto)/1000000.0 AS DECIMAL(12,2)) AS monto_mm,
       CAST(100.0*SUM(p.monto)/SUM(SUM(p.monto)) OVER () AS DECIMAL(5,1)) AS pct
FROM   #p p
LEFT JOIN #lig l ON l.sociedad=p.sociedad AND l.ejercicio=p.ejercicio
                AND l.documento_id=p.documento_id AND l.posicion=p.posicion
GROUP BY CASE WHEN l.n_fact IS NULL       THEN 'D. no liga a ninguna factura'
              WHEN l.n_fuera = 0          THEN 'A. todas sus facturas se liquidaron en el mes'
              WHEN l.n_fuera = l.n_fact   THEN 'C. sus facturas se liquidaron en otro mes'
              ELSE                             'B. mezcla de las dos' END
ORDER BY clase;
GO
