USE ANALISIS_DATOS;
GO

/*
========================================================================================
BACKFILL HISTORICO del modelo de aplicacion de pagos  -  2022-01-01 -> hoy
========================================================================================
CORRER BLOQUE POR BLOQUE, revisando la salida de cada uno. No de un jalon.

Volumen esperado:
    gold.fact_facturas compensadas   ~3,198,553   <- el pesado
    gold.fact_facturas abiertas          70,967   (foto, se recarga sola)
    gold.fact_pagos                     ~614,353   (~115-138K por anio)
    gold.fact_aplicacion_pagos        ~3-3.5M
    gold.fact_pagos_sin_aplicacion       ~2-3K

--- POR QUE ESTE ARCHIVO EXISTE, SI YA HAY PROCS ---
gold.load_fact_facturas ignora @fecha_hasta a proposito: en carga incremental el techo
truncaria las cadenas del segundo salto (probado - deja fuera facturas cuyo grupo final
se compensa despues). Pero eso significa que llamarlo con '2022-01-01' haria UN SOLO
INSERT de 3.2M filas, y el log de este servidor son 2 GB. Ya paso en este proyecto:
el corte anual fue lo que permitio terminar la Fase A sin Msg 9002.
Por eso el paso 1 inserta por anio SIN pasar por el proc. Durante un backfill completo
el techo es inofensivo - al terminar estan todos los anios - y protege el log.

--- ORDEN OBLIGATORIO ---
Primero fact_facturas COMPLETA. El puente de cualquier anio necesita las facturas de su
grupo, y un pago de 2022 puede alcanzar una factura por segundo salto en 2023. Si se
corre el puente antes de tener todas las facturas, faltan filas y no avisa.
Despues, anio por anio: pagos -> puente -> sin_aplicacion.

--- SI SE INTERRUMPE ---
Cada bloque es re-ejecutable: los procs borran su ventana antes de insertar. El paso 1
tambien (borra el anio antes de insertarlo). Se puede repetir el anio que quedo a medias
sin duplicar nada.
========================================================================================
*/


-- ========================================================================================
-- PASO 0 - Estado antes de empezar. Guarda esta salida.
-- ========================================================================================
SELECT 'fact_pagos' AS tabla, COUNT(*) AS filas FROM gold.fact_pagos
UNION ALL SELECT 'fact_facturas', COUNT(*) FROM gold.fact_facturas
UNION ALL SELECT 'fact_aplicacion_pagos', COUNT(*) FROM gold.fact_aplicacion_pagos
UNION ALL SELECT 'fact_pagos_sin_aplicacion', COUNT(*) FROM gold.fact_pagos_sin_aplicacion;

SELECT name AS archivo_log, size/128 AS mb_asignado,
       FILEPROPERTY(name,'SpaceUsed')/128 AS mb_usado
FROM sys.database_files WHERE type_desc = 'LOG';
GO


-- ========================================================================================
-- PASO 1 - gold.fact_facturas COMPENSADAS, anio por anio.
--          Correr los cinco bloques uno a la vez, revisando el log entre cada uno.
--          NO usa el proc: ver la nota de la cabecera.
-- ========================================================================================

-- Limpieza del historico compensado, en lotes (el log).
DECLARE @lote INT = 1;
WHILE @lote > 0
BEGIN
    DELETE TOP (50000) FROM gold.fact_facturas WHERE flag_compensada = 1;
    SET @lote = @@ROWCOUNT;
END
PRINT 'Historico compensado limpiado.';
GO

-- ---- 2022 ---- (repetir cambiando las dos fechas para 2023, 2024, 2025, 2026)
INSERT INTO gold.fact_facturas (
    sociedad, cliente_id, ejercicio, documento_id, posicion,
    documento_compensacion, ejercicio_compensacion, clase_documento,
    fecha_documento, fecha_vencimiento, fecha_contabilizacion, fecha_compensacion,
    monto, clave_contabilizacion, flag_compensada,
    cliente_comercial_sk, cliente_credito_sk)
