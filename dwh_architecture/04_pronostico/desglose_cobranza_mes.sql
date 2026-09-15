/* ============================================================================
   Monthly collections breakdown
   Purpose : What a month's collections are made of: the mirror of the budget,
             measured backwards. Four slices of settled invoices, then the
             reconciliation against the month's cash.
   Run     : any time; read-only. Change @ini.
   Notes   : Dates by fecha_documento (when the customer paid); the reconciliation
             also shows the cash by clearing and posting date.
             Measured by invoice, not by payment: a deposit that settles several
             invoices cannot be split, so the total differs from cash and the
             difference is shown, not hidden.
             PAGO_A_VENCIMIENTO means the invoice was already overdue before the
             month; it is relabeled here as overdue portfolio.
             "Invoiced and collected in the month" is taken out of the other
             slices, so the four add up exactly.
   ============================================================================ */
USE ANALISIS_DATOS;
GO

DECLARE @ini DATE = '2026-07-01';
DECLARE @fin DATE = EOMONTH(@ini);

-- ----------------------------------------------------------------------------
-- Invoices settled in the month
-- ----------------------------------------------------------------------------
IF OBJECT_ID('tempdb..#f') IS NOT NULL DROP TABLE #f;
SELECT f.monto,
       CASE
         WHEN f.fecha_documento >= @ini                THEN 2
         WHEN f.clasificacion_cobranza = 'PAGO_A_MES'  THEN 1
         WHEN f.clasificacion_cobranza = 'PAGO_ANTICIPADO' THEN 3
         ELSE 4
       END AS orden
INTO   #f
FROM   gold.fact_facturas f
WHERE  f.fecha_pago_efectiva >= @ini AND f.fecha_pago_efectiva <= @fin;

DECLARE @fact DECIMAL(19,2) = (SELECT SUM(monto) FROM #f);

-- ----------------------------------------------------------------------------
-- Cash of the month, by the three dates
-- ----------------------------------------------------------------------------
DECLARE @caja_doc DECIMAL(19,2) = (SELECT ISNULL(SUM(monto),0) FROM gold.fact_pagos
    WHERE fecha_documento      >= @ini AND fecha_documento      <= @fin);
DECLARE @caja_cnt DECIMAL(19,2) = (SELECT ISNULL(SUM(monto),0) FROM gold.fact_pagos
    WHERE fecha_contabilizacion>= @ini AND fecha_contabilizacion<= @fin);
DECLARE @caja_cmp DECIMAL(19,2) = (SELECT ISNULL(SUM(monto),0) FROM gold.fact_pagos
    WHERE fecha_compensacion   >= @ini AND fecha_compensacion   <= @fin);

-- Payments of the month that settle no invoice (shown with their reason).
DECLARE @nolig DECIMAL(19,2) = (SELECT ISNULL(SUM(p.monto),0)
    FROM gold.fact_pagos_sin_aplicacion s
    JOIN gold.fact_pagos p ON p.sociedad=s.sociedad AND p.cliente_id=s.cliente_id
         AND p.ejercicio=s.ejercicio AND p.documento_id=s.documento_id AND p.posicion=s.posicion
    WHERE p.fecha_documento >= @ini AND p.fecha_documento <= @fin);

-- ----------------------------------------------------------------------------
-- Result
-- ----------------------------------------------------------------------------
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
    -- Mostly the difference between what a payment brought and the face value of
    -- the invoices it settled (the bridge links, it does not split amounts); only a
    -- small part is payments to invoices settled in another month.
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

-- ----------------------------------------------------------------------------
-- Detail of what settles no invoice
-- ----------------------------------------------------------------------------
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
