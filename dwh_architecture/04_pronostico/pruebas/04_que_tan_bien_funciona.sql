/* =====================================================================================
   PRUEBA 4 - Que tan bien le atina
   =====================================================================================
   Mes por mes: lo que se presupuesto contra lo que de verdad entro.

   El presupuesto sale de gold.fact_presupuesto_cobranza, que se congela el dia del
   corte y no se vuelve a tocar. Lo real sale de gold.vw_cobranza_diaria, que se
   calcula al vuelo. Son dos tablas distintas a proposito: si el pronostico se
   recalculara cada noche, perseguiria a la realidad y siempre "acertaria".

   Cada mes se pronostico usando SOLO datos anteriores a el.
   ===================================================================================== */


-- =====================================================================================
-- MES POR MES
-- =====================================================================================
SELECT p.mes_presupuesto                                                     AS mes,
       p.fecha_corte                                                         AS se_calculo_el,
       SUM(p.monto_presupuesto)                                              AS presupuesto,
       SUM(c.monto_real)                                                     AS entro_de_verdad,
       CAST(100.0 * (SUM(c.monto_real) - SUM(p.monto_presupuesto))
            / SUM(p.monto_presupuesto) AS DECIMAL(6,1))                      AS diferencia_pct
FROM   gold.fact_presupuesto_cobranza p
LEFT JOIN gold.vw_cobranza_diaria c ON c.fecha = p.fecha
WHERE  p.mes_presupuesto < '2026-09-01'          -- septiembre sigue abierto
GROUP BY p.mes_presupuesto, p.fecha_corte
ORDER BY p.mes_presupuesto;


-- =====================================================================================
-- EL RESUMEN
-- El error ABSOLUTO medio es el que importa: promediar errores con signo dejaria que
-- un mes corto cancele a uno largo y el resultado se veria mejor de lo que es.
-- =====================================================================================
SELECT COUNT(*)                                        AS meses_evaluados,
       CAST(AVG(ABS(dif)) AS DECIMAL(6,2))             AS error_absoluto_medio_pct,
       CAST(AVG(dif)      AS DECIMAL(6,2))             AS sesgo_pct,
       CAST(MIN(dif)      AS DECIMAL(6,2))             AS peor_mes_abajo,
       CAST(MAX(dif)      AS DECIMAL(6,2))             AS peor_mes_arriba
FROM (
    SELECT 100.0 * (SUM(c.monto_real) - SUM(p.monto_presupuesto))
           / SUM(p.monto_presupuesto) AS dif
    FROM   gold.fact_presupuesto_cobranza p
    LEFT JOIN gold.vw_cobranza_diaria c ON c.fecha = p.fecha
    WHERE  p.mes_presupuesto < '2026-09-01'
    GROUP BY p.mes_presupuesto
) z;
