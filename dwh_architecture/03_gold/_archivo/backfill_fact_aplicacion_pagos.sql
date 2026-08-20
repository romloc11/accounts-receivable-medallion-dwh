USE ANALISIS_DATOS;
GO

/*
Backfill historico de gold.fact_aplicacion_pagos, año por año (mismo patron ya
usado para el backfill de silver.sap_bsad - ver 02_silver/backfill_bsad_historico.sql -
y el de bronze.sap_bsad: corridas manuales por año en SSMS, vigilando Msg 9002
de log lleno, en vez de asumir que un rango grande siempre cabe).

Este script es LA MISMA LOGICA que 03_gold/poblar_fact_aplicacion_pagos_prueba.sql
(3 niveles de match, aplicaciones parciales, tolerancia $1, sin filtro de canal,
resolucion de id_cliente_comercial/id_cliente_credito) - la unica diferencia es
que aqui @fecha_inicio/@fecha_fin se editan a mano entre corrida y corrida en vez
de estar fijos al rango de prueba jun-jul 2026. Si vuelves a ajustar la logica de
matching en poblar_fact_aplicacion_pagos_prueba.sql, replica el cambio aqui
tambien - los dos scripts deben quedarse identicos salvo el rango de fechas.

PLAN DE CORRIDAS (3 chunks, uno a la vez, revisando el PRINT de cada nivel y la
duracion antes de seguir con el siguiente). Alcance decidido 2026-08-17: desde
2024 en adelante, NO desde 2022 - el reporte real solo necesita ventana movil
(dpp_3m/12m, pct_pagos_a_tiempo_*), no historia completa; 2024-2025 da margen
de sobra para comparar periodo-contra-periodo sin pagar el costo de 2 años
adicionales (2022-2023) que ningun reporte planeado va a consultar. Si algun
dia se pide tendencia mas larga, se extiende hacia atras en ese momento:
  1. 2024-01-01 a 2024-12-31 (chunk configurado actualmente abajo)
  2. 2025-01-01 a 2025-12-31
  3. 2026-01-01 a HOY (esto vuelve a procesar jun-jul 2026, que ya estaba
     poblado por el script de prueba - es idempotente, mismo resultado, no hay
     riesgo de duplicar ni de dejar un hueco en el limite del rango de prueba)

Si un año completo se ve pesado/lento o truena con Msg 9002 (log lleno), cortar
ese chunk en semestres o trimestres - mismo fallback que se uso con bsad.

Recuerda actualizar @fecha_fin del chunk 5 al dia de hoy real antes de correrlo
(no queda fijo aqui porque cambia cada vez que se corre este backfill).
*/

DECLARE @fecha_inicio DATE = '20240101';
DECLARE @fecha_fin    DATE = '20241231';

DELETE FROM gold.fact_aplicacion_pagos
WHERE fecha_compensacion BETWEEN @fecha_inicio AND @fecha_fin;

-- Paso 1: facturas del rango, TODOS los canales - el alcance de negocio
-- (ej. solo mayoreo 10/40/60) se filtra en el reporte, no aqui.
IF OBJECT_ID('tempdb..#factura') IS NOT NULL DROP TABLE #factura;
SELECT *
INTO #factura
FROM silver.sap_bsad
WHERE clase_documento IN ('F1','F2','F3','F4','F5','F6')
  AND fecha_compensacion BETWEEN @fecha_inicio AND @fecha_fin;

CREATE INDEX IX_factura_grupo ON #factura (sociedad, cliente_id, documento_compensacion, ejercicio_compensacion, documento_id);

-- Paso 2: candidatos de aplicacion (pago/NC/ND/devolucion/ajuste) del rango
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

CREATE INDEX IX_aplicacion_rebzg ON #aplicacion (sociedad, cliente_id, factura_referencia_documento, factura_referencia_ejercicio, factura_referencia_posicion);
CREATE INDEX IX_aplicacion_grupo_tipo ON #aplicacion (sociedad, cliente_id, documento_compensacion, ejercicio_compensacion, tipo_aplicacion);
CREATE INDEX IX_aplicacion_hijo ON #aplicacion (sociedad, cliente_id, documento_id, ejercicio);

