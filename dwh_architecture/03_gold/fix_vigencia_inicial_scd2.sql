USE ANALISIS_DATOS;
GO

/*
========================================================================================
FIX (una sola vez): fecha_inicio_vigencia inicial de dim_cliente_comercial / dim_cliente_credito
========================================================================================
gold.load_dim_cliente_comercial y gold.load_dim_cliente_credito insertan la primera
version de cada cliente con fecha_inicio_vigencia = @hoy (fecha del dia en que se
corrio la carga por primera vez, ~2026-08-10) - correcto para versiones futuras que
representan un cambio real, pero incorrecto como punto de partida para la unica
version que existe hoy, que en realidad "aplica" desde que existe el cliente.

Con silver.sap_bsad ahora con historia completa desde 2022 (ver backfill_bsad_historico.sql),
gold.fact_movimientos_compensados necesita resolver estas dos dimensiones via join
temporal (fecha_compensacion BETWEEN fecha_inicio_vigencia AND fecha_fin_vigencia).
Sin este fix, CUALQUIER movimiento anterior a la fecha de carga original quedaria sin
match (NULL) porque fecha_inicio_vigencia seria posterior a fecha_compensacion.

Se retrasa la vigencia de la version VIGENTE actual (es_vigente=1) a 2020-01-01 (mismo
arranque que gold.dim_fecha) - solo afecta esta primera version por cliente. De aqui en
adelante el mecanismo SCD2 sigue igual sin cambios: un cambio real de atributos cierra
esa version (fecha_fin_vigencia = fecha real del cambio) y abre una nueva con
fecha_inicio_vigencia = fecha real del cambio, tal como ya hacen los procedimientos de
carga.

Correr UNA SOLA VEZ, antes de la primera carga de gold.fact_movimientos_compensados
(o de cualquier fact que necesite join temporal historico contra estas dimensiones).

BUG REAL encontrado y corregido 2026-08-18: la condicion original de este
script (es_vigente=1 AND fecha_inicio_vigencia<>'2020-01-01') NO era idempotente
como decia el comentario original - volver a correrlo despues de que un cliente
YA tuviera una version real posterior (ej. tras el revert de alcance de canal del
2026-08-17) retrasaba esa version nueva a 2020-01-01 TAMBIEN, encima de su propia
version predecesora, creando un traslape (1,280 clientes afectados en
dim_cliente_comercial, 40 en dim_cliente_credito - ver
diagnostico_bug_vigencia_duplicada.sql y su reparacion en
fix_vigencia_duplicada_scd2.sql). La condicion correcta es "esta es la UNICA
version que existe para este cliente" (NOT EXISTS otra fila con el mismo
cliente_id), no solo "es la vigente y no dice ya 2020-01-01" - un cliente con
2+ versiones NUNCA debe tocarse aqui, sin importar que diga su fila vigente.
========================================================================================
*/

UPDATE d
SET d.fecha_inicio_vigencia = '2020-01-01'
FROM gold.dim_cliente_comercial d
WHERE d.es_vigente = 1
  AND d.fecha_inicio_vigencia <> '2020-01-01'
  AND NOT EXISTS (
      SELECT 1 FROM gold.dim_cliente_comercial d2
      WHERE d2.cliente_id = d.cliente_id AND d2.id_surrogate <> d.id_surrogate
  );

PRINT 'dim_cliente_comercial - filas corregidas: ' + CAST(@@ROWCOUNT AS VARCHAR);
GO

UPDATE d
SET d.fecha_inicio_vigencia = '2020-01-01'
FROM gold.dim_cliente_credito d
WHERE d.es_vigente = 1
  AND d.fecha_inicio_vigencia <> '2020-01-01'
  AND NOT EXISTS (
      SELECT 1 FROM gold.dim_cliente_credito d2
      WHERE d2.cliente_id = d.cliente_id AND d2.id_surrogate <> d.id_surrogate
  );

PRINT 'dim_cliente_credito - filas corregidas: ' + CAST(@@ROWCOUNT AS VARCHAR);
GO
