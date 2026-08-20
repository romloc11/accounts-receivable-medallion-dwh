USE ANALISIS_DATOS;
GO

-- De los 52,179 casos de sobre-resolucion que quedan tras el fix de
-- "2+ categorias compitiendo": ¿vienen de REBZG (Nivel 1), de
-- GRUPO_INAMBIGUO (Nivel 2), o de una mezcla de ambos para la misma factura?
;WITH sobre_resueltas AS (
    SELECT sociedad, cliente_id, documento_factura, ejercicio_factura, posicion_factura
    FROM gold.fact_aplicacion_pagos
    WHERE tipo_aplicacion IS NOT NULL
    GROUP BY sociedad, cliente_id, documento_factura, ejercicio_factura, posicion_factura, monto_factura
    HAVING SUM(monto_aplicado) > monto_factura + 1.00
),
metodos_por_factura AS (
    SELECT f.sociedad, f.cliente_id, f.documento_factura, f.ejercicio_factura, f.posicion_factura,
           COUNT(DISTINCT f.metodo_match) AS num_metodos_distintos,
           MIN(f.metodo_match) AS metodo_si_solo_1
    FROM gold.fact_aplicacion_pagos f
    JOIN sobre_resueltas s
        ON s.sociedad = f.sociedad AND s.cliente_id = f.cliente_id
       AND s.documento_factura = f.documento_factura AND s.ejercicio_factura = f.ejercicio_factura
       AND s.posicion_factura = f.posicion_factura
    WHERE f.tipo_aplicacion IS NOT NULL
    GROUP BY f.sociedad, f.cliente_id, f.documento_factura, f.ejercicio_factura, f.posicion_factura
)
SELECT
    CASE WHEN num_metodos_distintos > 1 THEN 'Mezcla REBZG + GRUPO_INAMBIGUO'
         ELSE metodo_si_solo_1 + ' solo' END AS patron,
    COUNT(*) AS num_facturas
FROM metodos_por_factura
GROUP BY CASE WHEN num_metodos_distintos > 1 THEN 'Mezcla REBZG + GRUPO_INAMBIGUO'
         ELSE metodo_si_solo_1 + ' solo' END;

-- Ejemplo real completo de una factura sobre-resuelta (para ver el patron a detalle)
;WITH sobre_resueltas AS (
    SELECT TOP 1 sociedad, cliente_id, documento_factura, ejercicio_factura, posicion_factura
    FROM gold.fact_aplicacion_pagos
    WHERE tipo_aplicacion IS NOT NULL
    GROUP BY sociedad, cliente_id, documento_factura, ejercicio_factura, posicion_factura, monto_factura
    HAVING SUM(monto_aplicado) > monto_factura + 1.00
)
SELECT f.*
FROM gold.fact_aplicacion_pagos f
JOIN sobre_resueltas s
    ON s.sociedad = f.sociedad AND s.cliente_id = f.cliente_id
   AND s.documento_factura = f.documento_factura AND s.ejercicio_factura = f.ejercicio_factura
   AND s.posicion_factura = f.posicion_factura
ORDER BY f.tipo_aplicacion, f.metodo_match;
GO
