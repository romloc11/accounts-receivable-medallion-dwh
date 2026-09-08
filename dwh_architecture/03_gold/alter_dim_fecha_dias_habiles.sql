USE ANALISIS_DATOS;
GO

/*
========================================================================================
gold.dim_fecha  ->  columnas de dias habiles  (2026-09-08)
========================================================================================
ALTER in place: dim_fecha ya esta poblada y la referencian varios hechos, no se recrea.

--- PARA QUE ---
El presupuesto de cobranza reparte dinero por dia. Hasta hoy dim_fecha solo sabia
es_fin_de_semana, asi que "los domingos no entra dinero" y "los festivos tampoco" vivian
como porcentajes en la cabeza de quien arma el presupuesto. Con estas columnas dejan de
ser porcentaje y se vuelven regla.

Medido sobre 2023-2026 (gold.fact_pagos, fecha_documento):
    dia habil normal   $7.57M promedio   100%
    sabado             $0.07M              0.9%
    festivo            $0.04M              0.5%
    domingo            $0.02M              0.2%

--- LAS COLUMNAS ---
es_festivo / nombre_festivo   de gold.dim_festivo (lista mantenida a mano, ver ese archivo)
es_dia_habil                  ni fin de semana ni festivo
dia_habil_del_mes             1..N contando solo habiles. NULL si el dia no es habil.
                              Es lo que hace medible el patron "cobran a fin de mes":
                              el ultimo dia habil es dia_habil_del_mes = dias_habiles_mes,
                              sin importar si cae 28, 30 o 31.
dias_habiles_mes              total de habiles del mes, en cada fila del mes
siguiente_dia_habil           el mismo dia si es habil; si no, el siguiente que lo sea.
                              Aqui vive la regla del pronostico: fecha de pago predicha
                              que cae en domingo o festivo se recorre, no se pierde.

--- SE RECALCULAN COMPLETAS EN CADA CORRIDA, A PROPOSITO ---
gold.load_dim_fecha solo INSERTA dias nuevos, nunca actualiza los viejos. Pero estas
columnas no dependen solo de la fila: dia_habil_del_mes y dias_habiles_mes dependen del
MES entero, y todas dependen de dim_festivo, que puede crecer despues. Si se calcularan
solo al insertar, agregar un festivo de 2027 dejaria mal numerado todo ese mes y nadie
se enteraria. Son ~72K filas: recalcular todo cuesta menos de un segundo.
========================================================================================
*/

IF COL_LENGTH('gold.dim_fecha', 'es_festivo') IS NULL
    ALTER TABLE gold.dim_fecha ADD es_festivo BIT NOT NULL DEFAULT 0;
GO
IF COL_LENGTH('gold.dim_fecha', 'nombre_festivo') IS NULL
    ALTER TABLE gold.dim_fecha ADD nombre_festivo VARCHAR(40) NULL;
GO
IF COL_LENGTH('gold.dim_fecha', 'es_dia_habil') IS NULL
    ALTER TABLE gold.dim_fecha ADD es_dia_habil BIT NOT NULL DEFAULT 0;
GO
IF COL_LENGTH('gold.dim_fecha', 'dia_habil_del_mes') IS NULL
    ALTER TABLE gold.dim_fecha ADD dia_habil_del_mes INT NULL;
GO
IF COL_LENGTH('gold.dim_fecha', 'dias_habiles_mes') IS NULL
    ALTER TABLE gold.dim_fecha ADD dias_habiles_mes INT NULL;
GO
IF COL_LENGTH('gold.dim_fecha', 'siguiente_dia_habil') IS NULL
    ALTER TABLE gold.dim_fecha ADD siguiente_dia_habil DATE NULL;
GO

PRINT 'Columnas listas. gold.load_dim_fecha las puebla en la siguiente corrida.';
GO
