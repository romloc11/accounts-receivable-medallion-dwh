USE ANALISIS_DATOS;
GO

-- De las facturas sin match, cuantas tienen un Z1 (anulacion) en su MISMO
-- grupo de compensacion (es decir, fueron canceladas, no "sin resolver")
;WITH sin_match AS (
    SELECT sociedad, cliente_id, documento_factura, ejercicio_factura, posicion_factura,
           documento_compensacion, ejercicio_compensacion, monto_factura
    FROM gold.fact_aplicacion_pagos
    WHERE tipo_aplicacion IS NULL AND documento_compensacion IS NOT NULL
),
con_flag AS (
    SELECT sm.*,
        CASE WHEN EXISTS (
            SELECT 1 FROM silver.sap_bsad b
            WHERE b.sociedad = sm.sociedad AND b.cliente_id = sm.cliente_id
              AND b.documento_compensacion = sm.documento_compensacion AND b.ejercicio_compensacion = sm.ejercicio_compensacion
              AND b.clase_documento = 'Z1'
        ) THEN 1 ELSE 0 END AS tiene_z1
    FROM sin_match sm
)
SELECT
    COUNT(*) AS total_sin_match,
    SUM(tiene_z1) AS con_anulacion_z1,
    SUM(CASE WHEN tiene_z1 = 1 THEN monto_factura ELSE 0 END) AS monto_con_anulacion_z1
FROM con_flag;
GO
