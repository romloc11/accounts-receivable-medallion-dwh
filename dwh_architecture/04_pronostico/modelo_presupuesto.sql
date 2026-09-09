/* =====================================================================================
   MODELO DE PRESUPUESTO DE COBRANZA  -  v2, por ANTIGUEDAD
   dwh_architecture/04_pronostico/modelo_presupuesto.sql            (2026-09-09)
   =====================================================================================

   POR QUE SE TIRO EL MODELO ANTERIOR
   ----------------------------------
   La v1 predecia, factura por factura, la FECHA en que cada cliente iba a pagar
   (mediana historica del cliente sobre vencimiento, sobre fecha de factura, o lag en
   meses) y sumaba lo que caia dentro del mes. Media 1.8% de error a nivel mes y por
   eso parecia buena. NO LO ERA: ese 1.8% se midio sobre facturas que YA SE SABIA que
   se habian pagado - media el TIMING, no el pronostico. Puesta a predecir de verdad,
   con corte al 4o dia habil y parametros de 2025 aplicados a 2026, dio -65.8%.

   El motivo es estructural, no de calibracion. El predictor dice "vencimiento + N
   dias". Si esa fecha YA PASO y la factura sigue abierta, el modelo no tiene nada que
   decir y la descarta. En agosto 2026 eso era $33.1M. Sumado al papel viejo de
   clientes sin historial ($15.8M), ~$49M de un hueco de $64M eran facturas vencidas
   sobre las que el modelo callaba. No tenia teoria para la cartera vencida.

   Tambien arrastraba un problema de arranque en frio: ~12% de la cartera abierta es de
   clientes que NUNCA han pagado una factura en 2022-2025, asi que no habia mediana que
   calcular. Se intento con mas historia, con umbral mas bajo y con respaldo por
   segmento (canal x tipo_cliente): el error solo bajo de 65.8% a 60.9%.

   LA IDEA DE ESTA VERSION
   ----------------------
   Cambiar la pregunta. No "cuando paga esta factura" - que exige conocer al cliente -
   sino "de este monton de dinero con esta antiguedad, que fraccion entra este mes".
   Es una pregunta de masa, no de fecha, y se contesta con el comportamiento agregado
   de la cartera. Como consecuencia el arranque en frio DESAPARECE: toda factura cae en
   algun bucket, tenga o no historial su cliente.

   EL PRESUPUESTO, EN TRES TERMINOS
   --------------------------------
     T1  cartera parada al corte x tasa de recuperacion de su bucket
     T2  cobrado del dia 1 al corte  ->  NO SE PREDICE, SE OBSERVA. Ese dinero ya esta
         en el banco el dia que se arma el presupuesto; adivinarlo seria absurdo.
     T3  facturado-y-cobrado dentro del mes (componente C) mas pagos no ligados a
         factura, como factor sobre T1.

   TASAS DE RECUPERACION MEDIDAS (2024-2025, corte al 4o dia habil)
   ---------------------------------------------------------------
     bucket                    cartera/mes   entra en el mes
     A1  vence este mes          $107.9M         71.1%
     A2  vence despues            $83.5M         14.6%   <- pago anticipado
     B   vencida    1-30 d        $27.1M         66.2%
     C   vencida   31-60 d         $2.3M         31.0%
     D   vencida   61-90 d         $0.9M         19.6%
     E   vencida  91-180 d         $0.9M          9.1%
     F   vencida 181-365 d         $0.6M          1.1%
     G   vencida    +365 d        $16.5M          0.0%   <- papel muerto

   Partir "por vencer" en A1/A2 no es cosmetico: juntos daban 46.5%, un promedio que no
   describe a ninguna de las dos poblaciones. Lo que vence en el mes entra al 71%; lo
   que vence despues, al 15%.

   G MERECE ATENCION APARTE: $16.5M de cartera que recupera CERO, tres anios seguidos
   (0.0% / 0.0% / 0.1%). El metodo manual lo cuenta completo porque su regla es
   "fecha_vencimiento <= fin de mes" y toda factura vieja la cumple. Es dinero que el
   presupuesto promete y la caja nunca ve.

   RESULTADO, FUERA DE MUESTRA
   ---------------------------
   Parametros de 2024-2025, evaluado mes a mes en ene-ago 2026:

       metodo manual actual .......  23.4% de error absoluto medio  (sesgo -23.4%)
       modelo v1 (por fecha) ......  65.8%
       modelo v2 (antiguedad) .....   3.53%                          (sesgo +2.15%)

   DOS PRUEBAS DE ROBUSTEZ, AMBAS PASAN
   ------------------------------------
   1. Deriva de tasas. Los buckets que cargan el dinero casi no se mueven:
      A1  71.5 / 70.7 / 72.2   B  65.2 / 67.1 / 69.8   (2024 / 2025 / 2026 real)
      Los que si se mueven (C-F) suman menos de $5M, asi que su deriva no importa.
   2. Ventana de calibracion. Entrenando con 2024, con 2025 o con ambos, el error en
      2026 da 3.53 / 3.51 / 3.53. Que no dependa de la ventana es lo que separa un
      resultado real de un sobreajuste.

   LO QUE ESTE MODELO TODAVIA NO ES
   --------------------------------
   T3 es un FACTOR, no un mecanismo: ~37% de T1. Funciona porque el componente C escala
   con el tamano de la cartera, pero es una correlacion. El dia que cambie la mezcla de
   canales o el plazo de credito, T3 miente y nada avisa. Su reemplazo correcto es un
   pronostico de facturacion del mes; queda pendiente.

   Una limitacion menor y sin arreglo: la cartera historica se reconstruye desde el
   estado de HOY (fecha_compensacion NULL o >= corte). Una factura que existia al corte
   y despues se cancelo en SAP ya no aparece, asi que la foto de meses viejos queda
   marginalmente corta. Afecta igual al entrenamiento y a la evaluacion.

   PARA CORRERLO SOBRE UN MES REAL: ver el bloque PRONOSTICO al final.
   ===================================================================================== */

