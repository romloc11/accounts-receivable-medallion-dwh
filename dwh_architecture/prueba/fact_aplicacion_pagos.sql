/*
========================================================================================
dbo.fact_aplicacion_pagos  -  el PUENTE: que facturas toco cada pago
========================================================================================
CONTROL (2026-09-07): 54,800 filas
    GRUPO          52,633 filas | 10,661 documentos | $135,929,118  (91.1%)
    SEGUNDO_SALTO   2,114 filas |  1,333 documentos | $ 11,364,353  ( 7.6%)
    REFERENCIA         53 filas |    ~46 documentos | $     76,797  ( 0.1%)
    ----------------------------------------------------------------------
    ligado                                          | $147,370,269  (98.7%)
    sin ligar                   |     37 lineas     | $  1,874,426  ( 1.3%)

--- POR QUE ESTA TABLA NO TIENE COLUMNA DE MONTO ---
Es la decision central del diseno. El join produce filas al grano (pago x factura), y
ahi NINGUN monto es aditivo: ni el del pago ni el de la factura. Los dos vienen
heredados de un grano mas grueso, asi que sumarlos duplica.
    SUM(monto_pago) sobre el join = $11,427,680,334   <- 83x inflado
    lo correcto                   = $  147,293,472
El puente responde "que facturas toco este pago". El dinero se suma desde fact_pagos y
fact_facturas, cada una en su propio grano, con EXISTS (ver el bloque de consumo abajo).

--- POR QUE LA PK TIENE SEIS COLUMNAS ---
Es la llave natural completa: la PK del pago mas la PK de la factura. Se ve pesada pero
hace imposible un duplicado por construccion. Con menos no alcanza: el documento
1402635349 tiene dos lineas de pago apuntando al mismo grupo, asi que (pago, factura)
colisiona sin `posicion_pago`.

--- LAS TRES REGLAS ---
GRUPO          el grupo de compensacion del pago YA contiene las facturas. Es el caso
               normal: pago y factura se liquidaron en el mismo evento.
SEGUNDO_SALTO  el grupo del pago NO trae facturas porque es un documento intermedio
               ("hijo"): reemite el dinero con lineas clave 15 que se compensan contra
               SU PROPIO grupo final, y ahi estan las facturas.
REFERENCIA     el hijo tiene una linea clave 15 que quedo ABIERTA, con REBZG apuntando
               a una factura que TAMBIEN sigue abierta. Es el pago parcial: el dinero
               entro y se abono, pero no alcanzo a liquidar la factura.
Las tres usan solo llaves nativas de SAP. No hay reparto proporcional ni heuristica en
ninguna: cada fila es algo que SAP afirma, no algo que nosotros dedujimos.
GRUPO y SEGUNDO_SALTO son mutuamente excluyentes por construccion. REFERENCIA NO lo es,
y a proposito: 26 de sus pagos ya estaban ligados por otra regla y ganan una factura
mas (un deposito puede liquidar tres facturas y abonar a una cuarta). Verificado: 0
colisiones de llave con lo ya cargado.

--- QUE SIGNIFICA CADA FILA (leer antes de reportar) ---
GRUPO y SEGUNDO_SALTO dicen "este pago LIQUIDO esta factura".
REFERENCIA dice "este pago ABONO a esta factura, que sigue abierta".
Son dos afirmaciones distintas. Es la unica regla que aterriza en facturas abiertas -
las otras dos van por documento_compensacion, y una partida abierta no lo tiene.

--- LO QUE QUEDA SIN LIGAR, CON NOMBRE ---
37 lineas / $1,874,426, mayormente: pagos cuyo salto llega a un grupo sin facturas, y
pagos sin salto. Las 3 lineas clave 08 se excluyen a proposito (debitos espejo).
Ahi adentro esta Kushky: el dinero de una pasarela llega agregado, no factura por
factura, asi que estructuralmente no tiene a que apuntar. No es un defecto por corregir.

========================================================================================
*/

IF OBJECT_ID('dbo.fact_aplicacion_pagos', 'U') IS NOT NULL
    DROP TABLE dbo.fact_aplicacion_pagos;
GO

