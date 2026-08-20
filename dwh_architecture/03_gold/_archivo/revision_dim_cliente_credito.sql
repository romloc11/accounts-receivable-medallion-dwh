USE ANALISIS_DATOS;
GO

-- Revision de gold.dim_cliente_credito (SCD2) - misma familia de chequeos que
-- dim_cliente_comercial, mas la cobertura correcta (fuente es silver.sap_knkk
-- directo, no la vista de canal).

SELECT 'indice_unico_vigente_existe (1=OK, 0=FALTA)' AS chequeo,
    CAST(CASE WHEN EXISTS (
        SELECT 1 FROM sys.indexes WHERE name = 'UX_dim_cliente_credito_vigente'
          AND object_id = OBJECT_ID('gold.dim_cliente_credito')
    ) THEN 1 ELSE 0 END AS DECIMAL(10,2))

UNION ALL

SELECT 'clientes_con_mas_de_1_vigente', COUNT(*)
FROM (
    SELECT cliente_id FROM gold.dim_cliente_credito WHERE es_vigente = 1
    GROUP BY cliente_id HAVING COUNT(*) > 1
) x

UNION ALL

-- Cobertura correcta: fuente es silver.sap_knkk directo (no la vista de
-- canal) - todo cliente en knkk deberia tener una fila vigente aqui
SELECT 'clientes_en_knkk_sin_ninguna_vigente', COUNT(*)
FROM silver.sap_knkk k
WHERE NOT EXISTS (
    SELECT 1 FROM gold.dim_cliente_credito d WHERE d.cliente_id = k.cliente_id AND d.es_vigente = 1
)

UNION ALL

SELECT 'es_vigente_inconsistente_con_fecha_fin', COUNT(*)
FROM gold.dim_cliente_credito
WHERE (es_vigente = 1 AND fecha_fin_vigencia IS NOT NULL)
   OR (es_vigente = 0 AND fecha_fin_vigencia IS NULL)

UNION ALL

SELECT 'versiones_con_traslape_de_fechas', COUNT(*)
FROM gold.dim_cliente_credito a
JOIN gold.dim_cliente_credito b
    ON a.cliente_id = b.cliente_id AND a.id_surrogate < b.id_surrogate
WHERE a.fecha_inicio_vigencia <= ISNULL(b.fecha_fin_vigencia, '99991231')
  AND b.fecha_inicio_vigencia <= ISNULL(a.fecha_fin_vigencia, '99991231')

UNION ALL

SELECT 'versiones_con_hueco_entre_ellas', COUNT(*)
FROM gold.dim_cliente_credito a
WHERE a.es_vigente = 0
  AND NOT EXISTS (
      SELECT 1 FROM gold.dim_cliente_credito b
      WHERE b.cliente_id = a.cliente_id
        AND b.fecha_inicio_vigencia = DATEADD(DAY, 1, a.fecha_fin_vigencia)
  )

UNION ALL

SELECT 'hash_no_coincide_en_filas_vigentes', COUNT(*)
FROM gold.dim_cliente_credito d
WHERE d.es_vigente = 1
  AND d.hash_atributos <> HASHBYTES('SHA2_256',
        ISNULL(CAST(d.limite_credito AS VARCHAR(20)), '') + '|' + ISNULL(d.bloqueo_credito, '') + '|' +
        ISNULL(d.clasificacion_riesgo, '') + '|' + ISNULL(d.etiqueta_credito, '') + '|' + ISNULL(d.grupo_credito, '') + '|' +
        ISNULL(d.analista_credito_id, '') + '|' + ISNULL(d.analista_credito_nombre, '') + '|' +
        ISNULL(d.cobrador_id, '') + '|' + ISNULL(d.cobrador_nombre, '')
      )

UNION ALL

SELECT 'limite_credito_negativo', COUNT(*)
FROM gold.dim_cliente_credito
WHERE limite_credito < 0;
GO
