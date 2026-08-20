USE ANALISIS_DATOS;
GO

SELECT 'FKs_activas (deberia ser 4)' AS chequeo,
    CAST((SELECT COUNT(*) FROM sys.foreign_keys
          WHERE parent_object_id = OBJECT_ID('gold.fact_saldo_cartera') AND is_disabled = 0) AS DECIMAL(15,2)) AS valor

UNION ALL

-- Reconciliacion de saldo_total contra silver.sap_bsid (firmado por
-- debe_haber, excluyendo SA - mismo criterio que gold.load_fact_saldo_cartera
-- desde el rediseño 2026-08-18), SOLO para el snapshot mas reciente (bsid se
-- recarga completo cada dia, no tiene historia)
SELECT 'clientes_con_saldo_total_distinto_a_bsid_hoy',
    CAST((
        SELECT COUNT(*) FROM (
            SELECT s.cliente_id, s.saldo_total, b.saldo_bsid
            FROM gold.fact_saldo_cartera s
            JOIN (
                SELECT cliente_id,
                       SUM(CASE WHEN debe_haber = 'H' THEN -monto_moneda_local ELSE monto_moneda_local END) AS saldo_bsid
                FROM silver.sap_bsid
                WHERE clase_documento <> 'SA'
                GROUP BY cliente_id
            ) b ON b.cliente_id = s.cliente_id
            WHERE s.fecha_snapshot = (SELECT MAX(fecha_snapshot) FROM gold.fact_saldo_cartera)
              AND ABS(s.saldo_total - b.saldo_bsid) > 1.00
        ) x
    ) AS DECIMAL(15,2))

UNION ALL

SELECT 'buckets_antiguedad_no_suman_saldo_vencido',
    CAST((SELECT COUNT(*) FROM gold.fact_saldo_cartera
          WHERE ABS((saldo_17_31 + saldo_32_180 + saldo_181_mas) - saldo_vencido) > 1.00) AS DECIMAL(15,2))

UNION ALL

SELECT 'saldo_no_vencido_mas_gracia_mas_vencido_no_suma_total',
    CAST((SELECT COUNT(*) FROM gold.fact_saldo_cartera
          WHERE ABS((saldo_no_vencido + saldo_1_16 + saldo_vencido) - saldo_total) > 1.00) AS DECIMAL(15,2))

UNION ALL

-- dias_vencido_max se calcula sobre TODO lo vencido (incluye periodo de
-- gracia 1-16), no solo saldo_vencido (que ahora es SOLO 17+) - por eso la
-- consistencia se checa contra saldo_1_16+saldo_vencido, no solo saldo_vencido
SELECT 'dias_vencido_max_inconsistente (NULL con algo vencido, o poblado sin nada vencido)',
    CAST((SELECT COUNT(*) FROM gold.fact_saldo_cartera
          WHERE ((saldo_1_16 + saldo_vencido) > 0 AND dias_vencido_max IS NULL)
             OR ((saldo_1_16 + saldo_vencido) = 0 AND dias_vencido_max IS NOT NULL)) AS DECIMAL(15,2))

UNION ALL

SELECT 'pct_pagos_fuera_de_rango_0_100',
    CAST((SELECT COUNT(*) FROM gold.fact_saldo_cartera
          WHERE pct_pagos_a_tiempo_3m NOT BETWEEN 0 AND 100
             OR pct_pagos_tarde_3m NOT BETWEEN 0 AND 100
             OR pct_pagos_a_tiempo_12m NOT BETWEEN 0 AND 100
             OR pct_pagos_tarde_12m NOT BETWEEN 0 AND 100) AS DECIMAL(15,2))

UNION ALL

SELECT 'dpp_negativo',
    CAST((SELECT COUNT(*) FROM gold.fact_saldo_cartera
          WHERE dpp_3m < 0 OR dpp_12m < 0) AS DECIMAL(15,2))

UNION ALL

SELECT 'id_cliente_comercial_fuera_de_su_vigencia',
    CAST((
        SELECT COUNT(*) FROM gold.fact_saldo_cartera s
        JOIN gold.dim_cliente_comercial dc ON dc.id_surrogate = s.id_cliente_comercial
        WHERE s.fecha_snapshot NOT BETWEEN dc.fecha_inicio_vigencia AND ISNULL(dc.fecha_fin_vigencia, '99991231')
    ) AS DECIMAL(15,2))

UNION ALL

SELECT 'num_snapshots_distintos_guardados',
    CAST((SELECT COUNT(DISTINCT fecha_snapshot) FROM gold.fact_saldo_cartera) AS DECIMAL(15,2));
GO
