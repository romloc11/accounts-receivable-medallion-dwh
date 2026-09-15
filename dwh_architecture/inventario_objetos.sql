/* ============================================================================
   Object inventory
   Purpose : Lists every table, view, procedure and function in the project
             schemas, to compare the server against the repo.
   Run     : any time. Read only.
   ============================================================================ */
USE ANALISIS_DATOS;
GO

SELECT s.name      AS esquema,
       o.name      AS objeto,
       o.type_desc AS tipo,
       o.create_date,
       o.modify_date
FROM sys.objects o
INNER JOIN sys.schemas s ON s.schema_id = o.schema_id
WHERE o.type IN ('U', 'V', 'P', 'FN', 'TF', 'IF')
  AND s.name IN ('bronze', 'silver', 'gold', 'control', 'dq')
ORDER BY s.name, o.type_desc, o.name;
GO
