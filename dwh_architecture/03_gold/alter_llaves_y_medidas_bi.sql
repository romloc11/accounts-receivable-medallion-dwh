USE ANALISIS_DATOS;
GO

/*
========================================================================================
LLAVES PARA POWER BI Y MEDIDAS ADITIVAS POR DEFAULT
========================================================================================
Pasos 2 y 3 de la hoja de ruta de docs/architecture/fase0_preguntas.md.

POR QUE:
1. Los tres hechos de documento tienen PK compuesta de 5 columnas
   (sociedad, cliente_id, ejercicio, documento_id, posicion). Power BI NO puede
   construir una relacion sobre una clave compuesta, asi que hoy el modelo
   sencillamente no se puede armar. Estas llaves son el desbloqueo.
   Verificado 2026-09-04: (sociedad, ejercicio, documento_id, posicion) es unica sin
   cliente_id en las tres tablas (0 casos de un mismo documento con 2+ clientes),
   asi que la llave no necesita al cliente.

2. SUM(monto_moneda_local) sobre gold.fact_pagos da un numero muy por encima del real:
   la tabla trae espejos de hijo, traspasos, reversos, reembolsos y cheques devueltos
   ademas del efectivo. Para acertar hay que saberse
   es_efectivo = 1 AND revertido = 0 AND es_reembolso = 0.
   monto_cobranza materializa esa regla - ya documentada en ddl_fact_aplicacion.sql -
   de modo que SUM(monto_cobranza) siempre da bien, sin filtros y sin conocer la
   mecanica de SAP. El numero correcto pasa a ser el que sale por default.

--------------------------------------------------------------------------------------
ANTES DE CORRER
--------------------------------------------------------------------------------------
* NO correr mientras haya una carga en curso. Un ALTER TABLE pide un bloqueo de esquema
  y se va a quedar esperando (o va a bloquear al cargador) sobre tablas de millones de
  filas. Esperar a que termine el backfill.
* Las columnas se crean SIN PERSISTED a proposito: son metadata, se aplican al instante
  y no escriben nada en el log de 2 GB. Persistirlas es una operacion del tamano de los
  datos sobre 4.8M de filas. La variante PERSISTED queda comentada abajo por si algun
  dia la lectura lo pide; los indices de la seccion 4 dan casi el mismo beneficio a un
  costo mucho menor.
* Cada seccion es independiente y re-ejecutable: revisan con COL_LENGTH antes de crear.
========================================================================================
*/


-- ========================================================================================
-- 1. Llaves surrogadas de una sola columna en los hechos de documento
--    Formato unico y compartido: sociedad|ejercicio|documento|posicion
-- ========================================================================================

IF COL_LENGTH('gold.fact_facturas', 'factura_key') IS NULL
    ALTER TABLE gold.fact_facturas ADD factura_key AS
        (sociedad + '|' + CAST(ejercicio AS VARCHAR(4)) + '|' + documento_id + '|' + CAST(posicion AS VARCHAR(6)));
GO

IF COL_LENGTH('gold.fact_notas', 'nota_key') IS NULL
    ALTER TABLE gold.fact_notas ADD nota_key AS
        (sociedad + '|' + CAST(ejercicio AS VARCHAR(4)) + '|' + documento_id + '|' + CAST(posicion AS VARCHAR(6)));
GO

IF COL_LENGTH('gold.fact_pagos', 'pago_key') IS NULL
    ALTER TABLE gold.fact_pagos ADD pago_key AS
        (sociedad + '|' + CAST(ejercicio AS VARCHAR(4)) + '|' + documento_id + '|' + CAST(posicion AS VARCHAR(6)));
GO


-- ========================================================================================
-- 2. Las dos llaves foraneas del puente
--    recibe_key sale NULL en las filas no identificadas: correcto, esas no cuelgan de
--    ninguna factura. El CASE lo hace explicito en vez de depender de
--    CONCAT_NULL_YIELDS_NULL, que es una opcion de sesion.
-- ========================================================================================

IF COL_LENGTH('gold.fact_aplicacion', 'aplica_key') IS NULL
    ALTER TABLE gold.fact_aplicacion ADD aplica_key AS
        (sociedad + '|' + CAST(ejercicio_aplica AS VARCHAR(4)) + '|' + documento_aplica + '|' + CAST(posicion_aplica AS VARCHAR(6)));
