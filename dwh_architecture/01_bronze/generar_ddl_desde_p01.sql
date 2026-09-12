/* =====================================================================================
   GENERAR EL DDL DE UNA TABLA DE BRONZE DESDE EL CATALOGO DE P01
   dwh_architecture/01_bronze/generar_ddl_desde_p01.sql                   (2026-09-11)
   =====================================================================================

   PARA QUE
   --------
   Bronze es un espejo exacto de SAP: mismos nombres, mismos tipos, MISMO ORDEN. El orden
   importa de verdad - los backfill hacen `INSERT INTO ... SELECT *` posicional, sin lista
   de columnas, porque la lista explicita dentro de un INSERT...SELECT rompe la
   compilacion en esta instancia. Si el orden no coincide, la carga mete cada dato en la
   columna equivocada sin marcar error.

   Escribir 73 o 111 columnas a mano es justo donde se cuela un error que nadie ve hasta
   que los montos salen raros. Este script las lee del catalogo y arma el CREATE TABLE.

   COMO SE USA
   -----------
   Cambiar @tabla, ejecutar, copiar el resultado de la columna `linea` y pegarlo en
   ddl_bronze.sql. Lee sys.columns, no la tabla: no pesa nada sobre produccion.

   LO QUE NO HACE
   --------------
   No pone la PRIMARY KEY - esa es una decision de diseno, no un dato del catalogo, y
   ademas hay que VERIFICARLA contra los datos antes de confiar en ella (ver la consulta
   al final de cada seccion en ddl_bronze.sql).

   EQUIVALENCIAS QUE APLICA
   ------------------------
     nvarchar(n bytes)  ->  NVARCHAR(n/2)     sys.columns reporta bytes
     decimal            ->  DECIMAL(13,2)     convencion del proyecto para importes
                                              (revisar a mano si la columna no es importe:
                                               tasas de cambio van DECIMAL(9,5), plazos
                                               DECIMAL(3,0) - ver bsad/bkpf en ddl_bronze)
   ===================================================================================== */

USE ANALISIS_DATOS;
GO

DECLARE @tabla SYSNAME = 'BSAS';   -- <<< cambiar aqui: BSAS, BSIS, BKPF, BSAD...

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


/* =====================================================================================
   COMPARAR DOS TABLAS DE SAP (util para BSAS contra BSIS)
   -------------------------------------------------------------------------------------
   BSIS son las partidas de mayor ABIERTAS y BSAS las COMPENSADAS. Resultado verificado el
   2026-09-11: son IDENTICAS, 82 columnas, mismos tipos, mismo orden. Se deja la consulta
   por si SAP cambia una de las dos.

   OJO CON EL FULL OUTER JOIN: poner el filtro de object_id dentro del ON NO limita el lado
   sin pareja - salen TODAS las columnas de TODOS los objetos de P01. Costo 264 s y 1,093,638
   filas la primera vez. Los filtros van en subconsultas, como aqui.
   ===================================================================================== */
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
