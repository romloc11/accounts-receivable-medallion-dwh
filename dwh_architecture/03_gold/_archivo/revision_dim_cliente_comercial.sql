USE ANALISIS_DATOS;
GO

-- Revision de gold.dim_cliente_comercial (SCD2). Chequeos de integridad de
-- versionado ademas de los basicos de calidad de dato.

SELECT 'indice_unico_vigente_existe (1=OK, 0=FALTA)' AS chequeo,
    CAST(CASE WHEN EXISTS (
        SELECT 1 FROM sys.indexes WHERE name = 'UX_dim_cliente_comercial_vigente'
          AND object_id = OBJECT_ID('gold.dim_cliente_comercial')
    ) THEN 1 ELSE 0 END AS DECIMAL(10,2))

UNION ALL

-- Redundante con el indice unico filtrado, pero confirma que la DATA
-- realmente lo respeta (defensa en profundidad, ya nos paso una vez en este
-- proyecto que DDL y base de datos viva se desincronizaron)
SELECT 'clientes_con_mas_de_1_vigente', COUNT(*)
FROM (
    SELECT cliente_id FROM gold.dim_cliente_comercial WHERE es_vigente = 1
    GROUP BY cliente_id HAVING COUNT(*) > 1
) x

UNION ALL

SELECT 'clientes_en_dim_cliente_sin_ninguna_vigente', COUNT(*)
FROM gold.dim_cliente c
WHERE NOT EXISTS (
    SELECT 1 FROM gold.dim_cliente_comercial dc WHERE dc.cliente_id = c.cliente_id AND dc.es_vigente = 1
)

UNION ALL

SELECT 'es_vigente_inconsistente_con_fecha_fin', COUNT(*)
FROM gold.dim_cliente_comercial
WHERE (es_vigente = 1 AND fecha_fin_vigencia IS NOT NULL)
   OR (es_vigente = 0 AND fecha_fin_vigencia IS NULL)

UNION ALL

-- Traslapes: 2 versiones del mismo cliente cuyas vigencias se pisan
SELECT 'versiones_con_traslape_de_fechas', COUNT(*)
FROM gold.dim_cliente_comercial a
JOIN gold.dim_cliente_comercial b
    ON a.cliente_id = b.cliente_id AND a.id_surrogate < b.id_surrogate
WHERE a.fecha_inicio_vigencia <= ISNULL(b.fecha_fin_vigencia, '99991231')
  AND b.fecha_inicio_vigencia <= ISNULL(a.fecha_fin_vigencia, '99991231')

UNION ALL

-- Huecos: version cerrada cuyo fin no conecta exactamente con el inicio de
-- la siguiente version del mismo cliente (deberia ser fecha_fin+1 = inicio_siguiente)
SELECT 'versiones_con_hueco_entre_ellas', COUNT(*)
FROM gold.dim_cliente_comercial a
WHERE a.es_vigente = 0
  AND NOT EXISTS (
      SELECT 1 FROM gold.dim_cliente_comercial b
      WHERE b.cliente_id = a.cliente_id
        AND b.fecha_inicio_vigencia = DATEADD(DAY, 1, a.fecha_fin_vigencia)
  )

UNION ALL

SELECT 'hash_no_coincide_en_filas_vigentes', COUNT(*)
FROM gold.dim_cliente_comercial d
WHERE d.es_vigente = 1
  AND d.hash_atributos <> HASHBYTES('SHA2_256',
        ISNULL(d.region, '') + '|' + ISNULL(d.ruta, '') + '|' + ISNULL(d.ruta_nombre, '') + '|' +
        ISNULL(d.condicion_pago, '') + '|' + ISNULL(d.vendedor_id, '') + '|' + ISNULL(d.vendedor_nombre, '') + '|' +
        ISNULL(d.gerente_id, '') + '|' + ISNULL(d.gerente_nombre, '') + '|' + d.estatus_comercial
      )

UNION ALL

SELECT 'estatus_comercial_fuera_de_catalogo', COUNT(*)
FROM gold.dim_cliente_comercial
WHERE estatus_comercial NOT IN ('ACTIVO', 'INACTIVO', 'REVISAR', 'LEGAL', 'FUERA_DE_ALCANCE')

UNION ALL

SELECT 'canal_distribucion_fuera_de_catalogo_en_vigentes', COUNT(*)
FROM gold.dim_cliente_comercial
WHERE es_vigente = 1 AND canal_distribucion NOT IN ('10', '20', '40', '60')
  AND estatus_comercial <> 'FUERA_DE_ALCANCE';
GO