-- Paso 3: conteo de aplicaciones por grupo+tipo (propias vs externas),
-- excluyendo candidatos cuyo REBZG ya apunta a una factura real de este
-- conjunto (ver poblar_fact_aplicacion_pagos_prueba.sql para el historial
-- completo de por que esta logica quedo asi, incluyendo el intento de
-- "mismo grupo" probado y revertido el 2026-08-14).
IF OBJECT_ID('tempdb..#grupo_aplicacion') IS NOT NULL DROP TABLE #grupo_aplicacion;
SELECT
    a.sociedad, a.cliente_id, a.documento_compensacion, a.ejercicio_compensacion, a.tipo_aplicacion,
    SUM(CASE WHEN a.documento_id = a.documento_compensacion AND a.ejercicio = a.ejercicio_compensacion THEN 1 ELSE 0 END) AS num_propias,
    SUM(CASE WHEN NOT (a.documento_id = a.documento_compensacion AND a.ejercicio = a.ejercicio_compensacion) THEN 1 ELSE 0 END) AS num_externas
INTO #grupo_aplicacion
FROM #aplicacion a
WHERE NOT EXISTS (
    SELECT 1 FROM #factura f
    WHERE f.sociedad = a.sociedad AND f.cliente_id = a.cliente_id
      AND f.documento_id = a.factura_referencia_documento
      AND f.ejercicio = a.factura_referencia_ejercicio
      AND f.posicion = a.factura_referencia_posicion
)
GROUP BY a.sociedad, a.cliente_id, a.documento_compensacion, a.ejercicio_compensacion, a.tipo_aplicacion;

CREATE UNIQUE INDEX IX_grupo_aplicacion ON #grupo_aplicacion (sociedad, cliente_id, documento_compensacion, ejercicio_compensacion, tipo_aplicacion);

-- Paso 3b: de los grupos con una categoria inambigua (num_propias=1 o
-- num_externas=1 en solitario), quedarse SOLO con los grupos donde esa
-- condicion se cumple para EXACTAMENTE 1 categoria en total. Bug real
-- encontrado 2026-08-18 en la revision de datos: cuando un grupo tenia, por
-- ejemplo, 1 PAGO inambiguo Y 1 NOTA_CREDITO inambigua AL MISMO TIEMPO, el
-- diseño anterior dejaba que Nivel 2 le asignara el SALDO PENDIENTE COMPLETO
-- a AMBAS categorias por separado (2 INSERTs de la misma factura, cada uno
-- con el monto completo) - la "limitacion conocida" documentada desde el
-- 2026-08-14 como "caso raro, aceptado por ahora" resulto afectar 178,024
-- facturas (~6% de toda la historia 2024-hoy) una vez medido a escala real,
-- no un caso raro. Caso real: factura 7404825851 (cliente 40000300, grupo
-- 1402624033, $623.00) resuelta DOS veces via GRUPO_INAMBIGUO - una vez por
-- NOTA_CREDITO (C5) y otra por PAGO (DZ), sumando $1,246 contra una factura
-- de $623. Si 2+ categorias compiten por el mismo grupo, ninguna es
-- realmente segura - se tratan como ambiguas (quedan fuera de Nivel 2,
-- caen a Nivel 3 sin match) en vez de que ambas se lo lleven completo.
IF OBJECT_ID('tempdb..#grupo_categoria_unica') IS NOT NULL DROP TABLE #grupo_categoria_unica;
SELECT ga.sociedad, ga.cliente_id, ga.documento_compensacion, ga.ejercicio_compensacion, ga.tipo_aplicacion, ga.num_propias, ga.num_externas
INTO #grupo_categoria_unica
FROM #grupo_aplicacion ga
WHERE (ga.num_propias = 1 OR (ga.num_propias = 0 AND ga.num_externas = 1))
  AND 1 = (
      SELECT COUNT(*) FROM #grupo_aplicacion ga2
      WHERE ga2.sociedad = ga.sociedad AND ga2.cliente_id = ga.cliente_id
        AND ga2.documento_compensacion = ga.documento_compensacion AND ga2.ejercicio_compensacion = ga.ejercicio_compensacion
        AND (ga2.num_propias = 1 OR (ga2.num_propias = 0 AND ga2.num_externas = 1))
  );

