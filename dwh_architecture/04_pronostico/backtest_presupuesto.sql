USE ANALISIS_DATOS;
GO

/*
========================================================================================
BACKTEST DE LA LINEA BASE DEL PRESUPUESTO DE COBRANZA          (2026-09-08)
========================================================================================
SOLO LECTURA. No crea ni modifica nada en gold: temporales y SELECT.

--- QUE MIDE ---
Si se puede predecir cuando se va a cobrar cada factura, y con que error se traduce
eso en un presupuesto por dia, por semana y por mes.

Metodo: parametros estimados con los pagos de 2025, evaluados sobre los pagos de 2026.
FUERA DE MUESTRA - el modelo nunca ve 2026 al ajustarse.

--- LOS TRES PREDICTORES, COMPITIENDO POR CLIENTE ---
  VENCIMIENTO   fecha_vencimiento + mediana(dias_pago) del cliente
  FACTURA       fecha_documento   + mediana(dias desde factura) del cliente
  DIA FIJO      dia D del mes, con lag de meses desde la factura
Gana el de menor error historico DE ESE CLIENTE. No hay un predictor global.

RESULTADO (2026, fuera de muestra):
    VENCIMIENTO  3,126 clientes   79.1% del dinero   MAE 6.3 dias
    FACTURA        225 clientes   12.1%              MAE 7.1
    DIA FIJO       320 clientes    8.8%              MAE 9.8
    MAE global eligiendo el mejor: 6.69 dias
    contra 9.15 / 8.79 / 13.33 usando uno solo -> competir los tres baja el error 27%

--- EL ERROR QUE IMPORTA NO ES EL MAE POR FACTURA ---
Al sumar miles de facturas los errores se cancelan. Lo que decide es el error AGREGADO.
Metrica: WAPE = suma|error| / suma real. No MAPE: en grano diario hay dias con casi
cero (domingos, festivos) y el MAPE explota.

    grano    punto   + perfil desde inicio   + perfil MIXTO
    DIA      41.6%           22.2%              19.5%
    SEMANA   19.7%            9.9%               6.2%
    MES       1.8%            1.8%               1.8%

--- DOS HIPOTESIS: UNA FALLO Y UNA PEGO ---
FALLO: repartir el monto sobre la distribucion historica del cliente en vez de un
punto. Se defendio como necesaria y dio 41.3% contra 41.6% - practicamente nada.
Razon: suavizar no reduce el error absoluto contra una realidad que tambien tiene
picos, solo lo redistribuye.
PEGO: perfil de calendario sobre un nivel confiable. El error diario no venia de la
incertidumbre por cliente - venia de no saber la forma del mes.

--- EL PERFIL VA CON INDICE MIXTO ---
Los meses tienen de 19 a 23 dias habiles. Indexar todo desde el inicio unta el pico de
cierre sobre 4 indices distintos segun la duracion del mes (se veia como 6.70, 7.74,
9.38, 7.13, 10.72 - con el absurdo de que el dia 22 salia mas bajo que el 21).
Solucion: primeros 8 dias contados desde el INICIO, ultimos 8 desde el FINAL, el medio
plano. El pico cae en un solo casillero:

    F01 (ultimo dia habil)  11.23%   <- un solo dia carga el 11% del mes
    F02                      6.81%
    F03                      5.83%
    M (medio del mes)        4.48%
    I01 (primer dia)         4.16%
    I02 (el mas muerto)      3.03%

Ultimos 8 dias habiles = ~47.5% del dinero del mes. Primeros 8 = ~30%.
El ultimo dia habil vale 3.7 veces el segundo dia del mes.

--- LO QUE ESTE BACKTEST NO CUBRE ---
1. Mide el TIMING de facturas que ya sabemos que se pagaron. Un presupuesto real
   tambien tiene que acertar CUALES de las abiertas se pagan en el horizonte.
2. No incluye el componente C (18.4% del dinero): facturas que aun no existen.
   Ese va aparte, como facturacion_pronosticada x 15.6%.
3. Los meses de borde (enero y agosto 2026) se excluyen a proposito: la ventana los
   trunca. Verificado: el faltante de agosto era 20.7M y la fuga por arriba 20.8M.

--- COMO SE COMPARA CON EL METODO ACTUAL ---
El manual presupuesta solo el componente B - lo que vence en el mes - que son 60.7%
del dinero. Es ~39% corto POR CONSTRUCCION, sin importar que tan bien se afinen los
porcentajes por dia.
========================================================================================
*/

