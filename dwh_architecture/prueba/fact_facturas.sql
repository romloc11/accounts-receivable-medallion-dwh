/*
========================================================================================
dbo.fact_facturas  -  lo que se DEBE, una fila por linea de factura
========================================================================================
Dos poblaciones en una tabla, separadas por flag_compensada:
  compensadas (bsad) -> ya liquidadas, tienen documento_compensacion
  abiertas    (bsid) -> siguen vivas, documento_compensacion NULL SIEMPRE

CONTROL (2026-09-07): 217,086 filas = 146,119 compensadas + 70,967 abiertas

LAS ABIERTAS NO PARTICIPAN DEL PUENTE. Verificado: 0 de ellas entran al join, porque
no tienen documento_compensacion. Estan aqui para analisis de cartera y para la regla
del pago parcial (R3, sin implementar), no para ligar pagos.

--- POR QUE LA VENTANA DE LAS COMPENSADAS NO TIENE TOPE SUPERIOR ---
Se filtra `fecha_compensacion >= '2026-07-01'` SIN `< '2026-08-01'`, y no es un olvido.
Un pago compensado en julio puede alcanzar, via el segundo salto
(virgen -> hijo -> grupo final), una factura que se compenso DESPUES. La cadena solo
avanza en el tiempo, nunca retrocede - medido: los grupos finales que faltaban cayeron
en 2026-08 (290 facturas) y 2026-09 (3), ninguno antes de julio.
El techo truncaba 157 pagos / $1,655,522. El piso es el que define el alcance.

--- POR QUE fecha_compensacion Y NO fecha_documento ---
Todas las lineas de un grupo comparten fecha_compensacion (verificado: 0 grupos con
fecha no uniforme; el evento de compensacion las estampa a todas igual). Filtrar por
ahi alcanza las 52,580 lineas relevantes sin perder ninguna.
Con fecha_documento se perdian 69 facturas viejas liquidadas en julio, y el piso de
enero era arbitrario respecto a la ventana de pagos.

--- D1 ---
Incluido ademas de F%: D1 es deuda, o sea si es algo por cobrar. Decision del usuario
2026-09-07. Las clases que existen en los datos son F1, F2, F3, F4, F5 y D1 - `F6` no
existe (estaba de mas en la version anterior de este script).

--- RESET DE COMPENSACION (FBRA) ---
11 lineas estan en bsad Y en bsid a la vez: se compensaron, y despues alguien deshizo
la compensacion. bsad conserva el registro historico; bsid refleja el estado de HOY.
GANA BSID. Sin excluirlas del lado compensado, la misma linea entra dos veces y revienta
la PK - y peor, el modelo diria que una factura esta pagada cuando sigue abierta.

PK (ejercicio, documento_id, posicion): igual que fact_pagos, documento_id no basta -
hay 40 documentos con dos lineas.
========================================================================================
*/

IF OBJECT_ID('dbo.fact_facturas', 'U') IS NOT NULL
    DROP TABLE dbo.fact_facturas;
GO

CREATE TABLE dbo.fact_facturas (
    cliente_id              VARCHAR(10)   NOT NULL,
    ejercicio               INT           NOT NULL,
    documento_id            VARCHAR(10)   NOT NULL,
    posicion                INT           NOT NULL,
    documento_compensacion  VARCHAR(10)   NULL,
    clase_documento         VARCHAR(2)    NOT NULL,   -- distingue factura (F*) de deuda (D1)
    fecha_documento         DATE          NULL,
    fecha_vencimiento       DATE          NULL,
    fecha_contabilizacion   DATE          NULL,
    fecha_compensacion      DATE          NULL,
    monto                   DECIMAL(15,2) NOT NULL,
    clave_contabilizacion   VARCHAR(2)    NULL,
    flag_compensada         BIT           NOT NULL,
    fecha_carga             DATE          NOT NULL
        CONSTRAINT DF_fact_facturas_carga DEFAULT CAST(GETDATE() AS DATE),
    CONSTRAINT PK_fact_facturas PRIMARY KEY (ejercicio, documento_id, posicion)
);
GO

CREATE INDEX IX_fact_facturas_grupo ON dbo.fact_facturas (documento_compensacion);
GO


INSERT INTO dbo.fact_facturas (
    cliente_id, ejercicio, documento_id, posicion, documento_compensacion,
    clase_documento, fecha_documento, fecha_vencimiento, fecha_contabilizacion,
    fecha_compensacion, monto, clave_contabilizacion, flag_compensada
)
-- ---------- COMPENSADAS ----------
SELECT b.cliente_id, b.ejercicio, b.documento_id, b.posicion, b.documento_compensacion,
       b.clase_documento, b.fecha_documento, b.fecha_vencimiento, b.fecha_contabilizacion,
       b.fecha_compensacion, b.monto_moneda_local, b.clave_contabilizacion,
       CAST(1 AS BIT)
FROM   silver.sap_bsad b
WHERE  b.mandante = '400'
  AND  b.debe_haber = 'S'
  AND  (b.clase_documento LIKE 'F%' OR b.clase_documento = 'D1')
  AND  b.fecha_compensacion >= '2026-07-01'      -- SIN tope superior, ver cabecera
  AND  b.cliente_id IN (
           SELECT c1.cliente_id FROM gold.dim_cliente_comercial c1
           WHERE  c1.estatus_comercial <> 'FUERA_DE_ALCANCE'
             AND  c1.canal_distribucion IN (10, 40, 60))
  -- Reset de compensacion: si la linea tambien esta en bsid, gana bsid (ver cabecera).
  AND  NOT EXISTS (
           SELECT 1
           FROM   silver.sap_bsid i
           WHERE  i.mandante     = b.mandante
             AND  i.sociedad     = b.sociedad
             AND  i.cliente_id   = b.cliente_id
             AND  i.ejercicio    = b.ejercicio
             AND  i.documento_id = b.documento_id
             AND  i.posicion     = b.posicion
       )

UNION ALL

-- ---------- ABIERTAS ----------
-- Sin filtro de fecha a proposito: una partida abierta lo esta sin importar cuando
-- nacio, y no tiene fecha_compensacion contra la cual filtrar.
SELECT b.cliente_id, b.ejercicio, b.documento_id, b.posicion, NULL,
       b.clase_documento, b.fecha_documento, b.fecha_vencimiento, b.fecha_contabilizacion,
       NULL, b.monto_moneda_local, b.clave_contabilizacion,
       CAST(0 AS BIT)
FROM   silver.sap_bsid b
WHERE  b.mandante = '400'
  AND  b.debe_haber = 'S'
  AND  (b.clase_documento LIKE 'F%' OR b.clase_documento = 'D1')
  AND  b.cliente_id IN (
           SELECT c1.cliente_id FROM gold.dim_cliente_comercial c1
           WHERE  c1.estatus_comercial <> 'FUERA_DE_ALCANCE'
             AND  c1.canal_distribucion IN (10, 40, 60));
GO


-- ========================================================================================
-- Verificacion:  compensadas 146,119  |  abiertas 70,967  |  total 217,086
-- ========================================================================================
SELECT flag_compensada, COUNT(*) AS filas,
       CAST(SUM(monto) AS DECIMAL(18,2)) AS monto
FROM   dbo.fact_facturas
GROUP BY flag_compensada;
GO
