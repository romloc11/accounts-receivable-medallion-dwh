USE ANALISIS_DATOS;
GO

/*
========================================================================================
ONE-TIME SCHEMA CHANGE: paridad de columnas entre silver.sap_bsid y silver.sap_bsad
========================================================================================
PROPOSITO (2026-09-05, decision del usuario):
  silver.sap_bsid debe tener EXACTAMENTE las mismas columnas que silver.sap_bsad,
  aunque las de compensacion siempre vengan en NULL, para que las dos tablas se puedan
  tratar como una sola poblacion (UNION ALL, misma proyeccion, mismo codigo de lectura)
  sin tener que recordar cual de las dos carece de que campo.

DELTA REAL (comparado columna por columna contra el servidor 2026-09-05): son 3, y las
3 son de compensacion. Todo lo demas ya estaba parejo, incluidos los campos de aplicacion
que se agregaron el 2026-09-03 (clave_contabilizacion, sgtxt, REBZG/REBZJ/REBZZ):

    fecha_compensacion       DATE          <- AUGDT
    documento_compensacion   VARCHAR(10)   <- AUGBL
    ejercicio_compensacion   INT           <- AUGGJ

POR QUE SIEMPRE VAN A SER NULL, Y POR QUE AUN ASI SE MAPEAN DESDE BRONZE:
  BSID es la tabla de partidas ABIERTAS de SAP: una partida se mueve a BSAD justo cuando
  se compensa, asi que por definicion una fila de BSID no tiene documento de compensacion.
  Verificado con datos reales 2026-09-05: las 83,653 filas de bronze.sap_bsid traen
  AUGBL=' ', AUGDT='00000000' y AUGGJ='0000' - o sea el valor "vacio" de SAP, no NULL.

  TRAMPA REAL ENCONTRADA AL ESCRIBIR ESTO: AUGGJ no viene vacio, viene '0000'. El parseo
  que usa bsad (TRY_CAST(NULLIF(LTRIM(RTRIM(AUGGJ)),'') AS INT)) NO lo atrapa, y habria
  dejado ejercicio_compensacion = 0 en las 83,653 filas - un "ejercicio cero" que parece
  dato y no lo es. Por eso el loader lleva un segundo NULLIF contra '0000' en bsid.
  En bsad no hace falta: toda fila compensada trae un ejercicio real (2022-2026 en las
  12.47M filas), asi que esa expresion se dejo tal cual, sin tocar codigo que ya sirve.
  Aun asi sp_load_silver.sql las mapea desde AUGDT/AUGBL/AUGGJ con exactamente el mismo
  parseo que usa bsad, en vez de escribir NULL literal. Dos razones: el loader dice de que
  campo de SAP viene cada columna (se documenta solo), y si algun dia SAP entrega una fila
  de BSID con compensacion, se veria en vez de perderse - seria una senal de que algo
  cambio en el origen, no un dato que se descarta en silencio.

DECISION DE ORDEN DE COLUMNAS (leer antes de escribir un UNION):
  ALTER TABLE ADD siempre agrega al FINAL. En bsad estas 3 columnas viven en las posiciones
  14-16 (entre fecha_registro_sistema y clase_documento); en bsid quedan al final. Las dos
  tablas tienen el MISMO CONJUNTO de columnas pero NO en el mismo orden.
  Consecuencia practica: cualquier UNION entre las dos DEBE listar las columnas
  explicitamente. 'SELECT * FROM bsid UNION ALL SELECT * FROM bsad' compila (mismo numero
  de columnas, tipos compatibles de a pares) pero aparea columnas equivocadas en silencio.
  Se prefirio ALTER sobre DROP+CREATE a proposito: hay 4 objetos que leen silver.sap_bsid
  (bronze.load_bronze, silver.load_silver, gold.load_fact_saldo_cartera y
  gold.vw_cartera_abierta), y uno de ellos hace SELECT * INTO #temp - reconstruir la tabla
  para ganar orden cosmetico no vale ese riesgo. Si algun dia se necesita paridad
  posicional, se logra con un DROP+CREATE de esta sola tabla seguido de EXEC
  silver.load_silver, NUNCA re-corriendo ddl_silver.sql completo (ese archivo hace DROP de
  las 8 tablas de la capa).

IMPACTO EN LO QUE YA EXISTE: ninguno.
  - El INSERT de silver.load_silver hacia sap_bsid lista columnas explicitamente, asi que
    seguia funcionando aun sin tocarlo; se actualizo de todos modos para poblar las nuevas.
  - gold.load_fact_saldo_cartera hace SELECT * INTO #bsid_firmado y despues agrega por
    columnas nombradas: 3 columnas mas en el temp, cero efecto en el resultado.
  - gold.vw_cartera_abierta proyecta columnas explicitas.
  - No hay FKs hacia silver.sap_bsid, y su unico indice es el PK (no cambia).

COMO CORRERLO: bloque por bloque. Es idempotente (revisa COL_LENGTH antes de cada ADD),
asi que se puede volver a correr sin dano. Despues hay que correr EXEC silver.load_silver
para que las columnas nuevas queden pobladas por el loader nuevo (van a quedar en NULL,
que es el resultado correcto).
========================================================================================
*/


