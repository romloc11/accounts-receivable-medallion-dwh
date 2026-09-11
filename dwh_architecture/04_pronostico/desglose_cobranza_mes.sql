/* =====================================================================================
   DESGLOSE DE LA COBRANZA DE UN MES
   dwh_architecture/04_pronostico/desglose_cobranza_mes.sql          (2026-09-09)
   =====================================================================================

   De que esta hecho el dinero que entro en un mes. Es el espejo del presupuesto:
   modelo_presupuesto.sql predice estas mismas rebanadas hacia adelante, esta consulta
   mide lo que de verdad paso. Cambiar @ini y ya.

   TRES NUMEROS DISTINTOS, LOS TRES CORRECTOS
   ------------------------------------------
   Julio 2026 da 151.81, 153.36 o 149.24 millones segun que fecha se use:

       fecha_documento        151.81   cuando el cliente pago
       fecha_contabilizacion  153.36   cuando contabilidad lo capturo
       fecha_compensacion     149.24   cuando se aplico contra las facturas

   Los "149 millones" que se citan en las juntas son por fecha_compensacion. Esta
   consulta usa fecha_documento, porque la pregunta es de COMPORTAMIENTO DE PAGO y ahi
   la fecha buena es la del cliente, no la del proceso interno. El bloque de
   conciliacion imprime los tres para que nadie se quede con la duda.

   OJO CON EL NOMBRE 'PAGO_A_VENCIMIENTO'
   --------------------------------------
   La etiqueta que ya existe en gold.fact_facturas.clasificacion_cobranza SUENA a "pago
   a tiempo" y significa lo contrario: la factura YA ESTABA VENCIDA antes del mes en que
   se pago. Es cartera vencida. Aqui se re-etiqueta a un texto que no se pueda leer al
   reves. La columna original no se toca - solo se traduce para presentar.

   EL COMPONENTE C ES UN CORTE TRANSVERSAL, NO UNA CUARTA REBANADA
   ---------------------------------------------------------------
   "Facturado y cobrado en el mismo mes" no es una categoria paralela a las otras tres:
   una factura emitida en julio y pagada en julio ES, ademas, anticipada o del mes.
   Medido en julio: $22.49M de ese dinero es PAGO_ANTICIPADO y $4.26M es PAGO_A_MES.
   Presentarlo como cuarta rebanada SIN sacarlo de las otras dos duplica $26.75M.
   Esta consulta lo saca, asi que las cuatro rebanadas suman exacto.

   POR QUE SE MIDE POR FACTURA Y NO POR PAGO
   -----------------------------------------
   Un deposito puede liquidar tres facturas a la vez -una del mes, una vencida y un
   anticipo- y no hay forma confiable de decir que parte del deposito fue a cual.
   Repartirlo seria inventar. Contando FACTURAS LIQUIDADAS cada monto tiene una sola
   categoria y no hay reparto que suponer.
   El costo es que no cuadra exacto contra la caja, y por eso abajo va la conciliacion
   completa en vez de esconder la diferencia.
   ===================================================================================== */

DECLARE @ini DATE = '2026-07-01';
DECLARE @fin DATE = EOMONTH(@ini);

/* ------------------------------------------------ facturas liquidadas en el mes */
IF OBJECT_ID('tempdb..#f') IS NOT NULL DROP TABLE #f;
SELECT f.monto,
       CASE
         /* Emitida Y liquidada dentro del mes: se saca de las otras dos, ver cabecera */
         WHEN f.fecha_documento >= @ini                THEN 2
         WHEN f.clasificacion_cobranza = 'PAGO_A_MES'  THEN 1
         WHEN f.clasificacion_cobranza = 'PAGO_ANTICIPADO' THEN 3
         ELSE 4   -- PAGO_A_VENCIMIENTO = ya estaba vencida. Ver cabecera.
       END AS orden
INTO   #f
FROM   gold.fact_facturas f
WHERE  f.fecha_pago_efectiva >= @ini AND f.fecha_pago_efectiva <= @fin;