CREATE UNIQUE INDEX IX_grupo_categoria_unica ON #grupo_categoria_unica (sociedad, cliente_id, documento_compensacion, ejercicio_compensacion, tipo_aplicacion);

-- Paso 4: pagos "virgen" (deposito original) - SIN acotar a fecha_compensacion
-- del rango de este chunk, porque el virgen puede haberse compensado en OTRO
-- año distinto al de las facturas que en definitiva pago.
-- FIX 2026-08-18: excluir hijos con 2+ virgenes candidatos. documento_compensacion
-- puede ser un LOTE que agrupa varios depositos no relacionados entre si (mismo
-- fenomeno ya visto en el caso del canal 50/grupo 8501577332) - sin este fix, el
-- LEFT JOIN de mas abajo hace fan-out y multiplica cada fila de aplicacion una
-- vez por cada virgen candidato, inflando monto_aplicado (bug real encontrado en
-- la revision de datos: factura 7403116624/cliente 40000052, 3 filas identicas
-- con 3 monto_pago_virgen distintos - $1,507 aplicado 3 veces contra la misma
-- factura). Si 2+ virgenes comparten el mismo hijo, ninguno es seguro - se
-- excluyen ambos, cae de vuelta a la fecha propia de la aplicacion via COALESCE.
IF OBJECT_ID('tempdb..#virgen') IS NOT NULL DROP TABLE #virgen;
SELECT sociedad, cliente_id, documento_hijo, ejercicio_hijo, documento_pago_virgen, fecha_pago, monto_pago_virgen
INTO #virgen
FROM (
    SELECT
        sociedad, cliente_id,
        documento_compensacion AS documento_hijo, ejercicio_compensacion AS ejercicio_hijo,
        documento_id AS documento_pago_virgen, fecha_documento AS fecha_pago, monto_moneda_local AS monto_pago_virgen,
        COUNT(*) OVER (PARTITION BY sociedad, cliente_id, documento_compensacion, ejercicio_compensacion) AS num_virgenes_para_este_hijo
    FROM silver.sap_bsad
    WHERE clase_documento = 'DZ' AND sgtxt = 'Asignación Aut. Deposito'
) x
WHERE num_virgenes_para_este_hijo = 1;

CREATE INDEX IX_virgen_hijo ON #virgen (sociedad, cliente_id, documento_hijo, ejercicio_hijo);

-- Paso 5: NIVEL 1 - match directo via REBZG. Prioriza candidatos que
-- comparten el MISMO grupo de compensacion (documento_compensacion) que la
-- propia factura sobre candidatos de OTRO grupo, cuando ambos existen para
-- la misma factura - solo usa candidatos de otro grupo si la factura NO
-- tiene NINGUN candidato en su propio grupo (evita repetir la regresion del
-- intento "mismo grupo obligatorio para TODOS" del 2026-08-14, que rompio
-- facturas cuyo unico candidato real vivia en otro grupo).
-- FIX 2026-08-18: bug real encontrado en la revision de datos - factura
-- 7403699099 (cliente 10000000, $125,638.65) tenia 2 candidatos REBZG de su
-- propio grupo que sumaban EXACTO el monto de la factura, y un tercer
-- candidato de un grupo totalmente distinto (con REBZG apuntando a esta
-- factura de todas formas, probablemente una referencia vieja/no
-- actualizada) se sumaba encima, sobrando $206.48 - ver
-- diagnostico_sobre_resolucion_rebzg.sql.
INSERT INTO gold.fact_aplicacion_pagos (
    sociedad, cliente_id, documento_factura, ejercicio_factura, posicion_factura, tipo_factura,
    fecha_factura, fecha_vencimiento, monto_factura,
    documento_compensacion, ejercicio_compensacion, fecha_compensacion,
    tipo_aplicacion, documento_aplicado, posicion_aplicado, clase_documento_aplicado, fecha_aplicado, monto_aplicado, metodo_match,
    documento_pago_virgen, fecha_pago, monto_pago_virgen,
    dias_anticipacion_vencimiento,
    id_cliente_comercial, id_cliente_credito
)
SELECT
    f.sociedad, f.cliente_id, f.documento_id, f.ejercicio, f.posicion, f.clase_documento,
    f.fecha_documento, f.fecha_vencimiento, f.monto_moneda_local,
    f.documento_compensacion, f.ejercicio_compensacion, f.fecha_compensacion,
    a.tipo_aplicacion, a.documento_id, a.posicion, a.clase_documento, a.fecha_documento, a.monto_moneda_local, 'REBZG',
    CASE WHEN a.tipo_aplicacion = 'PAGO' THEN COALESCE(v.documento_pago_virgen, a.documento_id) END,
    CASE WHEN a.tipo_aplicacion = 'PAGO' THEN COALESCE(v.fecha_pago, a.fecha_documento) END,
    CASE WHEN a.tipo_aplicacion = 'PAGO' THEN COALESCE(v.monto_pago_virgen, a.monto_moneda_local) END,
    CASE WHEN a.tipo_aplicacion = 'PAGO' AND f.fecha_vencimiento IS NOT NULL
         THEN DATEDIFF(DAY, f.fecha_vencimiento, COALESCE(v.fecha_pago, a.fecha_documento))
    END,
    dc.id_surrogate, dcr.id_surrogate