-- ========================================================================================
-- BLOQUE 0 - Diagnostico: que columnas de bsad le faltan a bsid (read-only)
--            Antes del cambio deben salir 3 filas; despues, 0.
-- ========================================================================================
SELECT d.COLUMN_NAME AS falta_en_bsid, d.DATA_TYPE, d.CHARACTER_MAXIMUM_LENGTH AS longitud
FROM INFORMATION_SCHEMA.COLUMNS d
WHERE d.TABLE_SCHEMA = 'silver' AND d.TABLE_NAME = 'sap_bsad'
  AND NOT EXISTS (
      SELECT 1 FROM INFORMATION_SCHEMA.COLUMNS i
      WHERE i.TABLE_SCHEMA = 'silver' AND i.TABLE_NAME = 'sap_bsid'
        AND i.COLUMN_NAME = d.COLUMN_NAME)
ORDER BY d.ORDINAL_POSITION;
GO


-- ========================================================================================
-- BLOQUE 1 - Agregar las 3 columnas (NULLables, sin DEFAULT: son metadata-only en SQL
--            Server, no reescriben la tabla y corren en milisegundos)
-- ========================================================================================
IF COL_LENGTH('silver.sap_bsid', 'fecha_compensacion') IS NULL
    ALTER TABLE silver.sap_bsid ADD fecha_compensacion DATE NULL;
GO
IF COL_LENGTH('silver.sap_bsid', 'documento_compensacion') IS NULL
    ALTER TABLE silver.sap_bsid ADD documento_compensacion VARCHAR(10) NULL;
GO
IF COL_LENGTH('silver.sap_bsid', 'ejercicio_compensacion') IS NULL
    ALTER TABLE silver.sap_bsid ADD ejercicio_compensacion INT NULL;
GO
PRINT 'Bloque 1 listo: columnas de compensacion agregadas a silver.sap_bsid.';
GO


-- ========================================================================================
-- BLOQUE 2 - Verificacion de paridad
--            Fila 1: columnas de bsad que le faltan a bsid  -> esperado 0
--            Fila 2: columnas de bsid que no estan en bsad  -> esperado 0
--            Fila 3: columnas con el mismo nombre pero tipo distinto -> esperado 0
-- ========================================================================================
SELECT 'faltan en bsid' AS chequeo, COUNT(*) AS columnas
FROM INFORMATION_SCHEMA.COLUMNS d
WHERE d.TABLE_SCHEMA='silver' AND d.TABLE_NAME='sap_bsad'
  AND NOT EXISTS (SELECT 1 FROM INFORMATION_SCHEMA.COLUMNS i
                  WHERE i.TABLE_SCHEMA='silver' AND i.TABLE_NAME='sap_bsid' AND i.COLUMN_NAME=d.COLUMN_NAME)
UNION ALL
SELECT 'sobran en bsid', COUNT(*)
FROM INFORMATION_SCHEMA.COLUMNS i
WHERE i.TABLE_SCHEMA='silver' AND i.TABLE_NAME='sap_bsid'
  AND NOT EXISTS (SELECT 1 FROM INFORMATION_SCHEMA.COLUMNS d
                  WHERE d.TABLE_SCHEMA='silver' AND d.TABLE_NAME='sap_bsad' AND d.COLUMN_NAME=i.COLUMN_NAME)
UNION ALL
SELECT 'tipo distinto', COUNT(*)
FROM INFORMATION_SCHEMA.COLUMNS d
JOIN INFORMATION_SCHEMA.COLUMNS i
  ON  i.TABLE_SCHEMA='silver' AND i.TABLE_NAME='sap_bsid' AND i.COLUMN_NAME=d.COLUMN_NAME
WHERE d.TABLE_SCHEMA='silver' AND d.TABLE_NAME='sap_bsad'
  AND (d.DATA_TYPE <> i.DATA_TYPE
    OR ISNULL(CAST(d.CHARACTER_MAXIMUM_LENGTH AS INT), -9) <> ISNULL(CAST(i.CHARACTER_MAXIMUM_LENGTH AS INT), -9)
    OR ISNULL(CAST(d.NUMERIC_PRECISION AS INT), -9)        <> ISNULL(CAST(i.NUMERIC_PRECISION AS INT), -9)
    OR ISNULL(CAST(d.NUMERIC_SCALE AS INT), -9)            <> ISNULL(CAST(i.NUMERIC_SCALE AS INT), -9));
GO


-- ========================================================================================
-- BLOQUE 3 - Despues de recompilar silver.load_silver y correr EXEC silver.load_silver:
--            las 3 columnas deben existir y estar 100% en NULL (partidas abiertas).
--            Si alguna trae valor, NO es un error del pipeline: significa que SAP entrego
--            una partida abierta con compensacion. Investigar antes de asumir nada.
-- ========================================================================================
SELECT COUNT(*) AS filas,
       SUM(CASE WHEN fecha_compensacion     IS NOT NULL THEN 1 ELSE 0 END) AS con_fecha_compensacion,
       SUM(CASE WHEN documento_compensacion IS NOT NULL THEN 1 ELSE 0 END) AS con_documento_compensacion,
       SUM(CASE WHEN ejercicio_compensacion IS NOT NULL THEN 1 ELSE 0 END) AS con_ejercicio_compensacion
FROM silver.sap_bsid;
GO
