USE ANALISIS_DATOS;
GO

-- ¿Que tan extendido esta el patron "fecha_pago muy anterior a fecha_factura"
-- (mas alla del ruido normal de +-pocos dias por posteo)? Umbral: 30 dias
-- antes de fecha_factura ya no es "posteo tardio normal", es sospechoso.
SELECT
    CASE
        WHEN DATEDIFF(DAY, fecha_factura, fecha_pago) >= -5 THEN '>= -5 dias (ruido normal de posteo)'
        WHEN DATEDIFF(DAY, fecha_factura, fecha_pago) >= -30 THEN '-6 a -30 dias (revisar)'
        ELSE '< -30 dias (claramente ilogico)'
    END AS categoria,
    COUNT(*) AS num_filas,
    SUM(monto_aplicado) AS monto_total,
    COUNT(DISTINCT cliente_id) AS num_clientes_distintos
FROM gold.fact_aplicacion_pagos
WHERE tipo_aplicacion = 'PAGO' AND fecha_pago IS NOT NULL
  AND DATEDIFF(DAY, fecha_factura, fecha_pago) < -5
GROUP BY
    CASE
        WHEN DATEDIFF(DAY, fecha_factura, fecha_pago) >= -5 THEN '>= -5 dias (ruido normal de posteo)'
        WHEN DATEDIFF(DAY, fecha_factura, fecha_pago) >= -30 THEN '-6 a -30 dias (revisar)'
        ELSE '< -30 dias (claramente ilogico)'
    END;

-- Lo mismo pero para dias_anticipacion_vencimiento (la metrica que SI se usa
-- para clasificar "a tiempo/tarde" en el reporte real, mas importante que DPP)
SELECT
    CASE
        WHEN metodo_match = 'REBZG' THEN 'REBZG'
        ELSE 'GRUPO_INAMBIGUO'
    END AS metodo,
    COUNT(*) AS num_filas_con_vencimiento_muy_temprano
FROM gold.fact_aplicacion_pagos
WHERE tipo_aplicacion = 'PAGO' AND dias_anticipacion_vencimiento < -180  -- pagado mas de 6 meses "antes" de vencer es sospechoso
GROUP BY CASE WHEN metodo_match = 'REBZG' THEN 'REBZG' ELSE 'GRUPO_INAMBIGUO' END;
GO
