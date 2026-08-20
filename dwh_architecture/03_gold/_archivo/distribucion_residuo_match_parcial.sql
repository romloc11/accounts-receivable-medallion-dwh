USE ANALISIS_DATOS;
GO

-- El caso del cliente 10000876 confirmo que un residuo NULL puede coexistir
-- con una fila ya resuelta por REBZG para la MISMA factura, y que el residuo
-- puede ser solo centavos (descuento pronto-pago via 2 AB ambiguos). Antes de
-- cerrar la investigacion: ¿el bucket "Match parcial, 2+ candidatos
-- (ambiguedad genuina)" de investigacion_sin_match_v6.sql ($728,878.39 en
-- 889 facturas) esta dominado por residuos chiquitos como este, o hay casos
-- grandes de verdad sin explicar?

DECLARE @fecha_inicio DATE = '20260601';
DECLARE @fecha_fin    DATE = '20260731';

;WITH resuelto AS (
    SELECT sociedad, cliente_id, documento_factura, ejercicio_factura, posicion_factura,
           SUM(monto_aplicado) AS monto_resuelto
    FROM gold.fact_aplicacion_pagos
    WHERE fecha_compensacion BETWEEN @fecha_inicio AND @fecha_fin AND tipo_aplicacion IS NOT NULL
    GROUP BY sociedad, cliente_id, documento_factura, ejercicio_factura, posicion_factura
),
residuo_parcial AS (
    -- solo las facturas que YA tienen algo resuelto (match parcial, no "nunca")
    SELECT f.documento_factura, f.monto_factura, r.monto_resuelto,
           f.monto_factura - r.monto_resuelto AS monto_sin_explicar
    FROM gold.fact_aplicacion_pagos f
    JOIN resuelto r
        ON r.sociedad = f.sociedad AND r.cliente_id = f.cliente_id
       AND r.documento_factura = f.documento_factura AND r.ejercicio_factura = f.ejercicio_factura
       AND r.posicion_factura = f.posicion_factura
    WHERE f.tipo_aplicacion IS NULL
      AND f.monto_factura - r.monto_resuelto > 0.01
)
SELECT
    CASE
        WHEN monto_sin_explicar <= 1 THEN '<= $1 (residuo de centavos, tipo descuento pronto-pago)'
        WHEN monto_sin_explicar <= 10 THEN '$1 - $10'
        WHEN monto_sin_explicar <= 100 THEN '$10 - $100'
        WHEN monto_sin_explicar <= 1000 THEN '$100 - $1,000'
        ELSE '> $1,000 (caso grande, revisar)'
    END AS rango_residuo,
    COUNT(*) AS num_facturas,
    SUM(monto_sin_explicar) AS monto_total_sin_explicar
FROM residuo_parcial
GROUP BY
    CASE
        WHEN monto_sin_explicar <= 1 THEN '<= $1 (residuo de centavos, tipo descuento pronto-pago)'
        WHEN monto_sin_explicar <= 10 THEN '$1 - $10'
        WHEN monto_sin_explicar <= 100 THEN '$10 - $100'
        WHEN monto_sin_explicar <= 1000 THEN '$100 - $1,000'
        ELSE '> $1,000 (caso grande, revisar)'
    END
ORDER BY MIN(monto_sin_explicar);
GO
