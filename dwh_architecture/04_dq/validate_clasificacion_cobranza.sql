USE ANALISIS_DATOS;
GO

/*
===============================================================================
PROJECT: Enterprise Data Warehouse (accounts-receivable-medallion-dwh)
LAYER: DQ - ad-hoc validation query (NOT an automated monitor)

Unlike the other objects in this folder (dq.clientes_ambiguos, a table
refreshed on every load), this is a standalone re-runnable query, not a
table/stored procedure. It doesn't flag a business data inconsistency to fix
in SAP - it answers a recurring stakeholder question about a deliberate
design choice in gold.vw_pago_factura_simple's clasificacion_cobranza field:
"can this classification produce inflated numbers?"

BACKGROUND: clasificacion_cobranza (CARTERA_VENCIDA / CARTERA_DEL_MES /
PAGO_ANTICIPADO) compares the CALENDAR MONTH of fecha_vencimiento against the
calendar month of fecha_pago - not the exact day gap between them (dias_pago
carries that instead). This is intentional (the field feeds a future monthly
budget-compliance report, where "which month's cartera was this" is the right
question), but it means a payment made 1 day before/after a month boundary
can land in a bucket that looks more extreme than it really is. See
vw_pago_factura_simple.sql's header comment and DESIGN.md for the full
writeup of why this is designed this way and isn't being changed.

VALIDATED 2026-08-26 over 2026 data: PAGO_ANTICIPADO inflated by 1-3-day
boundary crossings = 3.25% of that bucket's amount; CARTERA_DEL_MES hiding
invoices paid 17+ days late (same grace-period threshold gold.fact_saldo_cartera
already uses) = 1.9% of that bucket's amount. Both immaterial - re-run this
query with a fresh date range if asked the same question again, rather than
re-deriving the methodology from scratch.
===============================================================================
*/

DECLARE @fecha_inicio DATE = '2026-01-01'; -- adjust to whatever period is being asked about

SELECT
    clasificacion_cobranza,
    zona,
    num_facturas,
    monto,
    CAST(100.0 * monto / SUM(monto) OVER (PARTITION BY clasificacion_cobranza) AS DECIMAL(5,2)) AS pct_del_bucket
FROM (
    SELECT
        clasificacion_cobranza,
        CASE
            WHEN clasificacion_cobranza = 'PAGO_ANTICIPADO' AND dias_pago >= -3 THEN 'posible efecto de frontera de mes (1-3 dias antes)'
            WHEN clasificacion_cobranza = 'CARTERA_DEL_MES'  AND dias_pago > 16  THEN 'posible vencido real escondido (17+ dias tarde)'
            ELSE 'clasificacion confiable'
        END AS zona,
        COUNT(*) AS num_facturas,
        SUM(monto_factura) AS monto
    FROM gold.vw_pago_factura_simple
    WHERE fecha_pago >= @fecha_inicio
      AND clasificacion_cobranza IN ('PAGO_ANTICIPADO', 'CARTERA_DEL_MES')
    GROUP BY clasificacion_cobranza,
        CASE
            WHEN clasificacion_cobranza = 'PAGO_ANTICIPADO' AND dias_pago >= -3 THEN 'posible efecto de frontera de mes (1-3 dias antes)'
            WHEN clasificacion_cobranza = 'CARTERA_DEL_MES'  AND dias_pago > 16  THEN 'posible vencido real escondido (17+ dias tarde)'
            ELSE 'clasificacion confiable'
        END
) x
ORDER BY clasificacion_cobranza, zona;
GO
