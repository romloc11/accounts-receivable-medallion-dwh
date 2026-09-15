/* ============================================================================
   Validation: clasificacion_cobranza boundary effect
   Purpose : Ad-hoc query. Measures how much of each bucket of
             gold.vw_pago_factura_simple.clasificacion_cobranza could be a
             month-boundary effect, since it compares calendar months, not days.
   Run     : any time; read-only. Change @fecha_inicio.
   Notes   : Last run over 2026: PAGO_ANTICIPADO 1-3 days early = 3.25% of the
             bucket; CARTERA_DEL_MES 17+ days late = 1.9%. Both immaterial.
             Design rationale in DESIGN.md.
   ============================================================================ */
USE ANALISIS_DATOS;
GO

DECLARE @fecha_inicio DATE = '2026-01-01';

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
