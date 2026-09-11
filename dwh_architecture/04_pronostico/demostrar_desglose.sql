/* =====================================================================================
   COMO DEFENDER EL DESGLOSE DE UN MES
   dwh_architecture/04_pronostico/demostrar_desglose.sql              (2026-09-09)
   =====================================================================================

   Seis consultas, una por objecion. El resumen esta en desglose_cobranza_mes.sql;
   este archivo es para cuando alguien pregunta "y eso de donde sale".
   Cambiar @ini y sirve para cualquier mes. Correr de una en una.

   Julio 2026 da:

       Cartera del mes (vencia en julio, facturada antes)   $ 89.66M   64.2%
       Facturado y cobrado dentro de julio                  $ 26.75M   19.1%
       Anticipado (vencia en meses posteriores)             $ 11.39M    8.2%
       Cartera vencida (vencio antes de julio)              $ 11.90M    8.5%
       = FACTURAS LIQUIDADAS EN JULIO                       $139.70M  100.0%
       = CAJA DE JULIO                                      $151.81M

   LAS DOS CIFRAS MIDEN COSAS DISTINTAS, Y ESA ES LA PREGUNTA DIFICIL
   ------------------------------------------------------------------
   $139.70M es el VALOR NOMINAL de las facturas que se terminaron de pagar en julio.
   $151.81M es el DINERO que entro en julio.
   No tienen por que ser iguales, y la consulta 6 desarma la diferencia hasta el peso.

   Se mide por FACTURA y no por pago porque un deposito puede liquidar tres facturas
   -una del mes, una vencida y un anticipo- y no hay forma confiable de decir que parte
   del deposito fue a cual. El puente liga pagos con facturas pero NO reparte montos, a
   proposito. Contando facturas, cada monto tiene una sola categoria.
   ===================================================================================== */

-- =====================================================================================
-- CONSULTA 1 -- "Por que dicen 151.8 si nosotros siempre decimos 149?"
-- Los mismos pagos, tres fechas distintas. Ninguna esta mal; miden tres momentos.
-- =====================================================================================
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


-- =====================================================================================
-- CONSULTA 2 -- "De donde sale cada rebanada?"
-- La regla de cada categoria, escrita con las fechas a la vista. Nadie tiene que
-- confiar en una etiqueta: se ve la comparacion que la produce.
-- =====================================================================================
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


-- =====================================================================================
-- CONSULTA 3 -- "Como se que no estan contando lo mismo dos veces?"
-- Prueba de particion: cada factura cae en UNA categoria y el total cuadra.
-- Las tres filas deben decir SI / 0 / 0.
-- =====================================================================================
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


-- =====================================================================================
-- CONSULTA 4 -- "Ensename las facturas de esa rebanada"
-- El detalle. Cambiar @categoria: 1 cartera del mes, 2 facturado y cobrado en el mes,
-- 3 anticipado, 4 cartera vencida. Las tres fechas van a la vista para que cualquiera
-- verifique la clasificacion sin creerle a nadie.
-- =====================================================================================
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


-- =====================================================================================
-- CONSULTA 5 -- "Que son los 5.5 millones que no liquidan factura?"
-- No son errores. LIQUIDA_NO_FACTURA es dinero que salda algo que no es una factura.
-- Se listan uno por uno: son 53 pagos, caben en una pantalla.
-- =====================================================================================
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


-- =====================================================================================
-- CONSULTA 6 -- "Y los 12 millones de diferencia contra la caja?"
-- Esta es la pregunta dificil, y se contesta cambiando de lado: en vez de partir las
-- FACTURAS, se parten los PAGOS. Cada pago se cuenta una sola vez, asi que suma exacto
-- a la caja del mes y no hay reparto que suponer.
--
-- Julio 2026:
--     todas sus facturas se liquidaron en julio   11,908 pagos   $145.51M
--     sus facturas se liquidaron en otro mes          92 pagos   $  0.65M
--     mezcla de las dos                               14 pagos   $  0.11M
--     no liga a ninguna factura                       53 pagos   $  5.54M
--                                                              = $151.81M
--
-- LEER ESTO ANTES DE PRESENTARLO: la diferencia contra los $139.70M NO es
-- principalmente "pagos a facturas de otro mes" - eso son $0.76M. El grueso es que
-- $145.51M de pagos liquidaron facturas cuyo valor nominal suma menos: el puente liga
-- pago con factura pero NO reparte montos, asi que un pago puede traer mas o menos que
-- la suma de las facturas que salda (sobrepagos, coberturas parciales, saldos a cuenta).
-- Son dos formas de medir el mismo mes, no un descuadre.
--
-- Tarda ~1 minuto: cruza el puente completo. No es para correr en vivo frente a nadie.
-- =====================================================================================
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
