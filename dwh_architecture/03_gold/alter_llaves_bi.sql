USE ANALISIS_DATOS;
GO

/*
========================================================================================
LLAVES SINTETICAS PARA EL MODELO DE BI          (2026-09-08)
========================================================================================
Columnas calculadas PERSISTED. No tocan los procs de carga: se mantienen solas.

--- POR QUE EN SQL Y NO EN POWER QUERY ---
Estaban en M como Text.From([col]) & "|" & ... y eso ROMPE EL QUERY FOLDING: Power Query
se traia los millones de filas y concatenaba una por una en su propio motor. Sobre
fact_facturas (3.27M) y el puente (2.87M) el refresh se arrastraba.
Calculadas aqui, Power Query solo SELECCIONA una columna.

--- Y POR QUE NO EN DAX ---
El pronostico de presupuesto (04_pronostico) va a necesitar estas mismas llaves desde
Python. En DAX no existen fuera de Power BI, y reimplementar la concatenacion alla
significa dos definiciones que se separan en silencio el dia que alguien toque una.
Una sola definicion, aqui.

--- PERSISTED, NO CALCULADA AL VUELO ---
El valor se guarda: cuesta espacio pero se lee como cualquier columna. Sin PERSISTED
SQL Server la recalcularia en cada consulta, que es el problema que veniamos a resolver.

--- QUE LLEVA CADA UNA, Y QUE NO ---
    gold.fact_pagos.pago_key                 usada por el TREATAS de Cobranza Sin
                                             Aplicacion y por Estatus/Motivo en DAX
    gold.fact_pagos_sin_aplicacion.pago_key  el otro lado de ese TREATAS
    gold.fact_facturas.factura_key           relacion puente -> fact_facturas
    gold.fact_aplicacion_pagos.factura_key   el otro lado de esa relacion

NO se crea pago_key en el puente: NADA la consume. Existia en el modelo y eran 2.87M
concatenaciones para nada. Si algun dia se quiere volver a relacionar el puente con
fact_pagos, ojo: esa segunda relacion crea dos caminos de dim_cliente al puente y Power
BI SE NIEGA A ABRIR el archivo (paso el 2026-09-07). Ver fact_aplicacion_pagos.tmdl.

--- LAS DOS PARTES DE UNA RELACION SE CALCULAN CON LA MISMA EXPRESION ---
Y eso es la mitad del punto de bajarlas aqui: antes cada lado se concatenaba por separado
en M y nada garantizaba que coincidieran.
========================================================================================
*/

IF COL_LENGTH('gold.fact_pagos', 'pago_key') IS NULL
    ALTER TABLE gold.fact_pagos ADD pago_key AS (
        CAST(sociedad AS VARCHAR(4)) + '|' + CAST(ejercicio AS VARCHAR(4)) + '|'
        + documento_id + '|' + CAST(posicion AS VARCHAR(6))) PERSISTED;
GO
IF COL_LENGTH('gold.fact_pagos_sin_aplicacion', 'pago_key') IS NULL
    ALTER TABLE gold.fact_pagos_sin_aplicacion ADD pago_key AS (
        CAST(sociedad AS VARCHAR(4)) + '|' + CAST(ejercicio AS VARCHAR(4)) + '|'
        + documento_id + '|' + CAST(posicion AS VARCHAR(6))) PERSISTED;
GO
IF COL_LENGTH('gold.fact_facturas', 'factura_key') IS NULL
    ALTER TABLE gold.fact_facturas ADD factura_key AS (
        CAST(sociedad AS VARCHAR(4)) + '|' + CAST(ejercicio AS VARCHAR(4)) + '|'
        + documento_id + '|' + CAST(posicion AS VARCHAR(6))) PERSISTED;
GO
IF COL_LENGTH('gold.fact_aplicacion_pagos', 'factura_key') IS NULL
    ALTER TABLE gold.fact_aplicacion_pagos ADD factura_key AS (
        CAST(sociedad AS VARCHAR(4)) + '|' + CAST(ejercicio_factura AS VARCHAR(4)) + '|'
        + factura_id + '|' + CAST(posicion_factura AS VARCHAR(6))) PERSISTED;
GO

SELECT 'fact_pagos' AS tabla, COUNT(*) AS filas, COUNT(DISTINCT pago_key) AS llaves FROM gold.fact_pagos
UNION ALL SELECT 'fact_pagos_sin_aplicacion', COUNT(*), COUNT(DISTINCT pago_key) FROM gold.fact_pagos_sin_aplicacion
UNION ALL SELECT 'fact_facturas', COUNT(*), COUNT(DISTINCT factura_key) FROM gold.fact_facturas
UNION ALL SELECT 'fact_aplicacion_pagos (llaves repetidas: OK, es el puente)', COUNT(*), COUNT(DISTINCT factura_key) FROM gold.fact_aplicacion_pagos;
GO
