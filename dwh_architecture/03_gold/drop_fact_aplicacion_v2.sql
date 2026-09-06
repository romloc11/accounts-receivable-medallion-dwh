-- ============================================================================
-- LIMPIEZA: retiro completo de fact_aplicacion v2 de gold
-- ----------------------------------------------------------------------------
-- Decision del usuario 2026-09-05: se borra la estrategia v2 completa (tablas +
-- procedimientos) para volver a plantear la logica de aplicacion desde cero.
--
-- QUE SE BORRA (5 tablas + 5 procedimientos, todo lo que introdujeron
-- ddl_fact_aplicacion.sql y sp_load_fact_aplicacion.sql):
--     gold.fact_aplicacion            4,745,404 filas
--     gold.fact_facturas              4,787,338 filas
--     gold.fact_pagos                 3,319,435 filas
--     gold.fact_notas                   552,747 filas
--     gold.dim_tipo_documento                23 filas
--     gold.load_fact_aplicacion / load_fact_facturas / load_fact_pagos /
--     gold.load_fact_notas / load_dim_tipo_documento
--
-- QUE NO SE TOCA (la ruta que alimenta el dashboard sigue viva):
--     gold.fact_pagos_compensados, gold.fact_facturas_compensadas,
--     gold.fact_saldo_cartera, las 5 dimensiones, los 3 views
--     (vw_pago_factura_simple, vw_cartera_abierta, vw_cliente_canal_estatus)
--     y gold.load_gold - el orquestador NUNCA llego a llamar a los 5 procs de
--     v2, asi que no hay que editarlo.
--     Tampoco se tocan las columnas que v2 agrego en silver
--     (clave_contabilizacion / campos de aplicacion en bsid): son datos de
--     origen, ya cargados por silver.load_silver, y cualquier logica nueva los
--     va a querer. Ver 02_silver/alter_bsad_bsid_clave_contabilizacion.sql.
--
-- VERIFICADO ANTES DE ESCRIBIR ESTO (2026-09-05, contra el servidor):
--     - sys.foreign_keys: 0 FKs entrantes o salientes en las 5 tablas (las
--       unicas 4 FKs de gold son de fact_saldo_cartera hacia las dimensiones).
--     - sys.sql_modules: ningun view ni proc sobreviviente las referencia. La
--       unica mencion de 'fact_aplicacion' en silver.load_silver es un
--       comentario, no codigo.
--     - Power BI: 0 menciones en el semantic model.
--
-- COMO CORRERLO: bloque por bloque en SSMS, revisando el mensaje de cada uno.
-- NO es TRUNCATE ni DELETE a proposito - DROP no llena el log de transacciones
-- (borrar 13.4M filas con DELETE si lo llenaria; el limite de este servidor son
-- 2 GB, ver dwh-ciosa-sqlserver-constraints en memoria).
-- Sintaxis SQL Server 2012: no existe DROP TABLE IF EXISTS (es 2016+), por eso
-- cada bloque va con IF OBJECT_ID(...) IS NOT NULL.
--
-- REVERSIBILIDAD: el DDL y los procs se recuperan de git (commits cf7f105,
-- ae50153, f55b6d2, ya en GitHub). Los DATOS no: son ~30-60 min de backfill
-- historico por anio para volver a levantarlos.
-- ============================================================================


-- ============================================================================
-- BLOQUE 0 - Foto antes de borrar (read-only, corre esto primero y guarda el
--            resultado: es el unico registro de lo que habia)
-- ============================================================================
SELECT s.name + '.' + t.name AS tabla, SUM(p.rows) AS filas
FROM sys.tables t
JOIN sys.schemas s    ON s.schema_id = t.schema_id
JOIN sys.partitions p ON p.object_id = t.object_id AND p.index_id IN (0, 1)
WHERE s.name = 'gold'
  AND t.name IN ('dim_tipo_documento', 'fact_facturas', 'fact_notas', 'fact_pagos', 'fact_aplicacion')
GROUP BY s.name, t.name
ORDER BY tabla;
GO

-- Control de seguridad: esto DEBE regresar 0 filas. Si regresa algo, hay un
-- objeto que depende de las tablas y hay que revisarlo ANTES de seguir.
SELECT s.name + '.' + o.name AS objeto_dependiente, o.type_desc
FROM sys.sql_modules m
JOIN sys.objects o ON o.object_id = m.object_id
JOIN sys.schemas s ON s.schema_id = o.schema_id
WHERE o.name NOT IN ('load_dim_tipo_documento', 'load_fact_facturas', 'load_fact_notas',
                     'load_fact_pagos', 'load_fact_aplicacion')
  AND (m.definition LIKE '%gold.dim_tipo_documento%'
    OR m.definition LIKE '%gold.fact_aplicacion%'
    OR m.definition LIKE '%gold.fact_notas%'
    OR (m.definition LIKE '%gold.fact_facturas%' AND m.definition NOT LIKE '%gold.fact_facturas_compensadas%')
    OR (m.definition LIKE '%gold.fact_pagos%'    AND m.definition NOT LIKE '%gold.fact_pagos_compensados%'));