/* Igual que pred1 pero guardando la fecha PREDICHA, para medir el error AGREGADO */
IF OBJECT_ID('tempdb..#h') IS NOT NULL DROP TABLE #h;
SELECT cliente_id, monto, fecha_documento, fecha_vencimiento, fecha_pago_efectiva,
       DATEDIFF(DAY, fecha_vencimiento, fecha_pago_efectiva) AS d_venc,
       DATEDIFF(DAY, fecha_documento,   fecha_pago_efectiva) AS d_fact,
       DATEDIFF(MONTH, fecha_documento, fecha_pago_efectiva) AS lag_mes,
       DAY(fecha_pago_efectiva) AS dia_del_mes,
       CASE WHEN fecha_pago_efectiva < '2026-01-01' THEN 'ENTRENA' ELSE 'EVALUA' END AS parte
INTO #h FROM gold.fact_facturas
WHERE flag_compensada=1 AND fecha_vencimiento IS NOT NULL
  AND fecha_pago_efectiva >= '2025-01-01' AND fecha_pago_efectiva < '2026-09-01';

IF OBJECT_ID('tempdb..#par') IS NOT NULL DROP TABLE #par;
SELECT cliente_id, n_entrena, MAX(m_venc) AS off_venc, MAX(m_fact) AS off_fact,
       MAX(m_lag) AS lag_mes, MAX(m_dia) AS dia_fijo
INTO #par FROM (
  SELECT cliente_id, COUNT(*) OVER (PARTITION BY cliente_id) AS n_entrena,
   PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY d_venc)      OVER (PARTITION BY cliente_id) AS m_venc,
   PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY d_fact)      OVER (PARTITION BY cliente_id) AS m_fact,
   PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY lag_mes)     OVER (PARTITION BY cliente_id) AS m_lag,
   PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY dia_del_mes) OVER (PARTITION BY cliente_id) AS m_dia
  FROM #h WHERE parte='ENTRENA') z GROUP BY cliente_id, n_entrena;

-- ganador por cliente, decidido con 2025
IF OBJECT_ID('tempdb..#g') IS NOT NULL DROP TABLE #g;
SELECT p.cliente_id, p.off_venc, p.off_fact, p.lag_mes, p.dia_fijo,
       CASE WHEN a.mae1<=a.mae2 AND a.mae1<=a.mae3 THEN 'VENCIMIENTO'
            WHEN a.mae2<=a.mae3 THEN 'FACTURA' ELSE 'DIA_FIJO' END AS predictor
INTO #g FROM #par p JOIN (
  SELECT h.cliente_id,
    AVG(ABS(DATEDIFF(DAY, DATEADD(DAY,CAST(p.off_venc AS INT),h.fecha_vencimiento), h.fecha_pago_efectiva))*1.0) AS mae1,
    AVG(ABS(DATEDIFF(DAY, DATEADD(DAY,CAST(p.off_fact AS INT),h.fecha_documento),   h.fecha_pago_efectiva))*1.0) AS mae2,
    AVG(ABS(DATEDIFF(DAY, DATEADD(MONTH,CAST(p.lag_mes AS INT),h.fecha_documento),  h.fecha_pago_efectiva))*1.0) AS mae3
  FROM #h h JOIN #par p ON p.cliente_id=h.cliente_id
  WHERE h.parte='ENTRENA' GROUP BY h.cliente_id) a ON a.cliente_id=p.cliente_id
WHERE p.n_entrena >= 6;

