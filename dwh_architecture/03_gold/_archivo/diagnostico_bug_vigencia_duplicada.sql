USE ANALISIS_DATOS;
GO

-- Hipotesis: fix_vigencia_inicial_scd2.sql se corrio 2 veces (la original al
-- reconstruir el gold layer tras el incidente de ddl_gold.sql, y de nuevo el
-- 2026-08-17 al revertir el alcance de canal). Su WHERE (es_vigente=1 AND
-- fecha_inicio_vigencia<>'2020-01-01') no distingue "esta es la PRIMERA
-- version de este cliente" de "esta es una version nueva real que broto de
-- un cambio de atributo" - la segunda corrida pudo haber retrocedido la
-- fecha_inicio de versiones NUEVAS (creadas por el propio revert) de vuelta
-- a 2020-01-01, encima de su propia version predecesora ya cerrada.

-- Clientes con 2+ filas que EMPIEZAN en 2020-01-01 (solo deberia poder pasar
-- una vez por cliente - la version genuina mas antigua)
SELECT 'clientes_con_2+_versiones_iniciando_2020-01-01' AS chequeo, COUNT(*) AS num_clientes
FROM (
    SELECT cliente_id FROM gold.dim_cliente_comercial
    WHERE fecha_inicio_vigencia = '20200101'
    GROUP BY cliente_id HAVING COUNT(*) > 1
) x;

-- Ejemplos concretos para confirmar el patron a ojo
SELECT TOP 5 cliente_id, id_surrogate, estatus_comercial, canal_distribucion,
       fecha_inicio_vigencia, fecha_fin_vigencia, es_vigente, fecha_carga
FROM gold.dim_cliente_comercial
WHERE cliente_id IN (
    SELECT cliente_id FROM gold.dim_cliente_comercial
    WHERE fecha_inicio_vigencia = '20200101'
    GROUP BY cliente_id HAVING COUNT(*) > 1
)
ORDER BY cliente_id, id_surrogate;

-- Mismo chequeo para dim_cliente_credito - se corrio el mismo fix ahi tambien
SELECT 'credito_clientes_con_2+_versiones_iniciando_2020-01-01' AS chequeo, COUNT(*) AS num_clientes
FROM (
    SELECT cliente_id FROM gold.dim_cliente_credito
    WHERE fecha_inicio_vigencia = '20200101'
    GROUP BY cliente_id HAVING COUNT(*) > 1
) x;
GO
