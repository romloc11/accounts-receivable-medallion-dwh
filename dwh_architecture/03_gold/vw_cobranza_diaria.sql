/* =====================================================================================
   gold.vw_cobranza_diaria
   dwh_architecture/03_gold/vw_cobranza_diaria.sql                   (2026-09-09)
   =====================================================================================

   La cobranza real de cada dia. Un renglon por fecha con caja (1,609 desde 2019).

   POR QUE ESTO EXISTE
   -------------------
   gold.fact_presupuesto_cobranza nacio con una columna monto_real que se llenaba al
   correr el proc - o sea UNA VEZ AL MES - y nunca se refrescaba. Para un reporte de
   seguimiento diario eso no sirve: al dia 20 seguia mostrando lo que se sabia el dia 4.

   La correccion no es "agregarle un refresh", es separar dos cosas que tienen
   naturalezas distintas:

       el PRONOSTICO se congela   -> gold.fact_presupuesto_cobranza
       lo REAL se refresca solo   -> esta vista

   Mezclarlas en una tabla obliga a elegir una de las dos disciplinas para las dos.

   POR QUE VISTA Y NO TABLA
   ------------------------
   Una tabla necesitaria su proc, su renglon en gold.load_gold y su lugar en el orden de
   carga - y podria quedarse rancia sin que nadie se entere, que es exactamente el
   problema que se esta arreglando. Agregar 614 mil pagos a 1,609 dias es sub-segundo,
   asi que la vista se calcula al vuelo, nunca miente, y no agrega nada al orquestador.
   Si algun dia fact_pagos crece lo suficiente para que pese, materializarla es un
   cambio local: misma forma, mismo nombre.

   LA REGLA DE ALCANCE, AUNQUE HOY NO CAMBIE NADA
   ----------------------------------------------
   Se filtra estatus_comercial <> 'FUERA_DE_ALCANCE' resuelto A LA FECHA DEL PAGO.
   Medido sobre 2026: la caja fuera de alcance es 0.000% de $1,220.6M - fact_pagos no
   arrastra la fuga que si tiene fact_facturas, porque los clientes fuera de alcance
   simplemente no pagan: el mayor de ellos no factura desde hace anios.
   Se filtra igual. Lo real y el presupuesto tienen que salir de la MISMA poblacion, y
   que hoy coincidan por casualidad no es lo mismo que garantizarlo por construccion:
   el dia que un cliente fuera de alcance pague, las dos series se separarian sin que
   nada avise.

   OJO AL COMPARAR CONTRA EL REPORTE DE FLUJO DE PAGOS
   ---------------------------------------------------
   Esta vista mide CAJA (gold.fact_pagos, por fecha_documento del pago). El reporte de
   flujo mide FACTURAS LIQUIDADAS (por fecha_pago_efectiva). No van a cuadrar exacto:
   se separan por el ~3.5% de pagos no ligados y por las facturas que reciben dinero en
   dos meses distintos. Son dos preguntas distintas y esta bien que den distinto - lo
   que no esta bien es que nadie sepa por que.
   ===================================================================================== */

USE ANALISIS_DATOS;
GO

IF OBJECT_ID('gold.vw_cobranza_diaria') IS NOT NULL
    DROP VIEW gold.vw_cobranza_diaria;
GO

CREATE VIEW gold.vw_cobranza_diaria
AS
SELECT
    g.fecha_documento           AS fecha,
    SUM(g.monto)                AS monto_real,
    COUNT(*)                    AS n_pagos,
    COUNT(DISTINCT g.cliente_id) AS n_clientes
FROM   gold.fact_pagos g
JOIN   gold.dim_cliente_comercial d
       ON  d.cliente_id = g.cliente_id
       AND g.fecha_documento >= d.fecha_inicio_vigencia
       AND (d.fecha_fin_vigencia IS NULL OR g.fecha_documento <= d.fecha_fin_vigencia)
       AND d.estatus_comercial <> 'FUERA_DE_ALCANCE'
       AND d.canal_distribucion IN (10, 40, 60)
GROUP BY g.fecha_documento;
GO

PRINT 'View gold.vw_cobranza_diaria created.';
GO