-- prediccion sobre 2026
IF OBJECT_ID('tempdb..#pr') IS NOT NULL DROP TABLE #pr;
SELECT h.monto, h.fecha_pago_efectiva AS real_f,
       CASE g.predictor
         WHEN 'VENCIMIENTO' THEN DATEADD(DAY, CAST(g.off_venc AS INT), h.fecha_vencimiento)
         WHEN 'FACTURA'     THEN DATEADD(DAY, CAST(g.off_fact AS INT), h.fecha_documento)
         ELSE DATEFROMPARTS(
                YEAR (DATEADD(MONTH, CAST(g.lag_mes AS INT), h.fecha_documento)),
                MONTH(DATEADD(MONTH, CAST(g.lag_mes AS INT), h.fecha_documento)),
                CASE WHEN CAST(g.dia_fijo AS INT) > DAY(EOMONTH(DATEADD(MONTH,CAST(g.lag_mes AS INT),h.fecha_documento)))
                     THEN DAY(EOMONTH(DATEADD(MONTH,CAST(g.lag_mes AS INT),h.fecha_documento)))
                     ELSE CAST(g.dia_fijo AS INT) END) END AS pred_f
INTO #pr FROM #h h JOIN #g g ON g.cliente_id=h.cliente_id WHERE h.parte='EVALUA';

-- recorrer al siguiente dia habil (la regla del calendario)
IF OBJECT_ID('tempdb..#pr2') IS NOT NULL DROP TABLE #pr2;
SELECT p.monto, p.real_f, ISNULL(d.siguiente_dia_habil, p.pred_f) AS pred_f
INTO #pr2 FROM #pr p LEFT JOIN gold.dim_fecha d ON d.fecha = p.pred_f;



/* ===================================================================
   PERFIL CON INDICE MIXTO
   Los dos extremos del mes tienen anclas distintas:
     primeros 8 dias habiles  -> se cuentan desde el INICIO  (clave I1..I8)
     ultimos 8 dias habiles   -> se cuentan desde el FINAL   (clave F-1..F-8)
     el medio                 -> plano, una sola clave M
   Indexar todo desde el inicio unta el pico de cierre sobre 4 indices distintos
   segun si el mes tuvo 19 o 23 dias habiles.
   =================================================================== */
IF OBJECT_ID('tempdb..#cal') IS NOT NULL DROP TABLE #cal;
SELECT fecha, anio, mes,
       CASE WHEN dia_habil_del_mes <= 8
                 THEN 'I' + RIGHT('0'+CAST(dia_habil_del_mes AS VARCHAR(3)),2)
            WHEN dia_habil_del_mes - dias_habiles_mes - 1 >= -8
                 THEN 'F' + RIGHT('0'+CAST(ABS(dia_habil_del_mes - dias_habiles_mes - 1) AS VARCHAR(3)),2)
            ELSE 'M' END AS clave
INTO   #cal
FROM   gold.dim_fecha WHERE es_dia_habil = 1;

-- dinero real de entrenamiento por dia, recorrido a dia habil
IF OBJECT_ID('tempdb..#tr') IS NOT NULL DROP TABLE #tr;
SELECT ISNULL(d.siguiente_dia_habil, h.fecha_pago_efectiva) AS fecha, SUM(h.monto) AS monto
INTO   #tr FROM #h h LEFT JOIN gold.dim_fecha d ON d.fecha = h.fecha_pago_efectiva
WHERE  h.parte='ENTRENA'
GROUP BY ISNULL(d.siguiente_dia_habil, h.fecha_pago_efectiva);

-- PERFIL A: indice desde el inicio (el que ya medimos)
IF OBJECT_ID('tempdb..#pA') IS NOT NULL DROP TABLE #pA;
SELECT f.dia_habil_del_mes AS k, AVG(1.0*t.monto/m.tot) AS share
INTO #pA FROM #tr t JOIN gold.dim_fecha f ON f.fecha=t.fecha
JOIN (SELECT f2.anio,f2.mes,SUM(t2.monto) tot FROM #tr t2 JOIN gold.dim_fecha f2 ON f2.fecha=t2.fecha
      GROUP BY f2.anio,f2.mes) m ON m.anio=f.anio AND m.mes=f.mes
WHERE f.dia_habil_del_mes IS NOT NULL GROUP BY f.dia_habil_del_mes;

-- PERFIL B: indice mixto
IF OBJECT_ID('tempdb..#pB') IS NOT NULL DROP TABLE #pB;
SELECT c.clave AS k, AVG(1.0*t.monto/m.tot) AS share
INTO #pB FROM #tr t JOIN #cal c ON c.fecha=t.fecha
JOIN (SELECT c2.anio,c2.mes,SUM(t2.monto) tot FROM #tr t2 JOIN #cal c2 ON c2.fecha=t2.fecha
      GROUP BY c2.anio,c2.mes) m ON m.anio=c.anio AND m.mes=c.mes
