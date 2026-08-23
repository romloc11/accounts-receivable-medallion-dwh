USE ANALISIS_DATOS;
GO

-- ==========================================================
-- Full inventory of objects in bronze/silver/gold/control/dq -
-- to compare against what's versioned in the repo and detect
-- obsolete/orphaned objects (e.g. gold.load_fact_pagos, found
-- 2026-08-21 after the fact_pagos/fact_facturas rename).
-- ==========================================================
SELECT
    s.name  AS esquema,
    o.name  AS objeto,
    o.type_desc AS tipo,
    o.create_date,
    o.modify_date
FROM sys.objects o
INNER JOIN sys.schemas s ON s.schema_id = o.schema_id
WHERE o.type IN ('U', 'V', 'P', 'FN', 'TF', 'IF')  -- table, view, proc, scalar/table functions
  AND s.name IN ('bronze', 'silver', 'gold', 'control', 'dq')
ORDER BY s.name, o.type_desc, o.name;
GO