FROM #factura f
JOIN #aplicacion a
    ON a.sociedad = f.sociedad AND a.cliente_id = f.cliente_id
   AND a.factura_referencia_documento = f.documento_id
   AND a.factura_referencia_ejercicio = f.ejercicio
   AND a.factura_referencia_posicion = f.posicion
   AND (
        (a.documento_compensacion = f.documento_compensacion AND a.ejercicio_compensacion = f.ejercicio_compensacion)
        OR NOT EXISTS (
            SELECT 1 FROM #aplicacion a2
            WHERE a2.sociedad = f.sociedad AND a2.cliente_id = f.cliente_id
              AND a2.factura_referencia_documento = f.documento_id
              AND a2.factura_referencia_ejercicio = f.ejercicio
              AND a2.factura_referencia_posicion = f.posicion
              AND a2.documento_compensacion = f.documento_compensacion
              AND a2.ejercicio_compensacion = f.ejercicio_compensacion
        )
       )
LEFT JOIN #virgen v
    ON v.sociedad = a.sociedad AND v.cliente_id = a.cliente_id
   AND v.documento_hijo = a.documento_id AND v.ejercicio_hijo = a.ejercicio
LEFT JOIN gold.dim_cliente_comercial dc
    ON dc.cliente_id = f.cliente_id
   AND f.fecha_compensacion BETWEEN dc.fecha_inicio_vigencia AND ISNULL(dc.fecha_fin_vigencia, '99991231')
LEFT JOIN gold.dim_cliente_credito dcr
    ON dcr.cliente_id = f.cliente_id
   AND f.fecha_compensacion BETWEEN dcr.fecha_inicio_vigencia AND ISNULL(dcr.fecha_fin_vigencia, '99991231');

PRINT 'Nivel 1 (REBZG): ' + CAST(@@ROWCOUNT AS VARCHAR);

-- Paso 6a: SALDO PENDIENTE por factura despues del nivel 1
IF OBJECT_ID('tempdb..#factura_pendiente') IS NOT NULL DROP TABLE #factura_pendiente;
SELECT
    f.sociedad, f.cliente_id, f.documento_id, f.ejercicio, f.posicion, f.clase_documento,
    f.fecha_documento, f.fecha_vencimiento, f.monto_moneda_local,
    f.documento_compensacion, f.ejercicio_compensacion, f.fecha_compensacion,
    f.monto_moneda_local - ISNULL(r.monto_resuelto, 0) AS monto_pendiente
