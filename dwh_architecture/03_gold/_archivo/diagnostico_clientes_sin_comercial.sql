USE ANALISIS_DATOS;
GO

-- Los 218 clientes de dim_cliente sin fila vigente en dim_cliente_comercial:
-- ¿es porque no tienen NINGUN registro en silver.sap_knvv (nunca entran a
-- vw_cliente_canal_estatus), o hay otra causa?
;WITH sin_comercial AS (
    SELECT c.cliente_id, c.nombre, c.tipo_cliente, c.rfc
    FROM gold.dim_cliente c
    WHERE NOT EXISTS (
        SELECT 1 FROM gold.dim_cliente_comercial dc WHERE dc.cliente_id = c.cliente_id AND dc.es_vigente = 1
    )
),
clasificado AS (
    SELECT sc.cliente_id,
        CASE WHEN EXISTS (SELECT 1 FROM silver.sap_knvv v WHERE v.cliente_id = sc.cliente_id)
             THEN 'SI tiene knvv (otra causa - revisar)' ELSE 'NO tiene ningun registro en knvv' END AS causa
    FROM sin_comercial sc
)
SELECT causa, COUNT(*) AS num_clientes
FROM clasificado
GROUP BY causa;

-- Si hay alguno con knvv, mostrar ejemplos para investigar
SELECT TOP 5 sc.cliente_id, sc.nombre, sc.tipo_cliente
FROM gold.dim_cliente sc
WHERE NOT EXISTS (SELECT 1 FROM gold.dim_cliente_comercial dc WHERE dc.cliente_id = sc.cliente_id AND dc.es_vigente = 1)
  AND EXISTS (SELECT 1 FROM silver.sap_knvv v WHERE v.cliente_id = sc.cliente_id);
GO