GROUP BY c.clave;

IF OBJECT_ID('tempdb..#mes') IS NOT NULL DROP TABLE #mes;
SELECT YEAR(pred_f) anio, MONTH(pred_f) mes, SUM(monto) total INTO #mes FROM #pr2 GROUP BY YEAR(pred_f), MONTH(pred_f);

-- aplicar A
IF OBJECT_ID('tempdb..#hA') IS NOT NULL DROP TABLE #hA;
SELECT f.fecha, m.total*p.share/s.suma AS monto INTO #hA
FROM gold.dim_fecha f JOIN #mes m ON m.anio=f.anio AND m.mes=f.mes
JOIN #pA p ON p.k=f.dia_habil_del_mes
JOIN (SELECT f3.anio,f3.mes,SUM(p3.share) suma FROM gold.dim_fecha f3 JOIN #pA p3 ON p3.k=f3.dia_habil_del_mes
      GROUP BY f3.anio,f3.mes) s ON s.anio=f.anio AND s.mes=f.mes
WHERE f.es_dia_habil=1;

-- aplicar B
IF OBJECT_ID('tempdb..#hB') IS NOT NULL DROP TABLE #hB;
SELECT c.fecha, m.total*p.share/s.suma AS monto INTO #hB
FROM #cal c JOIN #mes m ON m.anio=c.anio AND m.mes=c.mes
JOIN #pB p ON p.k=c.clave
JOIN (SELECT c3.anio,c3.mes,SUM(p3.share) suma FROM #cal c3 JOIN #pB p3 ON p3.k=c3.clave
      GROUP BY c3.anio,c3.mes) s ON s.anio=c.anio AND s.mes=c.mes;

IF OBJECT_ID('tempdb..#cmp') IS NOT NULL DROP TABLE #cmp;
SELECT f.fecha, ISNULL(r.m,0) real_m, ISNULL(pt.m,0) punto_m, ISNULL(a.monto,0) hA_m, ISNULL(b.monto,0) hB_m
INTO #cmp FROM gold.dim_fecha f
LEFT JOIN (SELECT real_f d,SUM(monto) m FROM #pr2 GROUP BY real_f) r ON r.d=f.fecha
LEFT JOIN (SELECT pred_f d,SUM(monto) m FROM #pr2 GROUP BY pred_f) pt ON pt.d=f.fecha
LEFT JOIN #hA a ON a.fecha=f.fecha LEFT JOIN #hB b ON b.fecha=f.fecha
WHERE f.fecha>='2026-02-01' AND f.fecha<'2026-08-01';

SELECT 'DIA' grano,
  CAST(SUM(ABS(punto_m-real_m))/SUM(real_m)*100 AS DECIMAL(6,1)) AS punto,
  CAST(SUM(ABS(hA_m-real_m))/SUM(real_m)*100 AS DECIMAL(6,1))    AS perfil_inicio,
  CAST(SUM(ABS(hB_m-real_m))/SUM(real_m)*100 AS DECIMAL(6,1))    AS perfil_mixto
FROM #cmp
UNION ALL
SELECT 'SEMANA',
  CAST(SUM(ABS(punto_m-real_m))/SUM(real_m)*100 AS DECIMAL(6,1)),
  CAST(SUM(ABS(hA_m-real_m))/SUM(real_m)*100 AS DECIMAL(6,1)),
  CAST(SUM(ABS(hB_m-real_m))/SUM(real_m)*100 AS DECIMAL(6,1))
FROM (SELECT DATEDIFF(WEEK,'2026-02-01',fecha) w,SUM(real_m) real_m,SUM(punto_m) punto_m,SUM(hA_m) hA_m,SUM(hB_m) hB_m
      FROM #cmp GROUP BY DATEDIFF(WEEK,'2026-02-01',fecha)) z;

SELECT k AS clave, CAST(100.0*share AS DECIMAL(5,2)) AS pct_del_mes FROM #pB ORDER BY k;
GO