INTO #factura_pendiente
FROM #factura f
LEFT JOIN (
    SELECT sociedad, cliente_id, documento_factura, ejercicio_factura, posicion_factura, SUM(monto_aplicado) AS monto_resuelto
    FROM gold.fact_aplicacion_pagos
    WHERE fecha_compensacion BETWEEN @fecha_inicio AND @fecha_fin AND tipo_aplicacion IS NOT NULL
    GROUP BY sociedad, cliente_id, documento_factura, ejercicio_factura, posicion_factura
) r ON r.sociedad = f.sociedad AND r.cliente_id = f.cliente_id AND r.documento_factura = f.documento_id
   AND r.ejercicio_factura = f.ejercicio AND r.posicion_factura = f.posicion
WHERE f.monto_moneda_local - ISNULL(r.monto_resuelto, 0) > 1.00  -- tolerancia $1, ver poblar_fact_aplicacion_pagos_prueba.sql
   OR r.monto_resuelto IS NULL;  -- 2026-08-17: nunca ocultar una factura que jamas tuvo match, sin importar su monto - ver diagnostico_facturas_faltantes_backfill.sql

CREATE INDEX IX_factura_pendiente_grupo ON #factura_pendiente (sociedad, cliente_id, documento_compensacion, ejercicio_compensacion, documento_id);

-- Paso 6b: NIVEL 2 - grupo de compensacion con exactamente 1 aplicacion
-- disponible de esa categoria, cubre el SALDO PENDIENTE de cada factura.
INSERT INTO gold.fact_aplicacion_pagos (
    sociedad, cliente_id, documento_factura, ejercicio_factura, posicion_factura, tipo_factura,
    fecha_factura, fecha_vencimiento, monto_factura,
    documento_compensacion, ejercicio_compensacion, fecha_compensacion,
    tipo_aplicacion, documento_aplicado, posicion_aplicado, clase_documento_aplicado, fecha_aplicado, monto_aplicado, metodo_match,
    documento_pago_virgen, fecha_pago, monto_pago_virgen,
    dias_anticipacion_vencimiento,
    id_cliente_comercial, id_cliente_credito
)
SELECT
    f.sociedad, f.cliente_id, f.documento_id, f.ejercicio, f.posicion, f.clase_documento,
    f.fecha_documento, f.fecha_vencimiento, f.monto_moneda_local,
    f.documento_compensacion, f.ejercicio_compensacion, f.fecha_compensacion,
    a.tipo_aplicacion, a.documento_id, a.posicion, a.clase_documento, a.fecha_documento, f.monto_pendiente, 'GRUPO_INAMBIGUO',
    CASE WHEN a.tipo_aplicacion = 'PAGO' THEN COALESCE(v.documento_pago_virgen, a.documento_id) END,
    CASE WHEN a.tipo_aplicacion = 'PAGO' THEN COALESCE(v.fecha_pago, a.fecha_documento) END,
    CASE WHEN a.tipo_aplicacion = 'PAGO' THEN COALESCE(v.monto_pago_virgen, a.monto_moneda_local) END,
    CASE WHEN a.tipo_aplicacion = 'PAGO' AND f.fecha_vencimiento IS NOT NULL
         THEN DATEDIFF(DAY, f.fecha_vencimiento, COALESCE(v.fecha_pago, a.fecha_documento))
    END,
    dc.id_surrogate, dcr.id_surrogate
FROM #factura_pendiente f
JOIN #grupo_categoria_unica ga
    ON ga.sociedad = f.sociedad AND ga.cliente_id = f.cliente_id
   AND ga.documento_compensacion = f.documento_compensacion AND ga.ejercicio_compensacion = f.ejercicio_compensacion
JOIN #aplicacion a
    ON a.sociedad = ga.sociedad AND a.cliente_id = ga.cliente_id
   AND a.documento_compensacion = ga.documento_compensacion AND a.ejercicio_compensacion = ga.ejercicio_compensacion
   AND a.tipo_aplicacion = ga.tipo_aplicacion
   AND NOT EXISTS (
        SELECT 1 FROM #factura f3
        WHERE f3.sociedad = a.sociedad AND f3.cliente_id = a.cliente_id
          AND f3.documento_id = a.factura_referencia_documento
          AND f3.ejercicio = a.factura_referencia_ejercicio
          AND f3.posicion = a.factura_referencia_posicion
   )
   AND (
        (ga.num_propias = 1 AND a.documento_id = a.documento_compensacion AND a.ejercicio = a.ejercicio_compensacion)
        OR
        (ga.num_propias = 0 AND ga.num_externas = 1 AND NOT (a.documento_id = a.documento_compensacion AND a.ejercicio = a.ejercicio_compensacion))
       )