GO


-- ============================================================================
-- BLOQUE 1 - Procedimientos (van primero: son los que referencian las tablas)
-- ============================================================================
IF OBJECT_ID('gold.load_fact_aplicacion', 'P') IS NOT NULL
    DROP PROCEDURE gold.load_fact_aplicacion;
GO
IF OBJECT_ID('gold.load_fact_pagos', 'P') IS NOT NULL
    DROP PROCEDURE gold.load_fact_pagos;
GO
IF OBJECT_ID('gold.load_fact_notas', 'P') IS NOT NULL
    DROP PROCEDURE gold.load_fact_notas;
GO
IF OBJECT_ID('gold.load_fact_facturas', 'P') IS NOT NULL
    DROP PROCEDURE gold.load_fact_facturas;
GO
IF OBJECT_ID('gold.load_dim_tipo_documento', 'P') IS NOT NULL
    DROP PROCEDURE gold.load_dim_tipo_documento;
GO
PRINT 'Bloque 1 listo: 5 procedimientos de v2 eliminados.';
GO


-- ============================================================================
-- BLOQUE 2 - gold.fact_aplicacion (4.7M filas)
-- ============================================================================
IF OBJECT_ID('gold.fact_aplicacion', 'U') IS NOT NULL
    DROP TABLE gold.fact_aplicacion;
GO
PRINT 'gold.fact_aplicacion eliminada.';
GO


-- ============================================================================
-- BLOQUE 3 - gold.fact_pagos (3.3M filas)
-- ============================================================================
IF OBJECT_ID('gold.fact_pagos', 'U') IS NOT NULL
    DROP TABLE gold.fact_pagos;
GO
PRINT 'gold.fact_pagos eliminada.';
GO


-- ============================================================================
-- BLOQUE 4 - gold.fact_notas (552K filas)
-- ============================================================================
IF OBJECT_ID('gold.fact_notas', 'U') IS NOT NULL
    DROP TABLE gold.fact_notas;
GO
PRINT 'gold.fact_notas eliminada.';
GO


-- ============================================================================
-- BLOQUE 5 - gold.fact_facturas (4.8M filas)
-- ============================================================================
IF OBJECT_ID('gold.fact_facturas', 'U') IS NOT NULL
    DROP TABLE gold.fact_facturas;
GO
PRINT 'gold.fact_facturas eliminada.';
GO


-- ============================================================================
-- BLOQUE 6 - gold.dim_tipo_documento (23 filas)
-- ============================================================================
IF OBJECT_ID('gold.dim_tipo_documento', 'U') IS NOT NULL
    DROP TABLE gold.dim_tipo_documento;
GO
PRINT 'gold.dim_tipo_documento eliminada.';
GO


-- ============================================================================
-- BLOQUE 7 - Verificacion final
--            Esperado: 0 sobrevivientes, y el inventario de gold queda en
--            8 tablas + 3 views + 9 procedimientos.
-- ============================================================================
DECLARE @sobrevivientes INT;

SELECT @sobrevivientes = COUNT(*)
FROM sys.objects o
JOIN sys.schemas s ON s.schema_id = o.schema_id
WHERE s.name = 'gold'
  AND o.name IN ('dim_tipo_documento', 'fact_facturas', 'fact_notas', 'fact_pagos', 'fact_aplicacion',
                 'load_dim_tipo_documento', 'load_fact_facturas', 'load_fact_notas',
                 'load_fact_pagos', 'load_fact_aplicacion');

PRINT 'Objetos de v2 que sobrevivieron (esperado 0): ' + CAST(@sobrevivientes AS VARCHAR(10));
GO

SELECT o.type_desc, s.name + '.' + o.name AS objeto
FROM sys.objects o
JOIN sys.schemas s ON s.schema_id = o.schema_id
WHERE s.name = 'gold' AND o.type IN ('U', 'V', 'P')
ORDER BY o.type_desc, o.name;
GO

-- Sanity check de la ruta del dashboard: las 3 tablas que la alimentan deben
-- seguir con sus filas intactas. Si alguna sale en 0 o truena, se borro de mas.
-- (Esperado 2026-09-05: 617,213 / 4,721,162 / 47,439.)
SELECT 'fact_pagos_compensados'    AS tabla, COUNT(*) AS filas FROM gold.fact_pagos_compensados
UNION ALL
SELECT 'fact_facturas_compensadas', COUNT(*) FROM gold.fact_facturas_compensadas
UNION ALL
SELECT 'fact_saldo_cartera',        COUNT(*) FROM gold.fact_saldo_cartera;
GO

-- Y los 3 views deben seguir existiendo y compilando. Esto valida su definicion
-- sin ejecutarlos (vw_pago_factura_simple es pesado: un mes tarda varios minutos).
SELECT s.name + '.' + o.name AS vista, o.type_desc
FROM sys.objects o
JOIN sys.schemas s ON s.schema_id = o.schema_id
WHERE s.name = 'gold' AND o.type = 'V'
ORDER BY o.name;
GO
