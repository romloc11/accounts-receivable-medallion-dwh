USE ANALISIS_DATOS;
GO

/*
========================================================================================
gold.fact_pagos -> cuenta_mayor  (2026-09-14)
========================================================================================
ALTER in place: la tabla trae la historia 2022->hoy, no se recrea.

--- QUE ES ---
La cuenta de efectivo donde cayo el dinero de cada pago: un banco, una caja o la
transitoria de una pasarela de pago. Sale de la linea de banco del MISMO documento en
silver.sap_bsas / silver.sap_bsis.

--- PARA QUE ---
Para filtrar los pagos por banco. El reporte con el que la empresa dice cuanto dinero
entro cada mes suma las lineas de unas pocas cuentas de banco. Filtrando fact_pagos a esas
cuentas queda, medido documento por documento contra los exports de julio y agosto 2026:
    julio   +$166,648.41 (0.11%)   11,156 documentos identicos al centavo
    agosto  -$243,993.09 (0.17%)   10,553 documentos identicos al centavo
No es exacto, y la diferencia esta explicada:
  - clientes FUERA DE ALCANCE: el reporte los trae y fact_pagos no, a proposito
    (decision de negocio: el reporte los incluye por error);
  - depositos todavia sin aplicar: fact_pagos solo lee lo compensado, aparecen al aplicarse;
  - un documento hijo al mes, que fact_pagos excluye para no contar dos veces;
  - depositos automaticos que el reporte no trae y ningun atributo separa (~$0.3M/mes).
Las cuentas del reporte no se escriben aqui: el repo es publico.

--- UNA CUENTA POR DOCUMENTO ---
Medido sobre los documentos de fact_pagos de 2026: ninguno cae en dos cuentas de efectivo.
El MIN() del procedimiento no elige entre varias; solo desempaca la unica que hay.
NULL = el documento no tiene linea en una cuenta de efectivo (110 documentos en 2026).

--- ORDEN DE DESPLIEGUE (no es opcional) ---
1. ESTE archivo.
2. gold.load_fact_pagos en sp_load_gold.sql (solo ese rango de lineas).
   Al reves falla: SQL Server acepta un procedimiento que menciona una TABLA que no
   existe, pero no una COLUMNA que no existe. El CREATE revienta despues de que el
   archivo ya borro la version anterior, y la carga diaria se queda sin procedimiento.
3. Llenar la historia: el ALTER deja la columna en NULL. Se llena recargando fact_pagos
   anio por anio - es el paso 3 de backfill_fact_aplicacion_pagos.sql, el mismo que ya
   hace falta por el cambio del filtro de texto del mismo dia:
       EXEC gold.load_fact_pagos                '2022-01-01', '2023-01-01';
       EXEC gold.load_fact_aplicacion_pagos     '2022-01-01', '2023-01-01';
       EXEC gold.load_fact_pagos_sin_aplicacion '2022-01-01', '2023-01-01';
       ... 2023, 2024, 2025; y 2026 sin tope: '2026-01-01'
   Despues, tambien anio por anio: EXEC gold.load_fact_facturas_pago_efectivo.
   Y las invariantes del paso 4 de ese mismo archivo.
========================================================================================
*/

IF COL_LENGTH('gold.fact_pagos', 'cuenta_mayor') IS NULL
    ALTER TABLE gold.fact_pagos ADD cuenta_mayor VARCHAR(10) NULL;
GO

PRINT 'gold.fact_pagos.cuenta_mayor ready (agregada si faltaba).';
GO


-- ========================================================================================
-- VALIDACION, despues del backfill (antes de el, todo sale en NULL y es correcto).
-- ========================================================================================

-- 1. Cuantas filas quedaron sin cuenta, por anio. Deben ser pocas: ~110 documentos en 2026.
SELECT YEAR(fecha_contabilizacion)                               AS anio,
       COUNT(*)                                                   AS filas,
       SUM(CASE WHEN cuenta_mayor IS NULL THEN 1 ELSE 0 END)      AS sin_cuenta
FROM   gold.fact_pagos
GROUP BY YEAR(fecha_contabilizacion)
ORDER BY anio;
GO

-- 2. Un mes, por cuenta. Filtrando a las cuentas del reporte debe dar el monto de arriba.
SELECT cuenta_mayor, COUNT(*) AS lineas, SUM(monto) AS monto
FROM   gold.fact_pagos
WHERE  fecha_contabilizacion >= '2026-07-01' AND fecha_contabilizacion < '2026-08-01'
GROUP BY cuenta_mayor
ORDER BY monto DESC;
GO