LEFT JOIN #virgen v
    ON v.sociedad = a.sociedad AND v.cliente_id = a.cliente_id
   AND v.documento_hijo = a.documento_id AND v.ejercicio_hijo = a.ejercicio
LEFT JOIN gold.dim_cliente_comercial dc
    ON dc.cliente_id = f.cliente_id
   AND f.fecha_compensacion BETWEEN dc.fecha_inicio_vigencia AND ISNULL(dc.fecha_fin_vigencia, '99991231')
LEFT JOIN gold.dim_cliente_credito dcr
    ON dcr.cliente_id = f.cliente_id
   AND f.fecha_compensacion BETWEEN dcr.fecha_inicio_vigencia AND ISNULL(dcr.fecha_fin_vigencia, '99991231');

PRINT 'Nivel 2 (GRUPO_INAMBIGUO): ' + CAST(@@ROWCOUNT AS VARCHAR);

-- Paso 7: NIVEL 3 - lo que sigue pendiente despues de nivel 1 + nivel 2
INSERT INTO gold.fact_aplicacion_pagos (
    sociedad, cliente_id, documento_factura, ejercicio_factura, posicion_factura, tipo_factura,
    fecha_factura, fecha_vencimiento, monto_factura,
    documento_compensacion, ejercicio_compensacion, fecha_compensacion,
    id_cliente_comercial, id_cliente_credito
)
SELECT
    f.sociedad, f.cliente_id, f.documento_id, f.ejercicio, f.posicion, f.clase_documento,
    f.fecha_documento, f.fecha_vencimiento, f.monto_moneda_local,
    f.documento_compensacion, f.ejercicio_compensacion, f.fecha_compensacion,
    dc.id_surrogate, dcr.id_surrogate
FROM #factura f
LEFT JOIN (
    SELECT sociedad, cliente_id, documento_factura, ejercicio_factura, posicion_factura, SUM(monto_aplicado) AS monto_resuelto
    FROM gold.fact_aplicacion_pagos
    WHERE fecha_compensacion BETWEEN @fecha_inicio AND @fecha_fin AND tipo_aplicacion IS NOT NULL
    GROUP BY sociedad, cliente_id, documento_factura, ejercicio_factura, posicion_factura
) r ON r.sociedad = f.sociedad AND r.cliente_id = f.cliente_id AND r.documento_factura = f.documento_id
   AND r.ejercicio_factura = f.ejercicio AND r.posicion_factura = f.posicion
LEFT JOIN gold.dim_cliente_comercial dc
    ON dc.cliente_id = f.cliente_id
   AND f.fecha_compensacion BETWEEN dc.fecha_inicio_vigencia AND ISNULL(dc.fecha_fin_vigencia, '99991231')
LEFT JOIN gold.dim_cliente_credito dcr
    ON dcr.cliente_id = f.cliente_id
   AND f.fecha_compensacion BETWEEN dcr.fecha_inicio_vigencia AND ISNULL(dcr.fecha_fin_vigencia, '99991231')
WHERE f.monto_moneda_local - ISNULL(r.monto_resuelto, 0) > 1.00
   OR r.monto_resuelto IS NULL;  -- 2026-08-17: nunca ocultar una factura que jamas tuvo match, sin importar su monto - ver diagnostico_facturas_faltantes_backfill.sql

PRINT 'Nivel 3 (saldo sin explicar): ' + CAST(@@ROWCOUNT AS VARCHAR);

DROP TABLE #factura;
DROP TABLE #aplicacion;
DROP TABLE #grupo_aplicacion;
DROP TABLE #grupo_categoria_unica;
DROP TABLE #virgen;
DROP TABLE #factura_pendiente;
GO