CREATE TABLE dbo.fact_aplicacion_pagos (
    cliente_id              VARCHAR(10) NOT NULL,

    ejercicio_pago          INT         NOT NULL,
    pago_id                 VARCHAR(10) NOT NULL,
    posicion_pago           INT         NOT NULL,

    ejercicio_factura       INT         NOT NULL,
    factura_id              VARCHAR(10) NOT NULL,
    posicion_factura        INT         NOT NULL,

    -- El grupo donde REALMENTE esta la factura. En SEGUNDO_SALTO es el grupo final,
    -- no el del pago: hace la cadena auditable hacia atras.
    documento_compensacion  VARCHAR(10) NOT NULL,
    fecha_compensacion      DATE        NULL,
    regla                   VARCHAR(20) NOT NULL,

    fecha_carga             DATE        NOT NULL
        CONSTRAINT DF_fap_carga DEFAULT CAST(GETDATE() AS DATE),

    CONSTRAINT PK_fact_aplicacion_pagos PRIMARY KEY (
        ejercicio_pago, pago_id, posicion_pago,
        ejercicio_factura, factura_id, posicion_factura
    )
);
GO

-- Para navegar en el otro sentido: que pagos liquidaron esta factura.
CREATE INDEX IX_fap_factura ON dbo.fact_aplicacion_pagos
    (ejercicio_factura, factura_id, posicion_factura);
GO


-- ========================================================================================
-- REGLA 1 - GRUPO       52,633 filas
-- ========================================================================================
INSERT INTO dbo.fact_aplicacion_pagos (
    cliente_id, ejercicio_pago, pago_id, posicion_pago,
    ejercicio_factura, factura_id, posicion_factura,
    documento_compensacion, fecha_compensacion, regla
)
SELECT p.cliente_id,
       p.ejercicio, p.documento_id, p.posicion,
       f.ejercicio, f.documento_id, f.posicion,
       p.documento_compensacion,
       p.fecha_compensacion,
       'GRUPO'
FROM   dbo.fact_pagos p
JOIN   dbo.fact_facturas f
       ON f.documento_compensacion = p.documento_compensacion;
GO


-- ========================================================================================
-- REGLA 2 - SEGUNDO_SALTO       2,114 filas
-- ========================================================================================

-- El salto, al grano (hijo, grupo_final) AGREGADO. Por linea seria incorrecto: un hijo
-- con 3 lineas clave 15 hacia el mismo grupo final duplicaria cada factura 3 veces.
IF OBJECT_ID('tempdb..#salto') IS NOT NULL DROP TABLE #salto;
SELECT   h.documento_id            AS hijo,
         h.documento_compensacion  AS grupo_final,
         SUM(h.monto_moneda_local) AS monto_aplicado
INTO     #salto
FROM     silver.sap_bsad h
WHERE    h.mandante = '400' AND h.clase_documento = 'DZ'
  AND    h.clave_contabilizacion = '15'
  AND    h.documento_compensacion IS NOT NULL
GROUP BY h.documento_id, h.documento_compensacion;
CREATE UNIQUE CLUSTERED INDEX ix_salto ON #salto(hijo, grupo_final);

-- Guarda: cuantos DOCUMENTOS DE PAGO alimentan al intermedio. Si es mas de uno, el
-- dinero se mezclo ahi dentro y no se puede decir cual financio que linea.
--
-- Cuenta documentos de pago (claves 11 y 15), NO solo virgenes: los pagos directos
-- tambien participan del segundo salto - la estructura es la misma - y "un virgen
-- detras" no significa nada cuando no hay virgen. Son 106 pagos / $552,054.
--
-- Julio 2026: en SEGUNDO_SALTO no excluye nada; en REFERENCIA excluye 1 fila de 54.
-- Y en toda la historia hay 81 intermedios con varios pagos (750 documentos). No es
-- decorativa: va en serio.
IF OBJECT_ID('tempdb..#guarda') IS NOT NULL DROP TABLE #guarda;
SELECT   documento_compensacion AS intermedio,
         COUNT(DISTINCT documento_id) AS n_pagos
INTO     #guarda
FROM     silver.sap_bsad
WHERE    mandante = '400' AND clase_documento = 'DZ' AND debe_haber = 'H'
  AND    clave_contabilizacion IN ('11','15')
  AND    documento_compensacion IS NOT NULL
GROUP BY documento_compensacion;
CREATE UNIQUE CLUSTERED INDEX ix_guarda ON #guarda(intermedio);


INSERT INTO dbo.fact_aplicacion_pagos (
    cliente_id, ejercicio_pago, pago_id, posicion_pago,
    ejercicio_factura, factura_id, posicion_factura,
    documento_compensacion, fecha_compensacion, regla
)
SELECT p.cliente_id,
       p.ejercicio, p.documento_id, p.posicion,
       f.ejercicio, f.documento_id, f.posicion,
       s.grupo_final,            -- el grupo donde esta la factura, no el del pago
       p.fecha_compensacion,
       'SEGUNDO_SALTO'