SET NOCOUNT ON;

/* ------------------------------------------------------------------ 1. CALENDARIO
   El corte es el 4o dia habil, que es cuando Cobranza saca el numero - no el dia 1.
   No es un detalle: para septiembre 2026 la cartera abierta pasa de $140.5M el dia 1
   a $118.6M el dia 8. El presupuesto es un numero Y UNA FECHA. */
IF OBJECT_ID('tempdb..#mes') IS NOT NULL DROP TABLE #mes;
SELECT DATEFROMPARTS(anio, mes, 1)              AS ini,
       EOMONTH(DATEFROMPARTS(anio, mes, 1))     AS fin,
       MIN(CASE WHEN dia_habil_del_mes = 4 THEN fecha END) AS corte,
       CASE WHEN anio < 2026 THEN 'TRAIN' ELSE 'TEST' END  AS uso
INTO   #mes
FROM   gold.dim_fecha
WHERE  fecha >= '2024-01-01' AND fecha < '2026-09-01'
GROUP BY anio, mes;

/* ------------------------------------------------- 2. CARTERA PARADA AL CORTE
   fecha_documento < ini                 -> la factura ya existia cuando arranco el mes
   fecha_compensacion NULL o >= corte    -> seguia abierta el dia del calculo
   canal 10/40/60 resuelto A LA FECHA DEL CORTE (SCD2), no con la vigencia de hoy. */
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
       -- Solo se usa para ESTIMAR tasas sobre TRAIN. Nunca entra al pronostico.
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

/* ------------------------------------------------------- 3. TASAS (SOLO TRAIN)
   Ponderadas por monto, no promedio de porcentajes mensuales: lo que se predice es
   dinero, y un mes chico no debe pesar igual que uno grande. */
IF OBJECT_ID('tempdb..#tasa') IS NOT NULL DROP TABLE #tasa;
SELECT bucket, SUM(cobrado) / NULLIF(SUM(monto), 0) AS tasa
INTO   #tasa
FROM   #cartera
WHERE  uso = 'TRAIN'
GROUP BY bucket;

/* --------------------------------------------------------------- 4. T1 y T2 */
IF OBJECT_ID('tempdb..#term') IS NOT NULL DROP TABLE #term;
SELECT m.ini, m.uso, t1.v AS t1, t2.v AS t2, caja.v AS real_caja
INTO   #term
FROM   #mes m
CROSS APPLY (SELECT SUM(c.monto * t.tasa) AS v
             FROM #cartera c JOIN #tasa t ON t.bucket = c.bucket
             WHERE c.ini = m.ini) t1
-- T2: cobrado del dia 1 al corte. Observado, no predicho.
CROSS APPLY (SELECT SUM(g.monto) AS v FROM gold.fact_pagos g
             WHERE g.fecha_documento >= m.ini AND g.fecha_documento < m.corte) t2
CROSS APPLY (SELECT SUM(g.monto) AS v FROM gold.fact_pagos g
             WHERE g.fecha_documento >= m.ini AND g.fecha_documento <= m.fin) caja;

/* ------------------------------- 5. T3: factor de componente C + no ligados */
DECLARE @k DECIMAL(10,6) =
    (SELECT SUM(real_caja - t1 - t2) / SUM(t1) FROM #term WHERE uso = 'TRAIN');

/* ------------------------------------------------------------- 6. BACKTEST */
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

/* =====================================================================================
   PRONOSTICO DE UN MES REAL
   -------------------------------------------------------------------------------------
   Para presupuestar un mes en curso, correr los pasos 1-5 con la ventana de
   entrenamiento que se quiera (dos anios cerrados basta) y despues:

     DECLARE @ini DATE = '2026-10-01', @corte DATE = <4o dia habil>, @fin DATE = EOMONTH(@ini);

     T1 = SUM(cartera abierta al @corte  x  tasa del bucket)
     T2 = SUM(gold.fact_pagos WHERE fecha_documento >= @ini AND < @corte)
     T3 = T1 * @k
     presupuesto = T1 + T2 + T3

   Y ADEMAS, porque el numero solo no sirve para operar:
     - la parte de T1 que vive en el bucket G, que se sabe de antemano que no entra
     - el desglose por bucket, para que Cobranza vea DONDE esta el dinero prometido
     - el perfil de calendario (F01 = ultimo dia habil, 11.23%; los ultimos 8 dias
       habiles concentran ~47.5% del mes) para repartir el total dia por dia
   ===================================================================================== */