GO

IF COL_LENGTH('gold.fact_aplicacion', 'recibe_key') IS NULL
    ALTER TABLE gold.fact_aplicacion ADD recibe_key AS
        (CASE WHEN documento_recibe IS NULL OR ejercicio_recibe IS NULL OR posicion_recibe IS NULL
              THEN NULL
              ELSE sociedad + '|' + CAST(ejercicio_recibe AS VARCHAR(4)) + '|' + documento_recibe + '|' + CAST(posicion_recibe AS VARCHAR(6))
         END);
GO


-- ========================================================================================
-- 3. monto_cobranza - la medida aditiva por default de gold.fact_pagos
--    Misma regla que ya documenta ddl_fact_aplicacion.sql:
--      "Real cash of a period = SUM(monto) WHERE es_efectivo=1 AND revertido=0 AND es_reembolso=0"
--    es_efectivo ya vale 1 solo para origen_efectivo IN (BANCO, DIRECTO, REEMISION_PAGO_SA),
--    asi que esto no inventa logica: la materializa.
-- ========================================================================================

IF COL_LENGTH('gold.fact_pagos', 'monto_cobranza') IS NULL
    ALTER TABLE gold.fact_pagos ADD monto_cobranza AS
        (CASE WHEN es_efectivo = 1 AND revertido = 0 AND es_reembolso = 0
              THEN monto_moneda_local ELSE 0 END);
GO


-- ========================================================================================
-- 4. Indices de las llaves (opcional pero recomendado)
--    Power BI importa la tabla completa y no hace joins en SQL, asi que esto no es para el
--    dashboard: es para la vista de detalle factura<->pago y para cualquier consulta que
--    una el puente con los hechos. Un indice sobre una columna calculada determinista si
--    esta permitido, y materializa la llave a un costo mucho menor que PERSISTED.
--    Correr uno a la vez y revisar el log entre cada uno.
-- ========================================================================================

IF INDEXPROPERTY(OBJECT_ID('gold.fact_facturas'), 'IX_fact_facturas_key', 'IndexID') IS NULL
    CREATE UNIQUE NONCLUSTERED INDEX IX_fact_facturas_key ON gold.fact_facturas (factura_key);
GO
IF INDEXPROPERTY(OBJECT_ID('gold.fact_notas'), 'IX_fact_notas_key', 'IndexID') IS NULL
    CREATE UNIQUE NONCLUSTERED INDEX IX_fact_notas_key ON gold.fact_notas (nota_key);
GO
IF INDEXPROPERTY(OBJECT_ID('gold.fact_pagos'), 'IX_fact_pagos_key', 'IndexID') IS NULL
    CREATE UNIQUE NONCLUSTERED INDEX IX_fact_pagos_key ON gold.fact_pagos (pago_key);
GO
IF INDEXPROPERTY(OBJECT_ID('gold.fact_aplicacion'), 'IX_fact_aplicacion_recibe_key', 'IndexID') IS NULL
    CREATE NONCLUSTERED INDEX IX_fact_aplicacion_recibe_key ON gold.fact_aplicacion (recibe_key);
GO
IF INDEXPROPERTY(OBJECT_ID('gold.fact_aplicacion'), 'IX_fact_aplicacion_aplica_key', 'IndexID') IS NULL
    CREATE NONCLUSTERED INDEX IX_fact_aplicacion_aplica_key ON gold.fact_aplicacion (aplica_key);
GO


-- ========================================================================================
-- 5. VERIFICACION - correr despues de las secciones 1 a 3
-- ========================================================================================

-- 5a. Las llaves existen y no traen NULL donde no deben
SELECT 'fact_facturas' AS tabla, COUNT(*) AS filas,
       SUM(CASE WHEN factura_key IS NULL THEN 1 ELSE 0 END) AS llaves_nulas,
       COUNT(DISTINCT factura_key) AS llaves_distintas
