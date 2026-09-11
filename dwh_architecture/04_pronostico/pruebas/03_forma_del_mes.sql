/* =====================================================================================
   PRUEBA 3 - La forma del mes
   =====================================================================================
   Cuatro afirmaciones, cuatro consultas. Todas sobre la caja real de 2024-2025.

     A. el ultimo dia habil concentra ~11% del mes
     B. los ultimos ocho dias habiles suman ~47%
     C. dentro del mes, el lunes es el dia fuerte y el jueves el mas flojo
     D. sabados, domingos y festivos casi no reciben dinero

   El "share" de un dia es su caja dividida entre la caja habil de SU PROPIO mes, y
   despues se promedian esos shares. No se puede sumar dinero de meses distintos y
   dividir al final: un mes grande dominaria a uno chico.
   ===================================================================================== */


-- =====================================================================================
-- A y B -- el peso de cada dia habil, contado DESDE EL FINAL del mes
-- dia 1 = ultimo dia habil, dia 2 = penultimo, etc.
-- =====================================================================================
SELECT TOP 10
       d.dias_habiles_mes - d.dia_habil_del_mes + 1                      AS dia_desde_el_final,
       CAST(100.0 * AVG(dia.caja / mes.caja) AS DECIMAL(5,2))            AS pct_del_mes
FROM   gold.dim_fecha d
CROSS APPLY (SELECT SUM(p.monto) AS caja FROM gold.fact_pagos p
             WHERE p.fecha_documento = d.fecha) dia
CROSS APPLY (SELECT SUM(p.monto) AS caja FROM gold.fact_pagos p
             JOIN gold.dim_fecha d2 ON d2.fecha = p.fecha_documento AND d2.es_dia_habil = 1
             WHERE d2.anio = d.anio AND d2.mes = d.mes) mes
WHERE  d.fecha >= '2024-01-01' AND d.fecha < '2026-01-01'
AND    d.es_dia_habil = 1
GROUP BY d.dias_habiles_mes - d.dia_habil_del_mes + 1
ORDER BY dia_desde_el_final;


-- B en una sola cifra: los ultimos ocho dias habiles juntos
SELECT CAST(100.0 * AVG(CASE WHEN d.dias_habiles_mes - d.dia_habil_del_mes + 1 <= 8
                             THEN dia.caja / mes.caja ELSE 0 END) *
            COUNT(*) / COUNT(DISTINCT d.anio * 100 + d.mes) AS DECIMAL(5,1))  AS pct_ultimos_8_dias
FROM   gold.dim_fecha d
CROSS APPLY (SELECT SUM(p.monto) AS caja FROM gold.fact_pagos p
             WHERE p.fecha_documento = d.fecha) dia
CROSS APPLY (SELECT SUM(p.monto) AS caja FROM gold.fact_pagos p
             JOIN gold.dim_fecha d2 ON d2.fecha = p.fecha_documento AND d2.es_dia_habil = 1
             WHERE d2.anio = d.anio AND d2.mes = d.mes) mes
WHERE  d.fecha >= '2024-01-01' AND d.fecha < '2026-01-01'
AND    d.es_dia_habil = 1;


-- =====================================================================================
-- C -- el dia de la semana, SOLO en el tramo de en medio del mes
-- Se excluyen los 3 primeros y los 8 ultimos dias habiles: esos ya tienen su propio
-- efecto de calendario y contaminarian la comparacion.
-- =====================================================================================
SELECT DATENAME(WEEKDAY, d.fecha)                                  AS dia_semana,
       COUNT(*)                                                    AS dias_medidos,
       CAST(100.0 * AVG(dia.caja / mes.caja) AS DECIMAL(5,2))      AS pct_del_mes
FROM   gold.dim_fecha d
CROSS APPLY (SELECT SUM(p.monto) AS caja FROM gold.fact_pagos p
             WHERE p.fecha_documento = d.fecha) dia
CROSS APPLY (SELECT SUM(p.monto) AS caja FROM gold.fact_pagos p
             JOIN gold.dim_fecha d2 ON d2.fecha = p.fecha_documento AND d2.es_dia_habil = 1
             WHERE d2.anio = d.anio AND d2.mes = d.mes) mes
WHERE  d.fecha >= '2024-01-01' AND d.fecha < '2026-01-01'
AND    d.es_dia_habil = 1
AND    d.dia_habil_del_mes > 3                                  -- ni los primeros
AND    d.dias_habiles_mes - d.dia_habil_del_mes + 1 > 8         -- ni los ultimos
GROUP BY DATENAME(WEEKDAY, d.fecha), DATEPART(WEEKDAY, d.fecha)
ORDER BY DATEPART(WEEKDAY, d.fecha);


-- =====================================================================================
-- D -- cuanto dinero cae en dia inhabil
-- =====================================================================================
SELECT CASE WHEN d.es_dia_habil = 1 THEN 'Dia habil'
            WHEN d.es_festivo   = 1 THEN 'Festivo'
            ELSE                         'Sabado o domingo' END        AS tipo_de_dia,
       COUNT(*)                                                        AS dias,
       SUM(ISNULL(dia.caja, 0))                                        AS caja,
       CAST(100.0 * SUM(ISNULL(dia.caja,0)) / SUM(SUM(ISNULL(dia.caja,0))) OVER ()
            AS DECIMAL(5,2))                                           AS pct
FROM   gold.dim_fecha d
OUTER APPLY (SELECT SUM(p.monto) AS caja FROM gold.fact_pagos p
             WHERE p.fecha_documento = d.fecha) dia
WHERE  d.fecha >= '2024-01-01' AND d.fecha < '2026-01-01'
GROUP BY CASE WHEN d.es_dia_habil = 1 THEN 'Dia habil'
              WHEN d.es_festivo   = 1 THEN 'Festivo'
              ELSE                         'Sabado o domingo' END
ORDER BY caja DESC;