DECLARE @fact DECIMAL(19,2) = (SELECT SUM(monto) FROM #f);

/* ------------------------------------------------------------- caja del mes */
DECLARE @caja_doc DECIMAL(19,2) = (SELECT ISNULL(SUM(monto),0) FROM gold.fact_pagos
    WHERE fecha_documento      >= @ini AND fecha_documento      <= @fin);
DECLARE @caja_cnt DECIMAL(19,2) = (SELECT ISNULL(SUM(monto),0) FROM gold.fact_pagos
    WHERE fecha_contabilizacion>= @ini AND fecha_contabilizacion<= @fin);
DECLARE @caja_cmp DECIMAL(19,2) = (SELECT ISNULL(SUM(monto),0) FROM gold.fact_pagos
    WHERE fecha_compensacion   >= @ini AND fecha_compensacion   <= @fin);

/* Pagos del mes que NO liquidan ninguna factura. No son errores: LIQUIDA_NO_FACTURA
   es dinero que salda algo que no es factura (nota, anticipo a cuenta). Se muestra
   con su motivo en vez de esconderlo en un "otros". */
DECLARE @nolig DECIMAL(19,2) = (SELECT ISNULL(SUM(p.monto),0)
    FROM gold.fact_pagos_sin_aplicacion s
    JOIN gold.fact_pagos p ON p.sociedad=s.sociedad AND p.cliente_id=s.cliente_id
         AND p.ejercicio=s.ejercicio AND p.documento_id=s.documento_id AND p.posicion=s.posicion
    WHERE p.fecha_documento >= @ini AND p.fecha_documento <= @fin);

/* ===================================================================================
   RESULTADO
   Las cuatro rebanadas suman 100% de las facturas liquidadas. Abajo, la conciliacion
   contra la caja real.
   =================================================================================== */
SELECT orden, concepto,
       CAST(monto/1000000.0 AS DECIMAL(12,2)) AS monto_mm,
       CASE WHEN pct IS NULL THEN NULL
            ELSE CAST(pct AS DECIMAL(5,1)) END  AS pct
FROM (
    SELECT 1 AS orden, 'Cartera del mes (vencia en el mes, facturada antes)' AS concepto,
           SUM(CASE WHEN orden=1 THEN monto ELSE 0 END) AS monto,
           100.0*SUM(CASE WHEN orden=1 THEN monto ELSE 0 END)/NULLIF(@fact,0) AS pct FROM #f
    UNION ALL
    SELECT 2, 'Facturado y cobrado dentro del mes',
           SUM(CASE WHEN orden=2 THEN monto ELSE 0 END),
           100.0*SUM(CASE WHEN orden=2 THEN monto ELSE 0 END)/NULLIF(@fact,0) FROM #f
    UNION ALL
    SELECT 3, 'Anticipado (vencia en meses posteriores)',
           SUM(CASE WHEN orden=3 THEN monto ELSE 0 END),
           100.0*SUM(CASE WHEN orden=3 THEN monto ELSE 0 END)/NULLIF(@fact,0) FROM #f
    UNION ALL
    SELECT 4, 'Cartera vencida (vencio en meses anteriores)',
           SUM(CASE WHEN orden=4 THEN monto ELSE 0 END),
           100.0*SUM(CASE WHEN orden=4 THEN monto ELSE 0 END)/NULLIF(@fact,0) FROM #f
    UNION ALL
    SELECT 5, '= FACTURAS LIQUIDADAS EN EL MES', @fact, 100.0
    UNION ALL
    SELECT 6, '+ Pagos que no liquidan factura', @nolig, NULL
    UNION ALL
    /* RESIDUO, y hay que nombrarlo bien. Medido en julio 2026 por el lado del pago
       (ver demostrar_desglose.sql, consulta 6), solo $0.76M de esto son pagos aplicados
       a facturas que se liquidaron en otro mes. El resto -unos $5.8M- es otra cosa:
       la diferencia entre lo que trajo el pago y el VALOR NOMINAL de las facturas que
       liquido. El puente liga pagos con facturas pero a proposito NO reparte montos,
       asi que un pago puede traer mas o menos que la suma de sus facturas: sobrepagos,
       coberturas parciales, saldos a cuenta.
       Llamarlo "pagos a facturas de otro mes" seria describir mal el 88% del renglon. */
    SELECT 7, '+ Diferencia caja vs valor de factura (ver nota)',
           @caja_doc - @fact - @nolig, NULL
    UNION ALL
    SELECT 8, '= CAJA DEL MES (fecha de pago del cliente)', @caja_doc, NULL
    UNION ALL
    SELECT 9, '   [ref] misma caja por fecha de compensacion', @caja_cmp, NULL
    UNION ALL
    SELECT 10,'   [ref] misma caja por fecha de contabilizacion', @caja_cnt, NULL
) z
ORDER BY orden;

/* --------------------------------------------- detalle de lo que no liga a factura */
SELECT s.motivo,
       COUNT(*) AS n_pagos,
       CAST(SUM(p.monto)/1000000.0 AS DECIMAL(12,2)) AS monto_mm
FROM   gold.fact_pagos_sin_aplicacion s
JOIN   gold.fact_pagos p ON p.sociedad=s.sociedad AND p.cliente_id=s.cliente_id
       AND p.ejercicio=s.ejercicio AND p.documento_id=s.documento_id AND p.posicion=s.posicion
WHERE  p.fecha_documento >= @ini AND p.fecha_documento <= @fin
GROUP BY s.motivo
ORDER BY SUM(p.monto) DESC;
GO