FROM gold.fact_facturas
UNION ALL
SELECT 'fact_notas', COUNT(*), SUM(CASE WHEN nota_key IS NULL THEN 1 ELSE 0 END), COUNT(DISTINCT nota_key)
FROM gold.fact_notas
UNION ALL
SELECT 'fact_pagos', COUNT(*), SUM(CASE WHEN pago_key IS NULL THEN 1 ELSE 0 END), COUNT(DISTINCT pago_key)
FROM gold.fact_pagos;
-- filas = llaves_distintas y llaves_nulas = 0 en las tres. Si no, la llave no es unica
-- y hay que revisar el supuesto antes de modelar nada encima.
GO

-- 5b. El puente enlaza: cuantas filas encuentran su factura y su vehiculo
SELECT COUNT(*) AS filas,
       SUM(CASE WHEN recibe_key IS NULL THEN 1 ELSE 0 END) AS sin_factura_esperado,
       SUM(CASE WHEN recibe_key IS NOT NULL AND NOT EXISTS
                     (SELECT 1 FROM gold.fact_facturas f WHERE f.factura_key = a.recibe_key)
                THEN 1 ELSE 0 END) AS recibe_huerfano,
       SUM(CASE WHEN NOT EXISTS (SELECT 1 FROM gold.fact_pagos p WHERE p.pago_key = a.aplica_key)
                 AND NOT EXISTS (SELECT 1 FROM gold.fact_notas n WHERE n.nota_key = a.aplica_key)
                THEN 1 ELSE 0 END) AS aplica_huerfano
FROM gold.fact_aplicacion a;
-- sin_factura_esperado = las filas NO_IDENTIFICADA e IDENTIFICADA_LOTE, esta bien que existan.
-- Los dos huerfanos deben ser 0: si no, hay filas del puente que apuntan a documentos que
-- no estan en los hechos, y eso es un hallazgo, no un detalle de modelado.
GO

-- 5c. monto_cobranza contra el calculo manual: deben ser identicos
SELECT CAST(SUM(monto_cobranza) AS DECIMAL(18,2)) AS por_la_columna,
       CAST(SUM(CASE WHEN es_efectivo = 1 AND revertido = 0 AND es_reembolso = 0
                     THEN monto_moneda_local ELSE 0 END) AS DECIMAL(18,2)) AS por_la_regla_a_mano,
       CAST(SUM(monto_moneda_local) AS DECIMAL(18,2)) AS suma_ingenua_INCORRECTA
FROM gold.fact_pagos
WHERE fecha_contabilizacion >= '2026-07-01' AND fecha_contabilizacion < '2026-08-01';
-- Las dos primeras columnas deben coincidir al centavo. La tercera queda a la vista a
-- proposito: es el numero que sale hoy si alguien suma sin saberse la regla.
GO


/*
========================================================================================
6. PENDIENTE - las cuatro columnas de enriquecimiento de gold.fact_facturas
========================================================================================
NO se pueden crear todavia: dependen de que fact_aplicacion tenga la historia completa,
o saldrian NULL para todo lo anterior a julio 2026.

    fecha_pago_real           MIN(fecha_origen) de sus aplicaciones tipo PAGO
    forma_liquidacion         EFECTIVO / CREDITO / MIXTA
    monto_liquidado_efectivo  SUM(monto_aplicado) de sus aplicaciones tipo PAGO
    dpp_confiable             1 si hay fecha_pago_real, 0 si se uso el respaldo

Que resuelven, medido sobre julio 2026:
  * 5,792 facturas / $8,579,769 se compensaron SIN un peso de efectivo (nota de credito,
    devolucion, ajuste) y hoy entran al DPP como si hubieran sido pagadas: 4.5% del valor.
    forma_liquidacion permite excluirlas con un WHERE.
  * 293 clientes tienen un DPP desplazado 2 dias o mas porque fecha_compensacion no es la
    fecha en que llego el dinero, y varios cambian de signo (un cliente que pago 3.6 dias
    ANTES de vencer aparece con 6.5 dias de atraso). fecha_pago_real lo corrige.

A diferencia de las secciones 1 a 3, estas no son columnas calculadas: hay que poblarlas
en gold.load_fact_facturas despues de que corra gold.load_fact_aplicacion, lo que implica
tocar el orden de gold.load_gold. Es trabajo aparte, no un ALTER.
========================================================================================
*/
