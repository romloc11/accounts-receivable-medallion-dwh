USE ANALISIS_DATOS;
GO

/*
SUPERADO 2026-08-17 para uso regular: la logica de este script ya vive de
forma oficial en gold.load_fact_aplicacion_pagos (sp_load_gold.sql, ventana
incremental mes actual+anterior automatica). Este archivo se conserva como
referencia historica del script original acotado a jun-jul 2026, no lo uses
para refrescar la fact - usa el procedimiento.

Poblado de PRUEBA de gold.fact_aplicacion_pagos, acotado a facturas compensadas en
junio-julio 2026 (fecha_compensacion). Idempotente (DELETE del rango + INSERT).

Match en 3 niveles (ver ddl_gold.sql, seccion 6, para el detalle completo):
  1. REBZG directo (factura_referencia_documento/ejercicio/posicion)
  2. Grupo de compensacion con EXACTAMENTE 1 aplicacion de esa categoria (sin
     importar cuantas facturas tenga el grupo - confirmado 2026-08-13 con 3
     ejemplos reales de SAP: cuando solo hay 1 fuente de pago posible para todo
     el grupo, no hay ambiguedad aunque haya varias facturas).
  3. Sin match preciso (factura aparece con columnas de aplicacion en NULL)

APLICACIONES PARCIALES (2026-08-14): una factura puede terminar con VARIAS
filas en el fact - una por cada pago/NC/devolucion/ajuste que la cubrio
parcialmente. El nivel 1 (REBZG) ya puede insertar mas de una fila por factura
si hay varias lineas referenciandola (ej. varias notas de credito parciales).
El nivel 2 ahora opera sobre el SALDO PENDIENTE de cada factura (monto_factura
menos lo ya aplicado en nivel 1), no sobre el monto completo - asi que si una
factura quedo parcialmente resuelta por REBZG, el resto de su saldo todavia
puede resolverse en el nivel 2 en vez de perderse. El nivel 3 (sin match) se
recalcula al final contra lo que de verdad quedo pendiente tras los 2 niveles
anteriores, y puede coexistir con filas ya resueltas de la MISMA factura (ej.
$5,083.69 resueltos por REBZG + una fila NULL de "$4,312.83 sin explicar" si
el resto del grupo resulto ambiguo). Caso real que motivo esto: factura
7404563558 (cliente 10000914, grupo 1402608890) - pago parcial de $5,083.69
via REBZG contra una factura de $9,396.52; el resto se explicaba por un virgen
de $35,000 que antes quedaba invisible porque la factura ya se daba por
"resuelta" con el primer match encontrado.

CAMBIO IMPORTANTE 2026-08-13 en el filtro de PAGO/DZ: ya NO se excluyen las
lineas DZ con sgtxt poblado. Antes se excluian pensando que sgtxt = "es un
deposito virgen, no una aplicacion real" - pero se confirmo con SAP que a veces
el "virgen" (con sgtxt='Asignación Aut. Deposito' U OTRO texto como
'INVOICE EGDL - <factura>') es DIRECTAMENTE la unica fuente de pago del grupo,
sin que exista una linea 'H' separada de aplicacion dentro del hijo. Ahora el
unico filtro es debe_haber<>'S' (excluye solo la pierna de "recepcion" del
traspaso) - el conteo de num_aplicaciones por grupo ya distingue solo por si
mismo los casos ambiguos (grupo con 2+ candidatos H) de los inambiguos (1 solo).

fecha_pago = COALESCE(virgen.fecha_pago, aplicacion.fecha_documento): intenta
rastrear un virgen mas arriba en la cadena (patron con hijo intermedio); si no
encuentra ninguno, usa la fecha propia de la aplicacion resuelta directamente -
esto cubre tanto CP/ZY (nunca tienen virgen, es su propia fecha) como los casos
donde la aplicacion resuelta YA es el virgen mismo (no hay nada mas arriba que
rastrear).
*/

DECLARE @fecha_inicio DATE = '20260601';
DECLARE @fecha_fin    DATE = '20260731';

