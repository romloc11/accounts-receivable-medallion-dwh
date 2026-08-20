USE ANALISIS_DATOS;
GO

-- v6: desglose de los residuos sin explicar (Nivel 3), generalizado a las 6
-- categorias de tipo_aplicacion (v4 solo miraba PAGO) y usando la MISMA logica
-- de "candidato disponible" que poblar_fact_aplicacion_pagos_prueba.sql paso 3
-- (excluye candidatos cuyo REBZG ya apunta a una factura real del grupo).
-- Tambien separa "nunca tuvo match" vs "match parcial" (igual que v5).
--
-- Objetivo: distinguir 3 escenarios por residuo, tomando el MAXIMO de
-- candidatos disponibles entre las 6 categorias del grupo de la factura:
--   0 candidatos  -> hueco real, no hay nada en el grupo para explicar el saldo
--   1 candidato   -> sospechoso: el nivel 2 deberia haberlo resuelto solo
--                    (posible caso de la "limitacion conocida" documentada en
--                    el paso 6b del poblado: 2 categorias distintas, ambas
--                    inambiguas en el mismo grupo, compitiendo por el mismo
--                    saldo pendiente - o un bug real, hay que revisar ejemplos)
--   2+ candidatos -> ambiguedad genuina (igual que lo ya confirmado en v3/v4)

DECLARE @fecha_inicio DATE = '20260601';
DECLARE @fecha_fin    DATE = '20260731';

-- 2026-08-17: revertido el filtro de canal (ver poblar_fact_aplicacion_pagos_prueba.sql
-- Paso 1) - la fact volvio a ser completa (todos los canales), el alcance de
-- negocio se filtra en el reporte, no en el ETL. Este diagnostico debe
-- reflejar el mismo alcance que la fact para que los numeros sean comparables.
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
CREATE INDEX IX_aplicacion_rebzg ON #aplicacion (sociedad, cliente_id, factura_referencia_documento, factura_referencia_ejercicio, factura_referencia_posicion);

-- candidatos "disponibles" por grupo+categoria (excluye los ya consumidos por REBZG)
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

CREATE UNIQUE INDEX IX_grupo_categoria ON #grupo_categoria (sociedad, cliente_id, documento_compensacion, ejercicio_compensacion, tipo_aplicacion);

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
           f.monto_moneda_local - ISNULL(r.monto_resuelto, 0) AS monto_sin_explicar,
           CASE WHEN r.monto_resuelto IS NULL THEN 'Nunca tuvo match' ELSE 'Match parcial' END AS categoria
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
)
SELECT
    categoria,
    CASE
        WHEN ISNULL(max_candidatos_en_grupo, 0) = 0 THEN '0 candidatos disponibles (hueco real)'
        WHEN max_candidatos_en_grupo = 1 AND num_categorias_con_1_disponible >= 2 THEN '1 candidato pero 2+ categorias compitiendo (limitacion conocida del paso 6b)'
        WHEN max_candidatos_en_grupo = 1 THEN '1 candidato disponible (revisar - deberia haber resuelto solo)'
        ELSE '2+ candidatos disponibles (ambiguedad genuina)'
    END AS patron,
    COUNT(*) AS num_facturas,
    SUM(monto_sin_explicar) AS monto_sin_explicar
FROM con_candidatos
GROUP BY categoria,
    CASE
        WHEN ISNULL(max_candidatos_en_grupo, 0) = 0 THEN '0 candidatos disponibles (hueco real)'
        WHEN max_candidatos_en_grupo = 1 AND num_categorias_con_1_disponible >= 2 THEN '1 candidato pero 2+ categorias compitiendo (limitacion conocida del paso 6b)'
        WHEN max_candidatos_en_grupo = 1 THEN '1 candidato disponible (revisar - deberia haber resuelto solo)'
        ELSE '2+ candidatos disponibles (ambiguedad genuina)'
    END
ORDER BY categoria, num_facturas DESC;

DROP TABLE #factura;
DROP TABLE #aplicacion;
DROP TABLE #grupo_categoria;
GO
