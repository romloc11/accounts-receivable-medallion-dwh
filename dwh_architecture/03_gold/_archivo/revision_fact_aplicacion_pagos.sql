USE ANALISIS_DATOS;
GO

-- Revision de gold.fact_aplicacion_pagos. Cubre el rango realmente cargado
-- (2024-01-01 en adelante, backfill + incremental).
DECLARE @fecha_inicio DATE = '20240101';
DECLARE @fecha_fin    DATE = CAST(GETDATE() AS DATE);

-- 1. Las 4 FK existen y estan activas (no deshabilitadas)
SELECT 'FKs_activas (deberia ser 4)' AS chequeo,
    CAST((SELECT COUNT(*) FROM sys.foreign_keys
          WHERE parent_object_id = OBJECT_ID('gold.fact_aplicacion_pagos') AND is_disabled = 0) AS DECIMAL(10,2)) AS valor

UNION ALL

-- 2. Cobertura: toda factura de silver.sap_bsad en el rango debe tener AL
-- MENOS una fila en la fact (resuelta o residuo)
SELECT 'facturas_en_silver_sin_ninguna_fila_en_fact',
    CAST((
        SELECT COUNT(*) FROM silver.sap_bsad b
        WHERE b.clase_documento IN ('F1','F2','F3','F4','F5','F6')
          AND b.fecha_compensacion BETWEEN @fecha_inicio AND @fecha_fin
          AND NOT EXISTS (
              SELECT 1 FROM gold.fact_aplicacion_pagos f
              WHERE f.sociedad = b.sociedad AND f.cliente_id = b.cliente_id
                AND f.documento_factura = b.documento_id AND f.ejercicio_factura = b.ejercicio
                AND f.posicion_factura = b.posicion
          )
    ) AS DECIMAL(10,2))

UNION ALL

-- 3. Sobre-resolucion: facturas donde lo aplicado suma MAS que su propio
-- monto (mas alla de centavos de redondeo) - señal del bug de fan-out ya
-- visto antes en este proyecto
SELECT 'facturas_con_monto_aplicado_mayor_al_monto_factura',
    CAST((
        SELECT COUNT(*) FROM (
            SELECT documento_factura, ejercicio_factura, posicion_factura, cliente_id,
                   MAX(monto_factura) AS monto_factura, SUM(monto_aplicado) AS total_aplicado
            FROM gold.fact_aplicacion_pagos
            WHERE fecha_compensacion BETWEEN @fecha_inicio AND @fecha_fin AND tipo_aplicacion IS NOT NULL
            GROUP BY documento_factura, ejercicio_factura, posicion_factura, cliente_id
            HAVING SUM(monto_aplicado) > MAX(monto_factura) + 1.00
        ) x
    ) AS DECIMAL(10,2))

UNION ALL

SELECT 'tipo_aplicacion_fuera_de_catalogo',
    CAST((SELECT COUNT(*) FROM gold.fact_aplicacion_pagos
          WHERE tipo_aplicacion IS NOT NULL
            AND tipo_aplicacion NOT IN ('PAGO','NOTA_CREDITO','NOTA_DEBITO','DEVOLUCION','AJUSTE','ANULACION')) AS DECIMAL(10,2))

UNION ALL

SELECT 'metodo_match_fuera_de_catalogo',
    CAST((SELECT COUNT(*) FROM gold.fact_aplicacion_pagos
          WHERE metodo_match IS NOT NULL AND metodo_match NOT IN ('REBZG','GRUPO_INAMBIGUO')) AS DECIMAL(10,2))

UNION ALL

SELECT 'tipo_aplicacion_y_metodo_match_inconsistentes',
    CAST((SELECT COUNT(*) FROM gold.fact_aplicacion_pagos
          WHERE (tipo_aplicacion IS NULL AND metodo_match IS NOT NULL)
             OR (tipo_aplicacion IS NOT NULL AND metodo_match IS NULL)) AS DECIMAL(10,2))

UNION ALL

-- 4. Columnas exclusivas de PAGO no deberian poblarse en otras categorias
SELECT 'columnas_de_pago_pobladas_fuera_de_tipo_pago',
    CAST((SELECT COUNT(*) FROM gold.fact_aplicacion_pagos
          WHERE tipo_aplicacion IS NOT NULL AND tipo_aplicacion <> 'PAGO'
            AND (documento_pago_virgen IS NOT NULL OR fecha_pago IS NOT NULL
                 OR monto_pago_virgen IS NOT NULL OR dias_anticipacion_vencimiento IS NOT NULL)) AS DECIMAL(10,2))

UNION ALL

-- 5. monto_factura/monto_aplicado no deberian ser negativos
SELECT 'monto_factura_negativo_o_cero',
    CAST((SELECT COUNT(*) FROM gold.fact_aplicacion_pagos WHERE monto_factura <= 0) AS DECIMAL(10,2))

UNION ALL

SELECT 'monto_aplicado_negativo',
    CAST((SELECT COUNT(*) FROM gold.fact_aplicacion_pagos WHERE monto_aplicado < 0) AS DECIMAL(10,2))

UNION ALL

-- 6. join temporal de id_cliente_comercial: si esta poblado, fecha_compensacion
-- debe caer dentro de la vigencia de esa version (deberia ser garantizado por
-- el propio JOIN de la carga, pero confirmamos que no hay drift)
SELECT 'id_cliente_comercial_fuera_de_su_vigencia',
    CAST((
        SELECT COUNT(*) FROM gold.fact_aplicacion_pagos f
        JOIN gold.dim_cliente_comercial dc ON dc.id_surrogate = f.id_cliente_comercial
        WHERE f.fecha_compensacion NOT BETWEEN dc.fecha_inicio_vigencia AND ISNULL(dc.fecha_fin_vigencia, '99991231')
    ) AS DECIMAL(10,2));
GO
