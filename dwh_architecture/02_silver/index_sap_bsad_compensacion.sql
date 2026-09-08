USE ANALISIS_DATOS;
GO

/*
========================================================================================
INDICE silver.sap_bsad (documento_compensacion)  -  2026-09-07
========================================================================================
--- QUE PROBLEMA RESUELVE ---
Varias consultas del modelo de aplicacion de pagos correlacionan contra bsad POR
documento_compensacion, no por la PK:

    NOT EXISTS (SELECT 1 FROM silver.sap_bsad h
                WHERE h.clase_documento='DZ' AND h.clave_contabilizacion='11'
                  AND h.documento_compensacion = b.documento_id)   -- documento hijo

y el mismo patron con clave 15 para las cadenas del segundo salto.

La tabla tiene ~12.5M filas y hasta hoy solo dos indices: la PK CLUSTERED
(mandante, sociedad, cliente_id, ejercicio, documento_id, posicion) y uno NONCLUSTERED
por (clase_documento, sgtxt). NINGUNO cubre documento_compensacion.

Sin indice el optimizador puede resolverlo bien (hash) o pesimo (bucle anidado sobre
12.5M por cada fila de afuera), y la eleccion no es estable. Medido el 2026-09-07:
gold.load_fact_pagos corrio en 6 s por la manana y >7 min por la tarde SIN QUE CAMBIARA
LA CONSULTA - solo cambio el plan. Descomponiendo: la consulta sin el NOT EXISTS tarda
2.8 s; agregandolo, no termina. Ese es todo el costo.

--- POR QUE FILTRADO ---
El predicado siempre trae clase_documento='DZ' y documento_compensacion IS NOT NULL.
De las 12,484,551 filas de bsad, solo 1,698,656 cumplen (14%). El indice filtrado cuesta
una fraccion del completo y sirve igual.
OJO: un indice filtrado solo se usa si la sesion tiene ANSI_NULLS y QUOTED_IDENTIFIER en
ON (el default de SSMS y de los procs compilados aqui). Si alguna herramienta los apaga,
el indice se ignora en silencio - no da error, solo vuelve la lentitud.

--- COSTO ---
Escribir en bsad se encarece un poco (la carga de silver). A cambio, las consultas del
modelo de aplicacion dejan de depender de la suerte del optimizador.
========================================================================================
*/

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

IF EXISTS (SELECT 1 FROM sys.indexes
           WHERE name = 'IX_sap_bsad_dz_compensacion'
             AND object_id = OBJECT_ID('silver.sap_bsad'))
BEGIN
    PRINT 'IX_sap_bsad_dz_compensacion ya existe - no se toca.';
END
ELSE
BEGIN
    PRINT 'Creando IX_sap_bsad_dz_compensacion...';
END
GO

CREATE NONCLUSTERED INDEX IX_sap_bsad_dz_compensacion
    ON silver.sap_bsad (documento_compensacion, clave_contabilizacion)
    WHERE clase_documento = 'DZ' AND documento_compensacion IS NOT NULL;
GO

PRINT 'Indice creado.';
GO