SELECT b.sociedad, b.cliente_id, b.ejercicio, b.documento_id, b.posicion,
       b.documento_compensacion, b.ejercicio_compensacion, b.clase_documento,
       b.fecha_documento, b.fecha_vencimiento, b.fecha_contabilizacion, b.fecha_compensacion,
       b.monto_moneda_local, b.clave_contabilizacion, 1,
       dcc.id_surrogate, dck.id_surrogate
FROM silver.sap_bsad b
LEFT JOIN gold.dim_cliente_comercial dcc
       ON dcc.cliente_id = b.cliente_id
      AND b.fecha_contabilizacion >= dcc.fecha_inicio_vigencia
      AND (dcc.fecha_fin_vigencia IS NULL OR b.fecha_contabilizacion <= dcc.fecha_fin_vigencia)
LEFT JOIN gold.dim_cliente_credito dck
       ON dck.cliente_id = b.cliente_id
      AND b.fecha_contabilizacion >= dck.fecha_inicio_vigencia
      AND (dck.fecha_fin_vigencia IS NULL OR b.fecha_contabilizacion <= dck.fecha_fin_vigencia)
WHERE b.mandante = '400'
  AND b.debe_haber = 'S'
  AND (b.clase_documento LIKE 'F%' OR b.clase_documento = 'D1')
  AND b.fecha_compensacion >= '2022-01-01'
  AND b.fecha_compensacion <  '2023-01-01'
  AND b.cliente_id IN (
        SELECT c1.cliente_id FROM gold.dim_cliente_comercial c1
        WHERE c1.estatus_comercial <> 'FUERA_DE_ALCANCE'
          AND c1.canal_distribucion IN (10, 40, 60))
  -- Reset de compensacion (FBRA): gana bsid, que es el estado de hoy.
  AND NOT EXISTS (
        SELECT 1 FROM silver.sap_bsid i
        WHERE i.mandante = b.mandante AND i.sociedad = b.sociedad
          AND i.cliente_id = b.cliente_id AND i.ejercicio = b.ejercicio
          AND i.documento_id = b.documento_id AND i.posicion = b.posicion);
PRINT '2022 compensadas: ' + CAST(@@ROWCOUNT AS VARCHAR(12));
GO

-- Entre anio y anio, revisar el log. Si pasa de ~1,200 MB, hacer CHECKPOINT y esperar.
SELECT FILEPROPERTY('ANALISIS_DATOS_log','SpaceUsed')/128 AS log_mb_usado;
GO


-- ========================================================================================
-- PASO 2 - las ABIERTAS. Una sola vez: es una foto del presente, no tiene anios.
--          Se puede hacer con el proc, que ya las recarga completas.
--          (Ojo: el proc tambien recargaria las compensadas desde @fecha_desde. Para
--           evitarlo, este INSERT va directo.)
-- ========================================================================================
DECLARE @lote2 INT = 1;
WHILE @lote2 > 0
BEGIN
    DELETE TOP (50000) FROM gold.fact_facturas WHERE flag_compensada = 0;
    SET @lote2 = @@ROWCOUNT;
END

INSERT INTO gold.fact_facturas (
    sociedad, cliente_id, ejercicio, documento_id, posicion,
    documento_compensacion, ejercicio_compensacion, clase_documento,
    fecha_documento, fecha_vencimiento, fecha_contabilizacion, fecha_compensacion,
    monto, clave_contabilizacion, flag_compensada,
    cliente_comercial_sk, cliente_credito_sk)
SELECT b.sociedad, b.cliente_id, b.ejercicio, b.documento_id, b.posicion,
       NULL, NULL, b.clase_documento,
       b.fecha_documento, b.fecha_vencimiento, b.fecha_contabilizacion, NULL,
       b.monto_moneda_local, b.clave_contabilizacion, 0,
       dcc.id_surrogate, dck.id_surrogate
