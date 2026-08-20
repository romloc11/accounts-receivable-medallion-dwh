USE ANALISIS_DATOS;
GO

-- Revision de dq.clientes_ambiguos: recalcula la misma logica de
-- dq.load_clientes_ambiguos en vivo y compara contra lo guardado.

;WITH recalculado AS (
    SELECT cliente_id, COUNT(*) AS canales_activos
    FROM gold.vw_cliente_canal_estatus
    WHERE estatus_comercial = 'ACTIVO'
    GROUP BY cliente_id
    HAVING COUNT(*) > 1
)
SELECT 'filas_en_tabla_pero_no_en_recalculo (desactualizada)' AS chequeo, COUNT(*) AS num_filas
FROM dq.clientes_ambiguos t
WHERE NOT EXISTS (SELECT 1 FROM recalculado r WHERE r.cliente_id = t.cliente_id AND r.canales_activos = t.canales_activos)

UNION ALL

SELECT 'filas_en_recalculo_pero_no_en_tabla (desactualizada)', COUNT(*)
FROM recalculado r
WHERE NOT EXISTS (SELECT 1 FROM dq.clientes_ambiguos t WHERE t.cliente_id = r.cliente_id AND t.canales_activos = r.canales_activos)

UNION ALL

SELECT 'filas_con_canales_activos_no_mayor_a_1 (inconsistente con su proposito)', COUNT(*)
FROM dq.clientes_ambiguos
WHERE canales_activos <= 1;
GO
