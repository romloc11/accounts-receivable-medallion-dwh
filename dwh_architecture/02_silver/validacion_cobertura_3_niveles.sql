USE ANALISIS_DATOS;
GO

/*
Mide, por categoria, que porcentaje de FACTURAS quedaria resuelto bajo cada nivel:
  1. via REBZG directo (factura_referencia_documento/ejercicio/posicion = la factura)
  2. via grupo de compensacion INAMBIGUO (1 sola factura + 1 sola aplicacion de esa
     categoria comparten el mismo documento_compensacion/ejercicio_compensacion)
  3. sin match preciso (ninguno de los dos anteriores aplica)
Acotado a junio-julio 2026 (mismo rango de la prueba) para que sea rapido.
*/

DECLARE @fecha_inicio DATE = '20260601';
DECLARE @fecha_fin    DATE = '20260731';

;WITH factura AS (
    SELECT * FROM silver.sap_bsad
    WHERE clase_documento IN ('F1','F2','F3','F4','F5','F6')
      AND fecha_compensacion BETWEEN @fecha_inicio AND @fecha_fin
),
aplicacion AS (
    SELECT *,
        CASE
            WHEN clase_documento IN ('DZ','CP','ZY') THEN 'PAGO'
            WHEN clase_documento = 'C5' THEN 'NOTA_CREDITO'
            WHEN clase_documento = 'D1' THEN 'NOTA_DEBITO'
            WHEN clase_documento IN ('C1','C2','C3','C4') THEN 'DEVOLUCION'
            WHEN clase_documento = 'AB' THEN 'AJUSTE'
        END AS tipo_aplicacion
    FROM silver.sap_bsad
    WHERE (
            clase_documento IN ('CP','ZY')
            OR (clase_documento = 'DZ' AND sgtxt IS NULL AND debe_haber <> 'S')
            OR clase_documento IN ('C5','D1','C1','C2','C3','C4','AB')
          )
      AND fecha_compensacion BETWEEN @fecha_inicio AND @fecha_fin
),
-- grupos inambiguos: exactamente 1 factura y 1 aplicacion de la MISMA categoria
grupo_factura AS (
    SELECT sociedad, cliente_id, documento_compensacion, ejercicio_compensacion, COUNT(*) AS num_facturas
    FROM factura GROUP BY sociedad, cliente_id, documento_compensacion, ejercicio_compensacion
),
grupo_aplicacion AS (
    SELECT sociedad, cliente_id, documento_compensacion, ejercicio_compensacion, tipo_aplicacion, COUNT(*) AS num_aplicaciones
    FROM aplicacion GROUP BY sociedad, cliente_id, documento_compensacion, ejercicio_compensacion, tipo_aplicacion
)
SELECT
    a.tipo_aplicacion,
    COUNT(*) AS total_filas_aplicacion,
    SUM(CASE WHEN a.factura_referencia_documento IS NOT NULL THEN 1 ELSE 0 END) AS nivel1_rebzg,
    SUM(CASE
        WHEN a.factura_referencia_documento IS NULL
         AND gf.num_facturas = 1 AND ga.num_aplicaciones = 1
        THEN 1 ELSE 0 END) AS nivel2_grupo_inambiguo,
    SUM(CASE
        WHEN a.factura_referencia_documento IS NULL
         AND NOT (gf.num_facturas = 1 AND ga.num_aplicaciones = 1)
        THEN 1 ELSE 0 END) AS nivel3_sin_match
FROM aplicacion a
LEFT JOIN grupo_factura gf
    ON gf.sociedad = a.sociedad AND gf.cliente_id = a.cliente_id
   AND gf.documento_compensacion = a.documento_compensacion AND gf.ejercicio_compensacion = a.ejercicio_compensacion
LEFT JOIN grupo_aplicacion ga
    ON ga.sociedad = a.sociedad AND ga.cliente_id = a.cliente_id
   AND ga.documento_compensacion = a.documento_compensacion AND ga.ejercicio_compensacion = a.ejercicio_compensacion
   AND ga.tipo_aplicacion = a.tipo_aplicacion
GROUP BY a.tipo_aplicacion
ORDER BY total_filas_aplicacion DESC;
GO