FROM silver.sap_bsid b
LEFT JOIN gold.dim_cliente_comercial dcc
       ON dcc.cliente_id = b.cliente_id
      AND b.fecha_contabilizacion >= dcc.fecha_inicio_vigencia
      AND (dcc.fecha_fin_vigencia IS NULL OR b.fecha_contabilizacion <= dcc.fecha_fin_vigencia)
LEFT JOIN gold.dim_cliente_credito dck
       ON dck.cliente_id = b.cliente_id
      AND b.fecha_contabilizacion >= dck.fecha_inicio_vigencia
      AND (dck.fecha_fin_vigencia IS NULL OR b.fecha_contabilizacion <= dck.fecha_fin_vigencia)
WHERE b.mandante = '400'
  AND b.debe_haber = 'S'
  AND (b.clase_documento LIKE 'F%' OR b.clase_documento = 'D1')
  AND b.cliente_id IN (
        SELECT c1.cliente_id FROM gold.dim_cliente_comercial c1
        WHERE c1.estatus_comercial <> 'FUERA_DE_ALCANCE'
          AND c1.canal_distribucion IN (10, 40, 60));
PRINT 'Abiertas: ' + CAST(@@ROWCOUNT AS VARCHAR(12)) + ' (esperado ~70,967)';
GO

-- Control del paso 1+2 antes de seguir: NO continuar si esto no cuadra.
SELECT flag_compensada, COUNT(*) AS filas FROM gold.fact_facturas GROUP BY flag_compensada;
-- esperado: 0 -> ~70,967   |   1 -> ~3,198,553
GO


-- ========================================================================================
-- PASO 3 - pagos, puente y sin_aplicacion, ANIO POR ANIO.
--          Correr un anio completo (los tres EXEC) antes de pasar al siguiente.
--          Aqui SI se usan los procs: ellos borran su ventana antes de insertar, asi que
--          repetir un anio es seguro.
-- ========================================================================================

-- ---- 2022 ----
EXEC gold.load_fact_pagos                '2022-01-01', '2023-01-01';
EXEC gold.load_fact_aplicacion_pagos     '2022-01-01', '2023-01-01';
EXEC gold.load_fact_pagos_sin_aplicacion '2022-01-01', '2023-01-01';
GO
SELECT FILEPROPERTY('ANALISIS_DATOS_log','SpaceUsed')/128 AS log_mb_usado;
GO

-- ---- 2023 ----
EXEC gold.load_fact_pagos                '2023-01-01', '2024-01-01';
EXEC gold.load_fact_aplicacion_pagos     '2023-01-01', '2024-01-01';
EXEC gold.load_fact_pagos_sin_aplicacion '2023-01-01', '2024-01-01';
GO
SELECT FILEPROPERTY('ANALISIS_DATOS_log','SpaceUsed')/128 AS log_mb_usado;
GO

-- ---- 2024 ----
EXEC gold.load_fact_pagos                '2024-01-01', '2025-01-01';
EXEC gold.load_fact_aplicacion_pagos     '2024-01-01', '2025-01-01';
EXEC gold.load_fact_pagos_sin_aplicacion '2024-01-01', '2025-01-01';
GO
SELECT FILEPROPERTY('ANALISIS_DATOS_log','SpaceUsed')/128 AS log_mb_usado;
GO

-- ---- 2025 ----
EXEC gold.load_fact_pagos                '2025-01-01', '2026-01-01';
EXEC gold.load_fact_aplicacion_pagos     '2025-01-01', '2026-01-01';
EXEC gold.load_fact_pagos_sin_aplicacion '2025-01-01', '2026-01-01';
GO
SELECT FILEPROPERTY('ANALISIS_DATOS_log','SpaceUsed')/128 AS log_mb_usado;
GO

-- ---- 2026 ---- (sin tope: hasta hoy)
EXEC gold.load_fact_pagos                '2026-01-01';
EXEC gold.load_fact_aplicacion_pagos     '2026-01-01';
EXEC gold.load_fact_pagos_sin_aplicacion '2026-01-01';
GO


