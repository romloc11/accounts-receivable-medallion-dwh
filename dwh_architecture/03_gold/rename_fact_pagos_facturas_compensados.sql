USE ANALISIS_DATOS;
GO

-- ==========================================================
-- MIGRACION UNICA: renombrar gold.fact_pagos -> gold.fact_pagos_compensados
-- y gold.fact_facturas -> gold.fact_facturas_compensadas EN EL SERVIDOR REAL,
-- preservando los datos ya cargados (backfill 2022-2026).
--
-- NO uses ddl_gold.sql para este cambio: esa version ya quedo con
-- DROP TABLE + CREATE TABLE para los nombres nuevos, correcto para un
-- despliegue desde cero, pero destructivo si se corre sobre estas tablas
-- ya pobladas. sp_rename no toca los datos, solo el catalogo.
--
-- Orden: 1) tablas, 2) PK (implementada como constraint/indice), 3) indices
-- no-clustered. Despues de correr esto, vuelve a correr sp_load_gold.sql
-- (los CREATE PROCEDURE completos) y vw_pago_factura_simple.sql para que
-- los procedimientos/vista queden apuntando a los nombres nuevos - ambos
-- son DROP+CREATE de objetos sin datos, no hay riesgo ahi.
-- ==========================================================

EXEC sp_rename 'gold.fact_pagos', 'fact_pagos_compensados';
EXEC sp_rename 'gold.PK_fact_pagos', 'PK_fact_pagos_compensados', 'OBJECT';
EXEC sp_rename 'gold.fact_pagos_compensados.IX_fact_pagos_grupo', 'IX_fact_pagos_compensados_grupo', 'INDEX';

EXEC sp_rename 'gold.fact_facturas', 'fact_facturas_compensadas';
EXEC sp_rename 'gold.PK_fact_facturas', 'PK_fact_facturas_compensadas', 'OBJECT';
EXEC sp_rename 'gold.fact_facturas_compensadas.IX_fact_facturas_grupo', 'IX_fact_facturas_compensadas_grupo', 'INDEX';

-- Verificacion rapida: deben aparecer los nombres nuevos, con las mismas
-- filas que tenian antes del rename.
SELECT 'gold.fact_pagos_compensados' AS tabla, COUNT(*) AS filas FROM gold.fact_pagos_compensados
UNION ALL
SELECT 'gold.fact_facturas_compensadas', COUNT(*) FROM gold.fact_facturas_compensadas;
GO
