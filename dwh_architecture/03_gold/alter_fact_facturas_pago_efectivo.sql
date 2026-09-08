USE ANALISIS_DATOS;
GO

/*
========================================================================================
gold.fact_facturas -> fecha_pago_efectiva, dias_pago, clasificacion_cobranza (2026-09-08)
========================================================================================
ALTER in place: la tabla trae el backfill 2022->hoy, no se recrea.

--- POR QUE VIVEN AQUI Y NO EN EL BI ---
Estaban calculadas dentro de la consulta M del .pbip. Dos razones para bajarlas al DWH:
  1. El pronostico de presupuesto las necesita como VARIABLE OBJETIVO, y Python no
     deberia tener que pasar por Power BI para entrenarse.
  2. Recalcularlas en cada refresh cuesta ~15 s de mas y esconde la logica de negocio
     en un archivo que ademas esta en .gitignore.

--- POR QUE NO SE PUEBLAN EN load_fact_facturas ---
Salen del PUENTE (gold.fact_aplicacion_pagos), que se carga DESPUES de fact_facturas.
En el orden del orquestador, cuando corre load_fact_facturas el puente todavia trae la
ventana anterior. Por eso hay un proc aparte que corre despues del puente.

--- POR QUE AQUI Y NO EN gold.fact_aplicacion_pagos (EL PUENTE) ---
Es una pregunta razonable y la respuesta es el GRANO. El puente esta al grano
pago x factura; estas tres columnas son propiedades de la FACTURA, no de la pareja.
  1. Una factura liquidada con 3 pagos tendria 3 valores distintos de dias_pago, y
     cualquier agregacion tendria que elegir uno o los cuenta triple.
  2. El DPP ponderado se rompe: Sum(dias x monto) / Sum(monto) con dias en el puente y
     monto en la factura multiplica ENTRE granos, y la factura aporta su monto completo
     una vez por pago, arriba y abajo. Ese es exactamente el bug que traia el modelo
     anterior (SUMX(fact_cobranza, [Dias Pago] * [Monto Factura])).
  3. NULL significa 'no se ha pagado' - 549,063 facturas - y el puente no puede expresar
     ausencia: simplemente no hay fila, y habria que hacer anti-join cada vez.
  4. El pronostico de presupuesto entrena POR FACTURA: una fila, una etiqueta.

--- SOBRE EL MAX(): MEDIDO, NO SUPUESTO ---
fecha_pago_efectiva es MAX(fecha del pago), o sea 'cuando quedo saldada'. Para una
factura pagada en parcialidades eso sobreestima la espera. Cuanto importa:
    1 solo pago      2,682,072 facturas   $7,606.7M   97.7% del dinero
    2 pagos             18,862            $  112.1M    1.4%  (6 dias de separacion)
    3 a 5 pagos         15,831            $   55.7M    0.7%  (19 dias)
    mas de 5             6,430            $   13.3M    0.2%
El 97.7% del dinero tiene un solo pago: ahi MAX no colapsa nada. La objecion aplica al
2.3% restante. LIMITACION CONOCIDA Y ACOTADA: al pronosticar flujo diario ese 2.3% cae
en la fecha del ultimo pago en vez de repartido. El detalle no se pierde - el puente
unido a fact_pagos lo tiene - simplemente no se duplica aqui.

--- LAS COLUMNAS ---
fecha_pago_efectiva     fecha del ULTIMO pago que liquido la factura. Es fecha_documento
                        del pago -cuando pago el cliente-, NO fecha_contabilizacion
                        -cuando lo capturo contabilidad-. Coinciden en 99.82% de los
                        casos pero significan cosas distintas; para medir comportamiento
                        de pago la buena es la del cliente.
                        NULL cuando ningun deposito la liquido: cartera abierta, o se
                        liquido con algo que no es dinero (nota de credito, ajuste, AB).
                        Medido: 2,723,195 de 3,272,258 facturas la tienen.
dias_pago               DATEDIFF(dia, vencimiento, fecha_pago_efectiva).
                        NEGATIVO = pago antes de vencer. Medido 2025->: el 30.5% del
                        dinero se paga anticipado, 22.3% justo a tiempo, 36.2% de 1 a 7
                        dias tarde. Solo 0.1% pasa de 30 dias.
clasificacion_cobranza  compara el vencimiento contra el MES de la fecha de pago:
                        PAGO_A_VENCIMIENTO  ya estaba vencida antes de ese mes
                        PAGO_A_MES          vencia en el mismo mes en que se pago
                        PAGO_ANTICIPADO     vencia despues
                        Misma regla que traia vw_pago_factura_simple, ahora por FACTURA
                        y no por pareja pago-factura.
========================================================================================
*/

IF COL_LENGTH('gold.fact_facturas', 'fecha_pago_efectiva') IS NULL
    ALTER TABLE gold.fact_facturas ADD fecha_pago_efectiva DATE NULL;
GO
IF COL_LENGTH('gold.fact_facturas', 'dias_pago') IS NULL
    ALTER TABLE gold.fact_facturas ADD dias_pago INT NULL;
GO
IF COL_LENGTH('gold.fact_facturas', 'clasificacion_cobranza') IS NULL
    ALTER TABLE gold.fact_facturas ADD clasificacion_cobranza VARCHAR(20) NULL;
GO

PRINT 'Columnas listas. gold.load_fact_facturas_pago_efectivo las puebla.';
GO
