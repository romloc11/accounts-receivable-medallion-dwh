USE ANALISIS_DATOS;
GO

/*
========================================================================================
gold.dim_festivo  -  calendario de dias inhabiles  (2026-09-08)
========================================================================================
Lista MANTENIDA A MANO de festivos oficiales (LFT art. 74) y bancarios (CNBV).
Cubre 2022-2030. Para extenderla: agregar filas aqui y volver a correr el archivo -
el INSERT solo mete las fechas que faltan, no pisa lo que ya existe.

--- ESTA LISTA ESTA VALIDADA CONTRA LOS DATOS, NO SUPUESTA ---
Se comparo la cobranza real por dia (gold.fact_pagos, fecha_documento) 2023-2026:

    dia habil normal      921 dias   $7.57M promedio   100%
    sabado                189 dias   $0.07M              0.9%
    FESTIVO en dia habil   29 dias   $0.04M              0.5%
    domingo               137 dias   $0.02M              0.2%

Los festivos estan MAS muertos que un sabado. Uno por uno tampoco hay falsos
positivos: el mas "vivo" es Virgen de Guadalupe con $146K promedio (1.9% de un dia
normal); el resto va de $7K a $51K. Si algun ano se agrega un festivo que no cumpla
esto, sobra en la lista.

Y al reves: se buscaron dias ENTRE SEMANA con cobranza bajo el 20% que NO estuvieran
en la lista. En 3.5 anos aparecio UNO SOLO, 2024-10-01 (0.6%), que es la transmision
del Poder Ejecutivo - la reforma de 2019 la movio del 1-dic al 1-OCT y aplico por
primera vez en 2024. Ya esta incluido. Que solo falte uno es la evidencia de que la
lista esta completa para este negocio.

--- POR QUE TABLA Y NO UN CASE EN EL PROC ---
Agregar un festivo tiene que ser un INSERT, no una recompilacion de gold.load_dim_fecha.
Ademas los bancarios cambian por circular de CNBV y los de Semana Santa se mueven cada
ano (Pascua), asi que la lista se toca seguido.
========================================================================================
*/

IF OBJECT_ID('gold.dim_festivo', 'U') IS NULL
CREATE TABLE gold.dim_festivo (
    fecha   DATE        NOT NULL,
    nombre  VARCHAR(40) NOT NULL,
    tipo    VARCHAR(10) NOT NULL,   -- OFICIAL (LFT art. 74) | BANCARIO (CNBV)
    CONSTRAINT PK_dim_festivo PRIMARY KEY CLUSTERED (fecha)
);
GO