DELETE FROM gold.fact_aplicacion_pagos
WHERE fecha_compensacion BETWEEN @fecha_inicio AND @fecha_fin;

-- Paso 1: facturas del rango, TODOS los canales (2026-08-17, revertido -
-- el filtro de canal 10/40/60 vivio aqui brevemente el 2026-08-14 pero se
-- decidio que el alcance de negocio "solo mayoreo" pertenece a la CAPA DE
-- REPORTE, no al ETL - asi el alcance se puede ajustar (agregar/quitar
-- canales, comparar mayoreo vs menudeo) sin tener que re-disenar y
-- re-correr todo el pipeline cada vez, como paso con este mismo cambio.
-- La fact queda completa; quien construya el reporte de pagos filtra por
-- dim_cliente_comercial.canal_distribucion en su propia consulta/vista.
IF OBJECT_ID('tempdb..#factura') IS NOT NULL DROP TABLE #factura;
SELECT *
INTO #factura
FROM silver.sap_bsad
WHERE clase_documento IN ('F1','F2','F3','F4','F5','F6')
  AND fecha_compensacion BETWEEN @fecha_inicio AND @fecha_fin;

-- Indices sobre las tablas temporales (SELECT INTO no crea ninguno) - sin esto
-- cada join de los pasos siguientes hace table scan completo.
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
-- ANULACION (Z1=anulacion factura, Z2=anulacion devolucion, Z3=anulacion NC)
-- agregado 2026-08-13: confirmado con 2 ejemplos reales que ~34% de lo que
-- parecia "sin match" eran en realidad facturas CANCELADAS (Z1 neteando exacto
-- contra la factura, no un pago pendiente de resolver) - se catalogan aparte
-- en vez de mezclarse con la ambiguedad genuina.
-- 2026-08-13: debe_haber<>'S' aplica SOLO a DZ. Se confirmo con 2 ejemplos
-- reales de SAP (grupos 8501571419 y 8501571428) que AJUSTE (AB) TAMBIEN tiene
-- el patron virgen->hijo (fuente 'H' -> hijo self-referencing 'S') - pero
-- filtrar AB por debe_haber<>'S' empeoro el resultado total (AJUSTE/
-- GRUPO_INAMBIGUO bajo de 1084 a 787), porque a diferencia de DZ, en AB
-- tambien existen ajustes 'S' legitimos y AUTONOMOS (no residuo de ningun
-- hijo) que el filtro excluye por error - mismo problema que se vio primero
-- con NOTA_DEBITO. AB tiene semantica mixta (a veces H=fuente/S=hijo, a veces
-- S=ajuste real) y debe_haber solo no alcanza para distinguirlos con
-- seguridad - se necesitaria una señal mas precisa (ej. documento_id =
-- documento_compensacion, self-referencia, en vez de solo debe_haber) para
-- separar el hijo residual del ajuste autonomo. No investigado mas a fondo -
-- el impacto (unas ~300 facturas en el rango de prueba) no justifico seguir
-- por ahora dado que AJUSTE no es el foco del analisis de comportamiento de pago.

CREATE INDEX IX_aplicacion_rebzg ON #aplicacion (sociedad, cliente_id, factura_referencia_documento, factura_referencia_ejercicio, factura_referencia_posicion);
CREATE INDEX IX_aplicacion_grupo_tipo ON #aplicacion (sociedad, cliente_id, documento_compensacion, ejercicio_compensacion, tipo_aplicacion);
CREATE INDEX IX_aplicacion_hijo ON #aplicacion (sociedad, cliente_id, documento_id, ejercicio);

-- Paso 3: conteo de aplicaciones por grupo+tipo, separando "propias" (documento_id
-- = documento_compensacion, ej. la linea H que el propio hijo genera para
-- aplicar contra las facturas) de "externas" (ej. un virgen cuyo
-- documento_compensacion apunta al grupo desde otro documento). Una propia
-- SIEMPRE gana sobre una externa cuando ambas existen en el mismo grupo - caso
-- real confirmado 2026-08-13 (grupo 1402632719): el virgen 1402632625 y la
-- propia linea H del hijo (pos 3) coexistian, y contar las 2 como candidatos
-- volvia ambiguo un grupo que en realidad se resolvia con la propia (cuadra
-- exacto con las 3 facturas). Sin esta distincion, el fix que agrego los
-- "virgenes directos" (ver nota arriba) rompe estos casos de patron normal.
-- 2026-08-14: se excluyen del conteo las lineas cuyo REBZG apunta a una
-- factura REAL de este conjunto (o sea, que de verdad se consumio en el nivel
-- 1) - esas ya estan comprometidas por completo, y no deberian competir como
-- "candidato disponible" para las demas facturas del grupo. Caso real: grupo
-- 1402608890, cliente 10000914 - el pago parcial 1402602648 ($5,083.69) ya
-- tiene REBZG hacia la factura 7404563558; sin excluirlo, contaba como un
-- candidato externo mas junto al virgen 1402607195 ($35,000), volviendo
-- ambiguas (num_externas=2) las otras 4 facturas del grupo que en realidad
-- solo tenian al virgen como candidato disponible.
-- OJO: NO basta con "factura_referencia_documento IS NULL" a secas (primer
-- intento, revertido) - varias categorias (ej. ANULACION/Z1) traen REBZG
-- poblado apuntando a algo que NO es una factura real de este conjunto (otra
-- referencia interna de SAP sin relacion con esta compensacion especifica).
-- Excluir por "tiene CUALQUIER REBZG" tiro candidatos validos que el nivel 1
-- nunca iba a consumir de todas formas, rompiendo GRUPO_INAMBIGUO en masa
-- (paso de 9,212 a 49,623 facturas sin match). La condicion correcta es "su
-- REBZG apunta a una factura que SI existe en #factura".
-- 2026-08-14 (parte 3, PROBADO Y REVERTIDO): se intento exigir ADEMAS que la
-- factura referenciada por REBZG estuviera en el MISMO grupo de compensacion
-- que el candidato, motivado por un caso real verificado en SAP (grupo
-- 8501577332/factura 7503011679 - un C4 con REBZG apuntando, aparentemente
-- desactualizado, a una factura de otro grupo). Ese cambio causo una
-- REGRESION grande al volver a correr el poblado completo: "Nunca tuvo
-- match/2+ candidatos" subio de 6,027 ($4.08M) a 9,565 ($6.01M) - resulto que
-- el supuesto "un REBZG correcto siempre comparte grupo con su factura" NO es
-- universal, rompio muchos matches de Nivel 1 legitimos que si son correctos
-- sin compartir grupo. Revertido. El caso 8501577332 se deja como una
-- inconsistencia aislada de datos en SAP (REBZG desactualizado), no una regla
-- general - no perseguir de nuevo sin evidencia de que sea un patron amplio,
-- no un caso unico.
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

-- Paso 3b: quedarse solo con grupos donde EXACTAMENTE 1 categoria es
-- inambigua en total - fix 2026-08-18. La "LIMITACION CONOCIDA" documentada
-- originalmente en el Paso 6b (2+ categorias distintas, ambas inambiguas,
-- compitiendo por el mismo saldo pendiente) se creyo "rara" en el rango de
-- prueba jun-jul 2026, pero medida contra el historico completo (2024-hoy)
-- resulto afectar 178,024 facturas (~6% del total) - ver
-- backfill_fact_aplicacion_pagos.sql para el caso real que la expuso.
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
-- del rango de prueba, porque el virgen puede haberse compensado antes o
-- despues de las facturas que en definitiva pago.
-- FIX 2026-08-18: excluir hijos con 2+ virgenes candidatos - ver
-- backfill_fact_aplicacion_pagos.sql para el caso real que expuso el bug.
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

-- Paso 5: NIVEL 1 - match directo via REBZG
-- id_cliente_comercial/id_cliente_credito (2026-08-17): join temporal contra
-- las dims SCD2 usando f.fecha_compensacion, mismo patron ya usado en
-- gold.load_fact_saldo_cartera - NUNCA "canal actual", siempre vigente a la
-- fecha real del movimiento.
-- FIX 2026-08-18: prioriza candidatos del MISMO grupo de compensacion que la
-- factura sobre candidatos de otro grupo; solo usa candidatos de otro grupo
-- si no hay ninguno del propio - ver backfill_fact_aplicacion_pagos.sql para
-- el caso real (factura 7403699099 sobre-resuelta por un REBZG de otro
-- grupo encima de 2 candidatos de su propio grupo que ya la explicaban exacto).
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

-- Paso 6a: SALDO PENDIENTE por factura despues del nivel 1 - antes, una
-- factura resuelta (aunque fuera PARCIAL) por REBZG quedaba excluida del
-- nivel 2 por completo, perdiendo el resto del pago. Ahora se calcula cuanto
-- le falta (monto_factura - lo ya aplicado) y esa es la base para seguir
-- resolviendo - aplica igual a facturas con 0 aplicaciones (saldo pendiente =
-- monto completo) que a las que ya tienen algo de REBZG (saldo pendiente =
-- lo que falta). Caso real 2026-08-14: factura 7404563558 ($9,396.52) con un
-- pago parcial de $5,083.69 via REBZG - el saldo pendiente ($4,312.83) ahora
-- puede resolverse en el nivel 2 en vez de quedar perdido.
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
WHERE f.monto_moneda_local - ISNULL(r.monto_resuelto, 0) > 1.00  -- tolerancia $1 (confirmado 2026-08-14: residuos <=$1 son ruido sistematico de descuentos pronto-pago via pares de AB ambiguos, no casos reales por investigar - ver caso cliente 10000876/factura 7404602049)
   OR r.monto_resuelto IS NULL;  -- 2026-08-17: la tolerancia SOLO debe suprimir el SOBRANTE de una factura que YA tuvo algo de match - una factura que NUNCA tuvo ningun match (r.monto_resuelto NULL) debe seguir avanzando a nivel 2 sin importar que tan chica sea, si no desaparece de la fact sin dejar rastro (bug real encontrado en la reconciliacion del backfill: 2,749 facturas <=$1 desaparecieron por completo, $235.59 en total - ver diagnostico_facturas_faltantes_backfill.sql)

CREATE INDEX IX_factura_pendiente_grupo ON #factura_pendiente (sociedad, cliente_id, documento_compensacion, ejercicio_compensacion, documento_id);

-- Paso 6b: NIVEL 2 - grupo de compensacion con exactamente 1 aplicacion
-- disponible de esa categoria (sin importar cuantas facturas tenga el grupo)
-- cubre el SALDO PENDIENTE de cada factura (no el monto completo - si ya
-- tenia parte resuelta por REBZG, solo cubre lo que falta).
-- CORREGIDO 2026-08-18 (ver Paso 3b): si el mismo grupo tiene, al mismo
-- tiempo, un candidato inambiguo en DOS categorias distintas, ninguna se
-- considera segura - se excluyen ambas de #grupo_categoria_unica y la
-- factura cae a Nivel 3 (sin match) en vez de que las dos categorias se
-- lleven el saldo completo cada una.
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
   AND NOT EXISTS (  -- las que su REBZG SI apunta a una factura real quedan fuera (ver nota en #grupo_aplicacion)
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
-- (recalculado desde cero contra gold.fact_aplicacion_pagos, que ya tiene los
-- resultados de ambos niveles anteriores para este rango)
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
WHERE f.monto_moneda_local - ISNULL(r.monto_resuelto, 0) > 1.00  -- misma tolerancia $1 que el paso 6a, ver nota ahi
   OR r.monto_resuelto IS NULL;  -- misma correccion 2026-08-17 que el paso 6a - nunca ocultar una factura que jamas tuvo match, sin importar su monto

PRINT 'Nivel 3 (saldo sin explicar): ' + CAST(@@ROWCOUNT AS VARCHAR);

DROP TABLE #factura;
DROP TABLE #aplicacion;
DROP TABLE #grupo_aplicacion;
DROP TABLE #grupo_categoria_unica;
DROP TABLE #virgen;
DROP TABLE #factura_pendiente;
GO
