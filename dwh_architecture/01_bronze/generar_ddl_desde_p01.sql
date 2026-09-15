/* ============================================================================
   Generate a bronze CREATE TABLE from the P01 catalog
   Purpose : Bronze keeps SAP's column names, types and ORDER. The backfills
             insert with a positional SELECT *, so a column out of order loads
             data into the wrong column without an error.
   Run     : set @tabla, run, paste the `linea` column into ddl_bronze.sql.
             Reads sys.columns only.
   Notes   : Does not add the primary key: verify it against the data first.
             decimal becomes DECIMAL(13,2); review non-amount columns by hand
             (exchange rates DECIMAL(9,5), days DECIMAL(3,0)).
   ============================================================================ */
USE ANALISIS_DATOS;
GO

DECLARE @tabla SYSNAME = 'BSAS';

SELECT  c.column_id,
        '    ' + c.name
              + REPLICATE(' ', CASE WHEN 12 - LEN(c.name) > 0
                                    THEN 12 - LEN(c.name) ELSE 1 END)
              + CASE
                  WHEN t.name = 'nvarchar' THEN 'NVARCHAR(' + CAST(c.max_length / 2 AS VARCHAR(5)) + ')'
                  WHEN t.name = 'varchar'  THEN 'VARCHAR('  + CAST(c.max_length     AS VARCHAR(5)) + ')'
                  WHEN t.name = 'decimal'  THEN 'DECIMAL(13,2)'
                  ELSE UPPER(t.name)
                END
              + CASE WHEN c.name IN ('MANDT','BUKRS','HKONT','GJAHR','BELNR','BUZEI')
                     THEN ' NOT NULL' ELSE '' END
              + ','                                                        AS linea,
        t.name                                                             AS tipo_origen,
        c.max_length                                                       AS bytes
FROM    P01.sys.columns c
JOIN    P01.sys.types   t ON t.user_type_id = c.user_type_id
WHERE   c.object_id = OBJECT_ID('P01.p01.' + @tabla)
ORDER BY c.column_id;
GO

-- Compare two SAP tables column by column (e.g. BSAS vs BSIS). The object_id
-- filters go in the subqueries: inside the ON of a FULL OUTER JOIN they do not
-- limit the unmatched side and every column of P01 comes back.
SELECT  ISNULL(a.name, b.name)                                             AS columna,
        CASE WHEN a.name IS NULL THEN 'solo en BSIS'
             WHEN b.name IS NULL THEN 'solo en BSAS'
             WHEN a.max_length <> b.max_length THEN 'MISMO NOMBRE, LARGO DISTINTO'
             WHEN a.column_id  <> b.column_id  THEN 'MISMO NOMBRE, ORDEN DISTINTO'
             ELSE 'igual' END                                              AS estado,
        a.column_id                                                        AS orden_bsas,
        b.column_id                                                        AS orden_bsis
FROM       (SELECT name, column_id, max_length FROM P01.sys.columns
            WHERE object_id = OBJECT_ID('P01.p01.BSAS')) a
FULL OUTER JOIN
           (SELECT name, column_id, max_length FROM P01.sys.columns
            WHERE object_id = OBJECT_ID('P01.p01.BSIS')) b ON b.name = a.name
ORDER BY ISNULL(a.column_id, 999), columna;
GO
