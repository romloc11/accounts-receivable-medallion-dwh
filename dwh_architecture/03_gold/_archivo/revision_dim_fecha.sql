USE ANALISIS_DATOS;
GO

-- Revision de gold.dim_fecha: recalcula cada columna con la MISMA formula
-- que populate_dim_fecha.sql uso originalmente (incluye SET DATEFIRST 7,
-- necesario para que DATEPART(WEEKDAY,...) sea comparable - sin esto la
-- sesion de validacion podria usar un @@DATEFIRST distinto y dar falsos
-- positivos) y cuenta cuantas filas no cuadran en cada chequeo. Todo en 0
-- significa la tabla esta sana.
SET DATEFIRST 7;
GO

;WITH esperado AS (
    SELECT
        fecha,
        YEAR(fecha) AS anio_esp,
        MONTH(fecha) AS mes_esp,
        CASE MONTH(fecha)
            WHEN 1 THEN 'Enero' WHEN 2 THEN 'Febrero' WHEN 3 THEN 'Marzo' WHEN 4 THEN 'Abril'
            WHEN 5 THEN 'Mayo' WHEN 6 THEN 'Junio' WHEN 7 THEN 'Julio' WHEN 8 THEN 'Agosto'
            WHEN 9 THEN 'Septiembre' WHEN 10 THEN 'Octubre' WHEN 11 THEN 'Noviembre' WHEN 12 THEN 'Diciembre'
        END AS nombre_mes_esp,
        DATEPART(QUARTER, fecha) AS trimestre_esp,
        DAY(fecha) AS dia_esp,
        DATEPART(WEEKDAY, fecha) AS dia_semana_esp,
        CASE DATEPART(WEEKDAY, fecha)
            WHEN 1 THEN 'Domingo' WHEN 2 THEN 'Lunes' WHEN 3 THEN 'Martes' WHEN 4 THEN 'Miercoles'
            WHEN 5 THEN 'Jueves' WHEN 6 THEN 'Viernes' WHEN 7 THEN 'Sabado'
        END AS nombre_dia_semana_esp,
        CASE WHEN DATEPART(WEEKDAY, fecha) IN (1, 7) THEN 1 ELSE 0 END AS es_fin_de_semana_esp,
        DATEPART(ISO_WEEK, fecha) AS semana_anio_esp
    FROM gold.dim_fecha
)
SELECT 'anio' AS chequeo, COUNT(*) AS num_filas_mal
FROM gold.dim_fecha d JOIN esperado e ON e.fecha = d.fecha WHERE d.anio <> e.anio_esp
UNION ALL
SELECT 'mes', COUNT(*) FROM gold.dim_fecha d JOIN esperado e ON e.fecha = d.fecha WHERE d.mes <> e.mes_esp
UNION ALL
SELECT 'nombre_mes', COUNT(*) FROM gold.dim_fecha d JOIN esperado e ON e.fecha = d.fecha WHERE d.nombre_mes <> e.nombre_mes_esp
UNION ALL
SELECT 'trimestre', COUNT(*) FROM gold.dim_fecha d JOIN esperado e ON e.fecha = d.fecha WHERE d.trimestre <> e.trimestre_esp
UNION ALL
SELECT 'dia', COUNT(*) FROM gold.dim_fecha d JOIN esperado e ON e.fecha = d.fecha WHERE d.dia <> e.dia_esp
UNION ALL
SELECT 'dia_semana', COUNT(*) FROM gold.dim_fecha d JOIN esperado e ON e.fecha = d.fecha WHERE d.dia_semana <> e.dia_semana_esp
UNION ALL
SELECT 'nombre_dia_semana', COUNT(*) FROM gold.dim_fecha d JOIN esperado e ON e.fecha = d.fecha WHERE d.nombre_dia_semana <> e.nombre_dia_semana_esp
UNION ALL
SELECT 'es_fin_de_semana', COUNT(*) FROM gold.dim_fecha d JOIN esperado e ON e.fecha = d.fecha WHERE d.es_fin_de_semana <> e.es_fin_de_semana_esp
UNION ALL
SELECT 'semana_anio', COUNT(*) FROM gold.dim_fecha d JOIN esperado e ON e.fecha = d.fecha WHERE d.semana_anio <> e.semana_anio_esp
UNION ALL
SELECT 'total_filas_vs_esperado (0 = cuadra exacto)',
    ABS(COUNT(*) - (DATEDIFF(DAY, MIN(fecha), MAX(fecha)) + 1)) FROM gold.dim_fecha
UNION ALL
SELECT 'rango_min_correcto (0 = OK, 1 = MAL)', CASE WHEN MIN(fecha) = '20200101' THEN 0 ELSE 1 END FROM gold.dim_fecha
UNION ALL
SELECT 'rango_max_correcto (0 = OK, 1 = MAL)', CASE WHEN MAX(fecha) = '20351231' THEN 0 ELSE 1 END FROM gold.dim_fecha
UNION ALL
SELECT 'nulos_en_columnas_not_null (0 = OK)', COUNT(*) FROM gold.dim_fecha
    WHERE anio IS NULL OR mes IS NULL OR nombre_mes IS NULL OR trimestre IS NULL OR dia IS NULL
       OR dia_semana IS NULL OR nombre_dia_semana IS NULL OR es_fin_de_semana IS NULL OR semana_anio IS NULL;
GO
