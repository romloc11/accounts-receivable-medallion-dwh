USE ANALISIS_DATOS;
GO

/*
========================================================================================
FIX (una sola vez): repara el bug de fix_vigencia_inicial_scd2.sql corriendose
2+ veces sobre el mismo cliente.
========================================================================================
fix_vigencia_inicial_scd2.sql retrasaba la fila VIGENTE de cada cliente a
2020-01-01 sin verificar si ya existia una version anterior REAL para ese
cliente - la primera vez que se corrio (tabla recien reconstruida, 1 sola
version por cliente) fue seguro. Corridas posteriores (durante el revert de
canal del 2026-08-17 y/o despues del refresh completo del 2026-08-18)
volvieron a retrasar la version VIGENTE de cualquier cliente cuyo estatus/canal
ya habia cambiado desde entonces - creando 2 versiones que ambas dicen empezar
en 2020-01-01, traslapandose por completo (confirmado: 1,280 clientes en
dim_cliente_comercial, 40 en dim_cliente_credito - ver
diagnostico_bug_vigencia_duplicada.sql).

Este fix restaura la fecha_inicio_vigencia REAL de cualquier version que:
  (a) NO sea la primera version del cliente (existe una version con
      id_surrogate menor para el mismo cliente_id), Y
  (b) actualmente dice 2020-01-01 (la firma de la corrupcion)
calculandola como fecha_fin_vigencia de su version predecesora + 1 dia -
exactamente el mismo mecanismo con el que el procedimiento de carga real
(gold.load_dim_cliente_comercial/credito) las crea normalmente.

Correr UNA SOLA VEZ. Es idempotente por diseño: despues de corregidas, ninguna
fila cumple ya la condicion (a)+(b), asi que volver a correrlo no hace nada.
========================================================================================
*/

;WITH ordenado_comercial AS (
    SELECT
        id_surrogate, cliente_id, fecha_inicio_vigencia,
        LAG(fecha_fin_vigencia) OVER (PARTITION BY cliente_id ORDER BY id_surrogate) AS fecha_fin_anterior,
        ROW_NUMBER() OVER (PARTITION BY cliente_id ORDER BY id_surrogate) AS rn
    FROM gold.dim_cliente_comercial
)
UPDATE d
SET d.fecha_inicio_vigencia = DATEADD(DAY, 1, o.fecha_fin_anterior)
FROM gold.dim_cliente_comercial d
JOIN ordenado_comercial o ON o.id_surrogate = d.id_surrogate
WHERE o.rn > 1
  AND o.fecha_inicio_vigencia = '20200101'
  AND o.fecha_fin_anterior IS NOT NULL;

PRINT 'dim_cliente_comercial - filas corregidas: ' + CAST(@@ROWCOUNT AS VARCHAR);
GO

;WITH ordenado_credito AS (
    SELECT
        id_surrogate, cliente_id, fecha_inicio_vigencia,
        LAG(fecha_fin_vigencia) OVER (PARTITION BY cliente_id ORDER BY id_surrogate) AS fecha_fin_anterior,
        ROW_NUMBER() OVER (PARTITION BY cliente_id ORDER BY id_surrogate) AS rn
    FROM gold.dim_cliente_credito
)
UPDATE d
SET d.fecha_inicio_vigencia = DATEADD(DAY, 1, o.fecha_fin_anterior)
FROM gold.dim_cliente_credito d
JOIN ordenado_credito o ON o.id_surrogate = d.id_surrogate
WHERE o.rn > 1
  AND o.fecha_inicio_vigencia = '20200101'
  AND o.fecha_fin_anterior IS NOT NULL;

PRINT 'dim_cliente_credito - filas corregidas: ' + CAST(@@ROWCOUNT AS VARCHAR);
GO
