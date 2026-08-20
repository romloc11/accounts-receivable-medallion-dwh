USE ANALISIS_DATOS;
GO

-- 1. Un ejemplo real de id_cliente_comercial apuntando fuera de su vigencia -
-- para confirmar la hipotesis del reinicio de IDENTITY por el incidente de
-- ddl_gold.sql (ver si fecha_carga de la fila de fact es ANTERIOR a cuando
-- se reconstruyo dim_cliente_comercial)
SELECT TOP 5
    f.id_surrogate AS fact_id, f.cliente_id, f.documento_factura, f.fecha_compensacion,
    f.id_cliente_comercial, f.fecha_carga AS fact_fecha_carga,
    dc.cliente_id AS dim_cliente_id_real, dc.fecha_inicio_vigencia, dc.fecha_fin_vigencia, dc.fecha_carga AS dim_fecha_carga
FROM gold.fact_aplicacion_pagos f
JOIN gold.dim_cliente_comercial dc ON dc.id_surrogate = f.id_cliente_comercial
WHERE f.fecha_compensacion NOT BETWEEN dc.fecha_inicio_vigencia AND ISNULL(dc.fecha_fin_vigencia, '99991231')
ORDER BY f.id_surrogate;

-- 2. Un ejemplo real de sobre-resolucion, con TODAS las filas de esa factura
-- para ver el patron exacto (duplicados por fecha_compensacion distinta,
-- doble asignacion de saldo pendiente, u otra cosa)
;WITH sobre_resuelta AS (
    SELECT TOP 1 sociedad, cliente_id, documento_factura, ejercicio_factura, posicion_factura
    FROM gold.fact_aplicacion_pagos
    WHERE tipo_aplicacion IS NOT NULL
    GROUP BY sociedad, cliente_id, documento_factura, ejercicio_factura, posicion_factura, monto_factura
    HAVING SUM(monto_aplicado) > monto_factura + 1.00
)
SELECT f.*
FROM gold.fact_aplicacion_pagos f
JOIN sobre_resuelta s
    ON s.sociedad = f.sociedad AND s.cliente_id = f.cliente_id
   AND s.documento_factura = f.documento_factura AND s.ejercicio_factura = f.ejercicio_factura
   AND s.posicion_factura = f.posicion_factura
ORDER BY f.fecha_compensacion, f.tipo_aplicacion;

-- 3. De los 178,024 casos de sobre-resolucion, ¿cuantos tienen mas de UNA
-- fecha_compensacion distinta para la MISMA factura? (confirmaria/descartaria
-- la hipotesis de filas huerfanas por reversion/recompensacion)
;WITH sobre_resueltas_todas AS (
    SELECT sociedad, cliente_id, documento_factura, ejercicio_factura, posicion_factura
    FROM gold.fact_aplicacion_pagos
    WHERE tipo_aplicacion IS NOT NULL
    GROUP BY sociedad, cliente_id, documento_factura, ejercicio_factura, posicion_factura, monto_factura
    HAVING SUM(monto_aplicado) > monto_factura + 1.00
)
SELECT
    CASE WHEN num_fechas_compensacion_distintas > 1 THEN '2+ fecha_compensacion distintas (confirma hipotesis reversion)'
         ELSE '1 sola fecha_compensacion (otra causa)' END AS patron,
    COUNT(*) AS num_facturas
FROM (
    SELECT f.sociedad, f.cliente_id, f.documento_factura, f.ejercicio_factura, f.posicion_factura,
           COUNT(DISTINCT f.fecha_compensacion) AS num_fechas_compensacion_distintas
    FROM gold.fact_aplicacion_pagos f
    JOIN sobre_resueltas_todas s
        ON s.sociedad = f.sociedad AND s.cliente_id = f.cliente_id
       AND s.documento_factura = f.documento_factura AND s.ejercicio_factura = f.ejercicio_factura
       AND s.posicion_factura = f.posicion_factura
    GROUP BY f.sociedad, f.cliente_id, f.documento_factura, f.ejercicio_factura, f.posicion_factura
) x
GROUP BY CASE WHEN num_fechas_compensacion_distintas > 1 THEN '2+ fecha_compensacion distintas (confirma hipotesis reversion)'
         ELSE '1 sola fecha_compensacion (otra causa)' END;
GO
