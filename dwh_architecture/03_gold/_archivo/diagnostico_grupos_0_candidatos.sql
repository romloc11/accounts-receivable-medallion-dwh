USE ANALISIS_DATOS;
GO

-- Los 1,326 casos "0 candidatos disponibles" de investigacion_sin_match_v6.sql
-- no tienen NINGUNA fila en las 6 categorias conocidas (PAGO/NOTA_CREDITO/
-- NOTA_DEBITO/DEVOLUCION/AJUSTE/ANULACION) dentro de su grupo de compensacion.
-- Este script mira, SIN FILTRAR por clase_documento, que hay realmente en
-- esos grupos - para ver si es un clase_documento no catalogado (ej. 'SA',
-- documento de mayor/GL, ya visto rondando en v4) o algo mas.

DECLARE @fecha_inicio DATE = '20260601';
DECLARE @fecha_fin    DATE = '20260731';

IF OBJECT_ID('tempdb..#factura') IS NOT NULL DROP TABLE #factura;
SELECT *
INTO #factura
FROM silver.sap_bsad
WHERE clase_documento IN ('F1','F2','F3','F4','F5','F6')
  AND fecha_compensacion BETWEEN @fecha_inicio AND @fecha_fin;

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

;WITH resuelto AS (
    SELECT sociedad, cliente_id, documento_factura, ejercicio_factura, posicion_factura,
           SUM(monto_aplicado) AS monto_resuelto
    FROM gold.fact_aplicacion_pagos
    WHERE fecha_compensacion BETWEEN @fecha_inicio AND @fecha_fin AND tipo_aplicacion IS NOT NULL
    GROUP BY sociedad, cliente_id, documento_factura, ejercicio_factura, posicion_factura
),
residuo AS (
    SELECT f.sociedad, f.cliente_id, f.documento_compensacion, f.ejercicio_compensacion,
           f.documento_id, f.ejercicio, f.posicion,
           f.monto_moneda_local - ISNULL(r.monto_resuelto, 0) AS monto_sin_explicar
    FROM #factura f
    LEFT JOIN resuelto r
        ON r.sociedad = f.sociedad AND r.cliente_id = f.cliente_id
       AND r.documento_factura = f.documento_id AND r.ejercicio_factura = f.ejercicio
       AND r.posicion_factura = f.posicion
    WHERE f.monto_moneda_local - ISNULL(r.monto_resuelto, 0) > 0.01
),
grupos_0_candidatos AS (
    SELECT DISTINCT r.sociedad, r.cliente_id, r.documento_compensacion, r.ejercicio_compensacion
    FROM residuo r
    WHERE NOT EXISTS (
        SELECT 1 FROM #grupo_categoria gc
        WHERE gc.sociedad = r.sociedad AND gc.cliente_id = r.cliente_id
          AND gc.documento_compensacion = r.documento_compensacion
          AND gc.ejercicio_compensacion = r.ejercicio_compensacion
    )
)
-- Que clase_documento realmente aparece en estos grupos (sin filtrar nada,
-- pero SI respetando cliente_id - documento_compensacion no es unico entre
-- clientes distintos, hay que mantener la llave completa de 4 partes)
SELECT
    b.clase_documento,
    b.debe_haber,
    COUNT(*) AS num_lineas,
    COUNT(DISTINCT CONCAT(g.sociedad,'|',g.cliente_id,'|',g.documento_compensacion,'|',g.ejercicio_compensacion)) AS num_grupos_distintos,
    SUM(b.monto_moneda_local) AS monto_total
FROM grupos_0_candidatos g
JOIN silver.sap_bsad b
    ON b.sociedad = g.sociedad
   AND b.cliente_id = g.cliente_id
   AND b.documento_compensacion = g.documento_compensacion
   AND b.ejercicio_compensacion = g.ejercicio_compensacion
GROUP BY b.clase_documento, b.debe_haber
ORDER BY num_lineas DESC;

DROP TABLE #factura;
DROP TABLE #aplicacion;
DROP TABLE #grupo_categoria;
GO
