USE ANALISIS_DATOS;
GO

-- Revision de gold.dim_cliente (SCD1). Chequeos:
--   1. Duplicados de cliente_id en la fuente (silver.sap_knkk) que podrian
--      indicar que el LEFT JOIN de la carga no es 1:1 como se asume.
--   2. Reconciliacion: clientes en silver.sap_kna1 sin fila en dim_cliente
--      (la carga deberia cubrir a TODOS - si sale >0, la carga se quedo corta).
--   3. Clientes en dim_cliente que YA NO existen en kna1 (huerfanos - no es
--      necesariamente un bug, la carga nunca borra a proposito, pero hay que
--      saber si existen).
--   4. tipo_cliente: recalculado con la misma formula de gold.load_dim_cliente,
--      cuantas filas no cuadran contra lo ya guardado.
--   5. tipo_cliente con valores fuera del catalogo esperado (FILIAL/
--      DIRECCION_ALTERNA/GENERICO/PADRE).
--   6. % de NULL en columnas de identidad clave (rfc, nombre).
--   7. fecha_actualizacion: filas que NO se tocaron en la corrida de hoy
--      (deberian ser 0 justo despues de un refresh completo).

SELECT 'duplicados_cliente_id_en_knkk' AS chequeo, COUNT(*) AS num_filas
FROM (
    SELECT cliente_id FROM silver.sap_knkk GROUP BY cliente_id HAVING COUNT(*) > 1
) x

UNION ALL

SELECT 'clientes_en_kna1_sin_fila_en_dim_cliente', COUNT(*)
FROM silver.sap_kna1 k
WHERE NOT EXISTS (SELECT 1 FROM gold.dim_cliente d WHERE d.cliente_id = k.cliente_id)

UNION ALL

SELECT 'clientes_en_dim_cliente_ya_no_en_kna1 (huerfanos, informativo)', COUNT(*)
FROM gold.dim_cliente d
WHERE NOT EXISTS (SELECT 1 FROM silver.sap_kna1 k WHERE k.cliente_id = d.cliente_id)

UNION ALL

SELECT 'tipo_cliente_no_coincide_con_formula', COUNT(*)
FROM gold.dim_cliente d
JOIN silver.sap_kna1 k ON k.cliente_id = d.cliente_id
LEFT JOIN silver.sap_knkk kk ON kk.cliente_id = k.cliente_id
WHERE d.tipo_cliente <> CASE
        WHEN kk.etiqueta_credito = 'FILIAL' THEN 'FILIAL'
        WHEN k.rfc IS NULL THEN 'DIRECCION_ALTERNA'
        WHEN k.rfc IN ('XAXX010101000', 'XEXX010101000') THEN 'GENERICO'
        ELSE 'PADRE'
    END

UNION ALL

SELECT 'tipo_cliente_fuera_de_catalogo', COUNT(*)
FROM gold.dim_cliente
WHERE tipo_cliente NOT IN ('FILIAL', 'DIRECCION_ALTERNA', 'GENERICO', 'PADRE')

UNION ALL

SELECT 'pct_rfc_nulo (informativo, no necesariamente error)',
    CAST(100.0 * SUM(CASE WHEN rfc IS NULL THEN 1 ELSE 0 END) / COUNT(*) AS DECIMAL(5,2))
FROM gold.dim_cliente

UNION ALL

SELECT 'pct_nombre_nulo', CAST(100.0 * SUM(CASE WHEN nombre IS NULL THEN 1 ELSE 0 END) / COUNT(*) AS DECIMAL(5,2))
FROM gold.dim_cliente

UNION ALL

SELECT 'filas_no_tocadas_en_refresh_de_hoy', COUNT(*)
FROM gold.dim_cliente
WHERE CAST(fecha_actualizacion AS DATE) <> CAST(GETDATE() AS DATE);
GO