-- ========================================================================================
-- PASO 4 - VALIDACION FINAL. Las cinco tienen que pasar.
-- ========================================================================================
SELECT 'A. total fact_pagos' AS invariante,
       CAST(CAST(SUM(monto) AS DECIMAL(18,2)) AS VARCHAR(24)) AS valor
FROM gold.fact_pagos
UNION ALL
SELECT 'B. ligado a facturas',
       CAST(CAST(SUM(p.monto) AS DECIMAL(18,2)) AS VARCHAR(24))
FROM gold.fact_pagos p
WHERE EXISTS (SELECT 1 FROM gold.fact_aplicacion_pagos a
              WHERE a.sociedad=p.sociedad AND a.ejercicio_pago=p.ejercicio
                AND a.pago_id=p.documento_id AND a.posicion_pago=p.posicion)
UNION ALL
SELECT 'C. sin aplicacion',
       CAST(CAST(SUM(p.monto) AS DECIMAL(18,2)) AS VARCHAR(24))
FROM gold.fact_pagos p
JOIN gold.fact_pagos_sin_aplicacion s
  ON s.sociedad=p.sociedad AND s.ejercicio=p.ejercicio
 AND s.documento_id=p.documento_id AND s.posicion=p.posicion
UNION ALL
SELECT 'D. pagos en AMBAS tablas (debe ser 0)',
       CAST(COUNT(*) AS VARCHAR(24))
FROM gold.fact_pagos p
WHERE EXISTS (SELECT 1 FROM gold.fact_aplicacion_pagos a
              WHERE a.sociedad=p.sociedad AND a.ejercicio_pago=p.ejercicio
                AND a.pago_id=p.documento_id AND a.posicion_pago=p.posicion)
  AND EXISTS (SELECT 1 FROM gold.fact_pagos_sin_aplicacion s
              WHERE s.sociedad=p.sociedad AND s.ejercicio=p.ejercicio
                AND s.documento_id=p.documento_id AND s.posicion=p.posicion)
UNION ALL
SELECT 'E. pagos sin clasificar (debe ser 0)',
       CAST(COUNT(*) AS VARCHAR(24))
FROM gold.fact_pagos p
WHERE NOT EXISTS (SELECT 1 FROM gold.fact_aplicacion_pagos a
                  WHERE a.sociedad=p.sociedad AND a.ejercicio_pago=p.ejercicio
                    AND a.pago_id=p.documento_id AND a.posicion_pago=p.posicion)
  AND NOT EXISTS (SELECT 1 FROM gold.fact_pagos_sin_aplicacion s
                  WHERE s.sociedad=p.sociedad AND s.ejercicio=p.ejercicio
                    AND s.documento_id=p.documento_id AND s.posicion=p.posicion)
UNION ALL
SELECT 'F. etiqueta REVISAR (debe ser 0)',
       CAST(COUNT(*) AS VARCHAR(24))
FROM gold.fact_pagos_sin_aplicacion WHERE motivo = 'REVISAR';
-- B + C tiene que dar exactamente A.
GO

-- Cobertura por anio: sirve para ver si algun anio se comporta distinto.
SELECT YEAR(p.fecha_compensacion) AS anio,
       COUNT(*) AS pagos,
       CAST(SUM(p.monto) AS DECIMAL(18,2)) AS total,
       CAST(SUM(CASE WHEN a.pago_id IS NOT NULL THEN p.monto ELSE 0 END) AS DECIMAL(18,2)) AS ligado
FROM gold.fact_pagos p
LEFT JOIN (SELECT DISTINCT sociedad, ejercicio_pago, pago_id, posicion_pago
           FROM gold.fact_aplicacion_pagos) a
       ON a.sociedad=p.sociedad AND a.ejercicio_pago=p.ejercicio
      AND a.pago_id=p.documento_id AND a.posicion_pago=p.posicion
GROUP BY YEAR(p.fecha_compensacion)
ORDER BY anio;
GO