FROM   dbo.fact_pagos p
JOIN   #salto s            ON s.hijo = p.documento_compensacion
JOIN   dbo.fact_facturas f ON f.documento_compensacion = s.grupo_final
-- LEFT JOIN, nunca INNER: la guarda es un dato de control, no un filtro. Con INNER
-- tiraba en silencio 109 pagos legitimos (los que no son virgenes y por tanto no
-- estaban en #guarda). Mismo patron de error que un EXISTS sin calificar: una
-- construccion que parece consulta y actua como filtro.
LEFT JOIN #guarda g        ON g.intermedio = p.documento_compensacion
-- Las lineas clave 08 quedan fuera POR DECISION, no por accidente de un join: son
-- debitos espejo y atribuirles facturas no significa nada (su monto es negativo).
WHERE  p.clave_contabilizacion IN ('11','15')
  AND  ISNULL(g.n_pagos, 1) = 1
  -- Solo donde la regla GRUPO no encontro nada. Esto las hace excluyentes.
  AND  NOT EXISTS (SELECT 1 FROM dbo.fact_facturas ff
                   WHERE ff.documento_compensacion = p.documento_compensacion);
GO


-- ========================================================================================
-- REGLA 3 - REFERENCIA       53 filas       (reutiliza #guarda de la regla 2)
-- ========================================================================================
INSERT INTO dbo.fact_aplicacion_pagos (
    cliente_id, ejercicio_pago, pago_id, posicion_pago,
    ejercicio_factura, factura_id, posicion_factura,
    documento_compensacion, fecha_compensacion, regla
)
SELECT p.cliente_id,
       p.ejercicio, p.documento_id, p.posicion,
       f.ejercicio, f.documento_id, f.posicion,
       p.documento_compensacion,   -- el hijo: la factura abierta no tiene grupo propio
       p.fecha_compensacion,
       'REFERENCIA'
FROM   dbo.fact_pagos p
-- La linea clave 15 del hijo que quedo ABIERTA, con REBZG: la referencia nativa de SAP
-- a UNA factura. El deposito virgen NUNCA la trae - 0 de 10,851 en julio, todos 'V'.
-- La referencia vive aqui, en la linea de aplicacion del hijo, no en el pago.
JOIN   silver.sap_bsid a
       ON  a.documento_id          = p.documento_compensacion
       AND a.mandante              = '400'
       AND a.clase_documento       = 'DZ'
       AND a.clave_contabilizacion = '15'
       AND a.factura_referencia_documento IS NOT NULL
       AND a.factura_referencia_documento <> 'V'
JOIN   dbo.fact_facturas f
       ON  f.documento_id = a.factura_referencia_documento
       AND f.ejercicio    = a.factura_referencia_ejercicio
       -- SOLO facturas ABIERTAS. Sin esto entran 14 lineas mas ($1,488.12) donde la
       -- linea de pago sigue abierta pero la factura ya se liquido: eso no es un pago
       -- parcial, es dinero sin aplicar cuya factura se salda por otro lado.
       -- Atribuirsela diria que este pago la liquido, y no fue asi.
       AND f.flag_compensada = 0
LEFT JOIN #guarda g ON g.intermedio = p.documento_compensacion
WHERE  p.clave_contabilizacion IN ('11','15')
  -- Aqui la guarda SI muerde: excluye 1 fila de 54. Es el unico caso medido donde un
  -- hijo tiene varios pagos detras y el dinero se mezclo dentro.
  AND  ISNULL(g.n_pagos, 1) = 1;
GO


-- ========================================================================================
-- Verificacion
-- ========================================================================================
SELECT regla, COUNT(*) AS filas, COUNT(DISTINCT pago_id) AS pagos
FROM   dbo.fact_aplicacion_pagos
GROUP BY regla;
-- GRUPO 52,633 / 10,661   |   SEGUNDO_SALTO 2,114 / 1,333   |   REFERENCIA 53 / ~46


-- ========================================================================================
-- COMO SE CONSUME EL DINERO  -  NUNCA sumando sobre el puente
-- ========================================================================================
-- Cobranza aplicada a facturas. Sin join, imposible que infle.
SELECT SUM(p.monto)      -- 147,370,268.58
FROM   dbo.fact_pagos p
WHERE  EXISTS (SELECT 1 FROM dbo.fact_aplicacion_pagos a
               WHERE  a.ejercicio_pago = p.ejercicio
                 AND  a.pago_id       = p.documento_id
                 AND  a.posicion_pago = p.posicion);

-- El mismo patron invertido da el lado de facturas.
GO
