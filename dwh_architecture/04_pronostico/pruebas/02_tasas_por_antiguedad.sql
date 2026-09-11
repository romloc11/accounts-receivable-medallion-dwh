/* =====================================================================================
   PRUEBA 2 - Que fraccion de la cartera entra, segun su antiguedad
   =====================================================================================
   Para cada mes se toma la foto de la cartera abierta al 4o dia habil, se clasifica
   cada factura por su edad ese dia, y se mide cuanta de esa plata entro antes de que
   terminara el mes.

   Se calcula sobre TRES ventanas de historia -24, 12 y 6 meses- a proposito: si las
   tres dan casi lo mismo, la tasa es una propiedad del negocio y no del periodo que
   se escogio. Esa es la prueba de que el modelo no esta ajustado a modo.
   ===================================================================================== */

DECLARE @hoy DATE = '2026-09-01';   -- se mide con historia ANTERIOR a este mes

/* Un renglon por factura abierta al corte de cada mes, con su edad y si entro o no */
IF OBJECT_ID('tempdb..#cartera') IS NOT NULL DROP TABLE #cartera;
SELECT m.ini AS mes,
       f.monto,
       CASE WHEN f.fecha_pago_efectiva BETWEEN m.corte AND m.fin THEN f.monto ELSE 0 END AS entro,
       CASE
         WHEN f.fecha_vencimiento >  m.fin                              THEN 'Vence en meses posteriores'
         WHEN f.fecha_vencimiento >= m.corte                            THEN 'Vence este mes'
         WHEN DATEDIFF(DAY, f.fecha_vencimiento, m.corte) <=  30        THEN 'Vencida 1-30 dias'
         WHEN DATEDIFF(DAY, f.fecha_vencimiento, m.corte) <=  60        THEN 'Vencida 31-60 dias'
         WHEN DATEDIFF(DAY, f.fecha_vencimiento, m.corte) <=  90        THEN 'Vencida 61-90 dias'
         WHEN DATEDIFF(DAY, f.fecha_vencimiento, m.corte) <= 180        THEN 'Vencida 91-180 dias'
         WHEN DATEDIFF(DAY, f.fecha_vencimiento, m.corte) <= 365        THEN 'Vencida 181-365 dias'
         ELSE                                                                'Vencida mas de 365 dias'
       END AS bucket
INTO   #cartera
FROM  (SELECT DATEFROMPARTS(anio, mes, 1) AS ini,
              EOMONTH(DATEFROMPARTS(anio, mes, 1)) AS fin,
              MIN(CASE WHEN dia_habil_del_mes = 4 THEN fecha END) AS corte
       FROM   gold.dim_fecha
       WHERE  fecha >= DATEADD(MONTH, -24, @hoy) AND fecha < @hoy
       GROUP BY anio, mes) m
JOIN   gold.fact_facturas f
       ON  f.fecha_documento < m.ini                                    -- ya existia
       AND (f.fecha_compensacion IS NULL OR f.fecha_compensacion >= m.corte)  -- seguia abierta
       AND  f.fecha_vencimiento IS NOT NULL
JOIN   gold.dim_cliente_comercial d
       ON  d.cliente_id = f.cliente_id
       AND m.corte BETWEEN d.fecha_inicio_vigencia
                       AND ISNULL(d.fecha_fin_vigencia, '9999-12-31')   -- version vigente al corte
       AND d.canal_distribucion IN (10, 40, 60)
       AND d.estatus_comercial <> 'FUERA_DE_ALCANCE';


-- =====================================================================================
-- LA TABLA -- la misma tasa medida sobre tres ventanas de historia
-- Si las tres columnas se parecen, la tasa es estable.
-- =====================================================================================
SELECT bucket,
       CAST(100.0 * SUM(CASE WHEN mes >= DATEADD(MONTH,-24,@hoy) THEN entro END)
                  / SUM(CASE WHEN mes >= DATEADD(MONTH,-24,@hoy) THEN monto END) AS DECIMAL(5,1)) AS pct_24_meses,
       CAST(100.0 * SUM(CASE WHEN mes >= DATEADD(MONTH,-12,@hoy) THEN entro END)
                  / SUM(CASE WHEN mes >= DATEADD(MONTH,-12,@hoy) THEN monto END) AS DECIMAL(5,1)) AS pct_12_meses,
       CAST(100.0 * SUM(CASE WHEN mes >= DATEADD(MONTH, -6,@hoy) THEN entro END)
                  / SUM(CASE WHEN mes >= DATEADD(MONTH, -6,@hoy) THEN monto END) AS DECIMAL(5,1)) AS pct_6_meses,
       SUM(monto) / 24                                                                            AS cartera_promedio_mes
FROM   #cartera
GROUP BY bucket
ORDER BY MIN(CASE bucket
               WHEN 'Vence en meses posteriores' THEN 1
               WHEN 'Vence este mes'             THEN 2
               WHEN 'Vencida 1-30 dias'          THEN 3
               WHEN 'Vencida 31-60 dias'         THEN 4
               WHEN 'Vencida 61-90 dias'         THEN 5
               WHEN 'Vencida 91-180 dias'        THEN 6
               WHEN 'Vencida 181-365 dias'       THEN 7
               ELSE 8 END);
