USE ANALISIS_DATOS;
GO

-- ==========================================================
-- Inventario completo de objetos en bronze/silver/gold/control/dq -
-- para comparar contra lo que el repo tiene versionado y detectar
-- objetos obsoletos/huerfanos (ej. gold.load_fact_pagos, encontrado
-- 2026-08-21 tras el rename de fact_pagos/fact_facturas).
-- ==========================================================
SELECT
    s.name  AS esquema,
    o.name  AS objeto,
    o.type_desc AS tipo,
    o.create_date,
    o.modify_date
FROM sys.objects o
INNER JOIN sys.schemas s ON s.schema_id = o.schema_id
WHERE o.type IN ('U', 'V', 'P', 'FN', 'TF', 'IF')  -- tabla, vista, proc, funciones escalar/tabla
  AND s.name IN ('bronze', 'silver', 'gold', 'control', 'dq')
ORDER BY s.name, o.type_desc, o.name;
GO