-- Solo inserta lo que falta: re-ejecutable, y no pisa festivos agregados a mano.
INSERT INTO gold.dim_festivo (fecha, nombre, tipo)
SELECT v.fecha, v.nombre, v.tipo
FROM (VALUES
    ('2022-01-01','Ano Nuevo','OFICIAL'),
    ('2022-02-07','Dia de la Constitucion','OFICIAL'),
    ('2022-03-21','Natalicio de Benito Juarez','OFICIAL'),
    ('2022-04-14','Jueves Santo','BANCARIO'),
    ('2022-04-15','Viernes Santo','BANCARIO'),
    ('2022-05-01','Dia del Trabajo','OFICIAL'),
    ('2022-09-16','Independencia','OFICIAL'),
    ('2022-11-02','Dia de Muertos','BANCARIO'),
    ('2022-11-21','Revolucion Mexicana','OFICIAL'),
    ('2022-12-12','Virgen de Guadalupe','BANCARIO'),
    ('2022-12-25','Navidad','OFICIAL'),
    ('2023-01-01','Ano Nuevo','OFICIAL'),
    ('2023-02-06','Dia de la Constitucion','OFICIAL'),
    ('2023-03-20','Natalicio de Benito Juarez','OFICIAL'),
    ('2023-04-06','Jueves Santo','BANCARIO'),
    ('2023-04-07','Viernes Santo','BANCARIO'),
    ('2023-05-01','Dia del Trabajo','OFICIAL'),
    ('2023-09-16','Independencia','OFICIAL'),
    ('2023-11-02','Dia de Muertos','BANCARIO'),
    ('2023-11-20','Revolucion Mexicana','OFICIAL'),
    ('2023-12-12','Virgen de Guadalupe','BANCARIO'),
    ('2023-12-25','Navidad','OFICIAL'),
    ('2024-01-01','Ano Nuevo','OFICIAL'),
    ('2024-02-05','Dia de la Constitucion','OFICIAL'),
    ('2024-03-18','Natalicio de Benito Juarez','OFICIAL'),
    ('2024-03-28','Jueves Santo','BANCARIO'),
    ('2024-03-29','Viernes Santo','BANCARIO'),
    ('2024-05-01','Dia del Trabajo','OFICIAL'),
    ('2024-09-16','Independencia','OFICIAL'),
    ('2024-10-01','Transmision del Poder Ejecutivo','OFICIAL'),
    ('2024-11-02','Dia de Muertos','BANCARIO'),
    ('2024-11-18','Revolucion Mexicana','OFICIAL'),
    ('2024-12-12','Virgen de Guadalupe','BANCARIO'),
    ('2024-12-25','Navidad','OFICIAL'),
    ('2025-01-01','Ano Nuevo','OFICIAL'),
    ('2025-02-03','Dia de la Constitucion','OFICIAL'),
    ('2025-03-17','Natalicio de Benito Juarez','OFICIAL'),
    ('2025-04-17','Jueves Santo','BANCARIO'),
    ('2025-04-18','Viernes Santo','BANCARIO'),
    ('2025-05-01','Dia del Trabajo','OFICIAL'),
    ('2025-09-16','Independencia','OFICIAL'),
    ('2025-11-02','Dia de Muertos','BANCARIO'),
    ('2025-11-17','Revolucion Mexicana','OFICIAL'),
    ('2025-12-12','Virgen de Guadalupe','BANCARIO'),
    ('2025-12-25','Navidad','OFICIAL'),
    ('2026-01-01','Ano Nuevo','OFICIAL'),
    ('2026-02-02','Dia de la Constitucion','OFICIAL'),
    ('2026-03-16','Natalicio de Benito Juarez','OFICIAL'),
    ('2026-04-02','Jueves Santo','BANCARIO'),
    ('2026-04-03','Viernes Santo','BANCARIO'),
    ('2026-05-01','Dia del Trabajo','OFICIAL'),
    ('2026-09-16','Independencia','OFICIAL'),
    ('2026-11-02','Dia de Muertos','BANCARIO'),
    ('2026-11-16','Revolucion Mexicana','OFICIAL'),
    ('2026-12-12','Virgen de Guadalupe','BANCARIO'),
    ('2026-12-25','Navidad','OFICIAL'),
    ('2027-01-01','Ano Nuevo','OFICIAL'),
    ('2027-02-01','Dia de la Constitucion','OFICIAL'),
    ('2027-03-15','Natalicio de Benito Juarez','OFICIAL'),
    ('2027-03-25','Jueves Santo','BANCARIO'),
    ('2027-03-26','Viernes Santo','BANCARIO'),
    ('2027-05-01','Dia del Trabajo','OFICIAL'),
    ('2027-09-16','Independencia','OFICIAL'),
    ('2027-11-02','Dia de Muertos','BANCARIO'),
    ('2027-11-15','Revolucion Mexicana','OFICIAL'),
    ('2027-12-12','Virgen de Guadalupe','BANCARIO'),
    ('2027-12-25','Navidad','OFICIAL'),
    ('2028-01-01','Ano Nuevo','OFICIAL'),
    ('2028-02-07','Dia de la Constitucion','OFICIAL'),
    ('2028-03-20','Natalicio de Benito Juarez','OFICIAL'),
    ('2028-04-13','Jueves Santo','BANCARIO'),
    ('2028-04-14','Viernes Santo','BANCARIO'),
    ('2028-05-01','Dia del Trabajo','OFICIAL'),
    ('2028-09-16','Independencia','OFICIAL'),
    ('2028-11-02','Dia de Muertos','BANCARIO'),
    ('2028-11-20','Revolucion Mexicana','OFICIAL'),
    ('2028-12-12','Virgen de Guadalupe','BANCARIO'),
    ('2028-12-25','Navidad','OFICIAL'),
    ('2029-01-01','Ano Nuevo','OFICIAL'),
    ('2029-02-05','Dia de la Constitucion','OFICIAL'),
    ('2029-03-19','Natalicio de Benito Juarez','OFICIAL'),
    ('2029-03-29','Jueves Santo','BANCARIO'),
    ('2029-03-30','Viernes Santo','BANCARIO'),
    ('2029-05-01','Dia del Trabajo','OFICIAL'),
    ('2029-09-16','Independencia','OFICIAL'),
    ('2029-11-02','Dia de Muertos','BANCARIO'),
    ('2029-11-19','Revolucion Mexicana','OFICIAL'),
    ('2029-12-12','Virgen de Guadalupe','BANCARIO'),
    ('2029-12-25','Navidad','OFICIAL'),
    ('2030-01-01','Ano Nuevo','OFICIAL'),
    ('2030-02-04','Dia de la Constitucion','OFICIAL'),
    ('2030-03-18','Natalicio de Benito Juarez','OFICIAL'),
    ('2030-04-18','Jueves Santo','BANCARIO'),
    ('2030-04-19','Viernes Santo','BANCARIO'),
    ('2030-05-01','Dia del Trabajo','OFICIAL'),
    ('2030-09-16','Independencia','OFICIAL'),
    ('2030-10-01','Transmision del Poder Ejecutivo','OFICIAL'),
    ('2030-11-02','Dia de Muertos','BANCARIO'),
    ('2030-11-18','Revolucion Mexicana','OFICIAL'),
    ('2030-12-12','Virgen de Guadalupe','BANCARIO'),
    ('2030-12-25','Navidad','OFICIAL')
) v(fecha, nombre, tipo)
WHERE NOT EXISTS (SELECT 1 FROM gold.dim_festivo f WHERE f.fecha = v.fecha);
GO

SELECT anio = YEAR(fecha), festivos = COUNT(*) FROM gold.dim_festivo GROUP BY YEAR(fecha) ORDER BY 1;
GO
