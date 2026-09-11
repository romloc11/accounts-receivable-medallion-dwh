/* =====================================================================================
   PRUEBA 1 - De donde salen T1, T2 y T3 de septiembre
   =====================================================================================
   presupuesto = T1 + T2 + T3

     T1  cartera parada al corte x su tasa de recuperacion
     T2  cobrado del dia 1 al corte -> no se predice, se observa
     T3  facturado y cobrado dentro del mes, como factor sobre T1

   Corte de septiembre 2026: 4 de septiembre (4o dia habil).
   ===================================================================================== */


-- =====================================================================================
-- T1 -- cartera parada al corte, bucket por bucket
-- Cada renglon es cartera x tasa. La ultima linea es T1.
-- =====================================================================================
SELECT b.bucket_nombre                              AS bucket,
       SUM(c.monto_cartera)                         AS cartera,
       MAX(c.tasa_recuperacion)                     AS tasa,
       SUM(c.monto_esperado)                        AS esperado
FROM   gold.fact_presupuesto_cartera c
JOIN   gold.dim_bucket b ON b.bucket_key = c.bucket_key
WHERE  c.mes_presupuesto = '2026-09-01'
GROUP BY b.bucket_nombre, b.bucket_orden
ORDER BY b.bucket_orden;

SELECT SUM(monto_cartera) AS cartera_total,
       SUM(monto_esperado) AS T1
FROM   gold.fact_presupuesto_cartera
WHERE  mes_presupuesto = '2026-09-01';


-- =====================================================================================
-- T2 -- lo que ya estaba en el banco el dia del corte
-- No es pronostico: son los pagos del 1 al 3 de septiembre, ya cobrados.
-- =====================================================================================
SELECT fecha_documento AS dia,
       SUM(monto)      AS cobrado
FROM   gold.fact_pagos
WHERE  fecha_documento >= '2026-09-01'
AND    fecha_documento <  '2026-09-04'      -- el corte NO se incluye: es dia de pronostico
GROUP BY fecha_documento
ORDER BY fecha_documento;

SELECT SUM(monto) AS T2
FROM   gold.fact_pagos
WHERE  fecha_documento >= '2026-09-01'
AND    fecha_documento <  '2026-09-04';


-- =====================================================================================
-- T3 -- lo que se factura y se cobra dentro del mismo mes
-- Todavia no tiene factura el dia del corte, asi que no se puede ver: se estima como
-- un factor sobre T1. El factor sale de la historia, no de una suposicion.
--
-- Aqui se mide directo sobre los 24 meses previos: de cada peso de T1 que se predijo,
-- cuantos pesos extra entraron que NO venian de la cartera parada.
-- =====================================================================================
SELECT SUM(caja.total) - SUM(cartera.liquidado) - SUM(antes.cobrado)  AS dinero_extra,
       SUM(cartera.liquidado)                                          AS base_cartera,
       CAST( (SUM(caja.total) - SUM(cartera.liquidado) - SUM(antes.cobrado))
             / SUM(cartera.liquidado) AS DECIMAL(6,3))                 AS factor_T3
FROM  (SELECT DATEFROMPARTS(anio, mes, 1) AS ini,
              EOMONTH(DATEFROMPARTS(anio, mes, 1)) AS fin,
              MIN(CASE WHEN dia_habil_del_mes = 4 THEN fecha END) AS corte
       FROM   gold.dim_fecha
       WHERE  fecha >= '2024-09-01' AND fecha < '2026-09-01'
       GROUP BY anio, mes) m
CROSS APPLY (SELECT SUM(monto) AS total FROM gold.fact_pagos
             WHERE fecha_documento BETWEEN m.ini AND m.fin) caja
CROSS APPLY (SELECT SUM(monto) AS cobrado FROM gold.fact_pagos
             WHERE fecha_documento >= m.ini AND fecha_documento < m.corte) antes
CROSS APPLY (SELECT SUM(monto) AS liquidado FROM gold.fact_facturas
             WHERE fecha_documento < m.ini
             AND   fecha_pago_efectiva BETWEEN m.corte AND m.fin) cartera;


-- =====================================================================================
-- EL TOTAL -- lo que quedo guardado, para cerrar
-- OBSERVADO = T2 (dias antes del corte).  PRONOSTICO = T1 + T3.
-- =====================================================================================
SELECT origen,
       SUM(monto_presupuesto) AS monto
FROM   gold.fact_presupuesto_cobranza
WHERE  mes_presupuesto = '2026-09-01'
GROUP BY origen;

SELECT SUM(monto_presupuesto) AS presupuesto_septiembre
FROM   gold.fact_presupuesto_cobranza
WHERE  mes_presupuesto = '2026-09-01';
