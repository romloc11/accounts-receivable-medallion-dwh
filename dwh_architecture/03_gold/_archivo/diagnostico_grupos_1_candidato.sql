USE ANALISIS_DATOS;
GO

-- Complemento de investigacion_sin_match_v6.sql: si ese script muestra
-- facturas en el patron "1 candidato disponible (revisar)", este extrae los
-- documento_compensacion concretos (los de mayor monto sin explicar primero)
-- para inspeccionar linea por linea en silver.sap_bsad / SAP.
-- Si v6 no arrojo NINGUNA fila en ese patron, este script no es necesario.

DECLARE @fecha_inicio DATE = '20260601';
DECLARE @fecha_fin    DATE = '20260731';
DECLARE @top_n INT = 5;

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
con_candidatos AS (
    SELECT
        r.*,
        (SELECT MAX(gc.num_disponibles) FROM #grupo_categoria gc
         WHERE gc.sociedad = r.sociedad AND gc.cliente_id = r.cliente_id
           AND gc.documento_compensacion = r.documento_compensacion
           AND gc.ejercicio_compensacion = r.ejercicio_compensacion) AS max_candidatos_en_grupo,
        (SELECT COUNT(*) FROM #grupo_categoria gc
         WHERE gc.sociedad = r.sociedad AND gc.cliente_id = r.cliente_id
           AND gc.documento_compensacion = r.documento_compensacion
           AND gc.ejercicio_compensacion = r.ejercicio_compensacion
           AND gc.num_disponibles = 1) AS num_categorias_con_1_disponible
    FROM residuo r
),
grupos_candidatos AS (
    SELECT DISTINCT sociedad, documento_compensacion, ejercicio_compensacion,
           SUM(monto_sin_explicar) OVER (PARTITION BY sociedad, documento_compensacion, ejercicio_compensacion) AS monto_grupo_sin_explicar
    FROM con_candidatos
    WHERE max_candidatos_en_grupo = 1 AND num_categorias_con_1_disponible = 1
)
SELECT TOP (@top_n) *
FROM grupos_candidatos
ORDER BY monto_grupo_sin_explicar DESC;

-- Copia el/los documento_compensacion que arroje la consulta anterior y
-- pegalos en la lista de abajo (reemplaza los valores de ejemplo) para ver el
-- detalle linea por linea:
/*
SELECT
    documento_id, posicion, clase_documento, debe_haber, sgtxt,
    monto_moneda_local, documento_compensacion, ejercicio_compensacion,
    factura_referencia_documento, factura_referencia_ejercicio, factura_referencia_posicion
FROM silver.sap_bsad
WHERE sociedad = '2000' AND documento_compensacion IN ('<pegar aqui>')
  AND ejercicio_compensacion = 2026
ORDER BY documento_compensacion, documento_id, posicion;
*/

DROP TABLE #factura;
DROP TABLE #aplicacion;
DROP TABLE #grupo_categoria;
GO
