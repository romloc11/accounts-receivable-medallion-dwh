USE ANALISIS_DATOS;
GO

-- 3 ejemplos reales del bucket "Nunca tuvo match / 2+ candidatos disponibles
-- (ambiguedad genuina)" de investigacion_sin_match_v6.sql (5,206 facturas,
-- $3.21M, canal 10/40/60), ordenados por monto para traer los mas grandes.
-- Mismo filtro de canal que el poblado real.

DECLARE @fecha_inicio DATE = '20260601';
DECLARE @fecha_fin    DATE = '20260731';
DECLARE @top_n INT = 3;

IF OBJECT_ID('tempdb..#factura') IS NOT NULL DROP TABLE #factura;
SELECT b.*
INTO #factura
FROM silver.sap_bsad b
JOIN gold.dim_cliente_comercial dc
    ON dc.cliente_id = b.cliente_id AND dc.es_vigente = 1
WHERE b.clase_documento IN ('F1','F2','F3','F4','F5','F6')
  AND b.fecha_compensacion BETWEEN @fecha_inicio AND @fecha_fin
  AND dc.canal_distribucion IN ('10','40','60');

CREATE INDEX IX_factura_grupo ON #factura (sociedad, cliente_id, documento_compensacion, ejercicio_compensacion);

IF OBJECT_ID('tempdb..#aplicacion') IS NOT NULL DROP TABLE #aplicacion;
SELECT *,
    CASE
        WHEN clase_documento IN ('DZ','CP','ZY') THEN 'PAGO'
        WHEN clase_documento = 'C5' THEN 'NOTA_CREDITO'
        WHEN clase_documento = 'D1' THEN 'NOTA_DEBITO'
        WHEN clase_documento IN ('C1','C2','C3','C4') THEN 'DEVOLUCION'
        WHEN clase_documento = 'AB' THEN 'AJUSTE'
        WHEN clase_documento IN ('Z1','Z2','Z3') THEN 'ANULACION'
    END AS tipo_aplicacion
INTO #aplicacion
FROM silver.sap_bsad
WHERE (
        clase_documento IN ('CP','ZY','C5','D1','C1','C2','C3','C4','AB','Z1','Z2','Z3')
        OR (clase_documento = 'DZ' AND debe_haber <> 'S')
      )
  AND fecha_compensacion BETWEEN @fecha_inicio AND @fecha_fin;

CREATE INDEX IX_aplicacion_grupo ON #aplicacion (sociedad, cliente_id, documento_compensacion, ejercicio_compensacion, tipo_aplicacion);
CREATE INDEX IX_aplicacion_rebzg ON #aplicacion (sociedad, cliente_id, factura_referencia_documento, factura_referencia_ejercicio, factura_referencia_posicion);

IF OBJECT_ID('tempdb..#grupo_categoria') IS NOT NULL DROP TABLE #grupo_categoria;
SELECT
    a.sociedad, a.cliente_id, a.documento_compensacion, a.ejercicio_compensacion, a.tipo_aplicacion,
    COUNT(*) AS num_disponibles
INTO #grupo_categoria
FROM #aplicacion a
WHERE NOT EXISTS (
    SELECT 1 FROM #factura f
    WHERE f.sociedad = a.sociedad AND f.cliente_id = a.cliente_id
      AND f.documento_id = a.factura_referencia_documento
      AND f.ejercicio = a.factura_referencia_ejercicio
      AND f.posicion = a.factura_referencia_posicion
)
GROUP BY a.sociedad, a.cliente_id, a.documento_compensacion, a.ejercicio_compensacion, a.tipo_aplicacion;

;WITH residuo AS (
    SELECT f.sociedad, f.cliente_id, f.documento_compensacion, f.ejercicio_compensacion,
           f.documento_id, f.ejercicio, f.posicion, f.monto_moneda_local AS monto_sin_explicar
    FROM #factura f
    WHERE NOT EXISTS (
        SELECT 1 FROM gold.fact_aplicacion_pagos fp
        WHERE fp.sociedad = f.sociedad AND fp.cliente_id = f.cliente_id
          AND fp.documento_factura = f.documento_id AND fp.ejercicio_factura = f.ejercicio
          AND fp.posicion_factura = f.posicion AND fp.tipo_aplicacion IS NOT NULL
    )
),
con_candidatos AS (
    SELECT
        r.*,
        (SELECT MAX(gc.num_disponibles) FROM #grupo_categoria gc
         WHERE gc.sociedad = r.sociedad AND gc.cliente_id = r.cliente_id
           AND gc.documento_compensacion = r.documento_compensacion
           AND gc.ejercicio_compensacion = r.ejercicio_compensacion) AS max_candidatos_en_grupo
    FROM residuo r
)
SELECT TOP (@top_n)
    cliente_id, documento_id AS documento_factura, documento_compensacion, ejercicio_compensacion, monto_sin_explicar
FROM con_candidatos
WHERE ISNULL(max_candidatos_en_grupo, 0) >= 2
ORDER BY monto_sin_explicar DESC;

DROP TABLE #factura;
DROP TABLE #aplicacion;
DROP TABLE #grupo_categoria;
GO
