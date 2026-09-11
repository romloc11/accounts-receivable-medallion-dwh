/* =====================================================================================
   PRUEBA 5 - Agosto 2026, dia por dia
   =====================================================================================
   El presupuesto contra lo que entro, cada dia del mes, con el acumulado al lado.

   El acumulado es lo que sirve para operar: un dia suelto se mueve mucho, pero la
   linea acumulada dice si el mes va en curso o no. Comparar un martes contra su
   presupuesto no dice nada; comparar el acumulado del dia 20, si.

   Los primeros tres dias tienen presupuesto = real por construccion: son anteriores
   al corte, o sea dinero que ya estaba en el banco cuando se armo el numero.
   Los sabados y domingos tienen presupuesto 0 y a veces caja: es correcto, se
   presupuestan en cero porque historicamente reciben 0.2% del dinero.
   ===================================================================================== */

SELECT p.fecha,
       DATENAME(WEEKDAY, p.fecha)                                       AS dia,
       p.slot_calendario                                                AS posicion_en_el_mes,
       p.origen,
       p.monto_presupuesto                                              AS presupuesto,
       ISNULL(c.monto_real, 0)                                          AS entro,
       SUM(p.monto_presupuesto)      OVER (ORDER BY p.fecha)            AS presupuesto_acumulado,
       SUM(ISNULL(c.monto_real, 0))  OVER (ORDER BY p.fecha)            AS entro_acumulado
FROM   gold.fact_presupuesto_cobranza p
LEFT JOIN gold.vw_cobranza_diaria c ON c.fecha = p.fecha
WHERE  p.mes_presupuesto = '2026-08-01'
ORDER BY p.fecha;


-- =====================================================================================
-- EL CIERRE DEL MES, EN UNA LINEA
-- =====================================================================================
SELECT SUM(p.monto_presupuesto)                                         AS presupuesto,
       SUM(ISNULL(c.monto_real, 0))                                     AS entro,
       SUM(ISNULL(c.monto_real,0)) - SUM(p.monto_presupuesto)           AS diferencia,
       CAST(100.0 * (SUM(ISNULL(c.monto_real,0)) - SUM(p.monto_presupuesto))
            / SUM(p.monto_presupuesto) AS DECIMAL(6,1))                 AS diferencia_pct
FROM   gold.fact_presupuesto_cobranza p
LEFT JOIN gold.vw_cobranza_diaria c ON c.fecha = p.fecha
WHERE  p.mes_presupuesto = '2026-08-01';
