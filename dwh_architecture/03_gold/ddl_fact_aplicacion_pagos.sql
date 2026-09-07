USE ANALISIS_DATOS;
GO

/*
========================================================================================
MODELO DE APLICACION DE PAGOS  -  4 tablas nuevas en gold
========================================================================================
Promocion a gold del modelo construido y validado en dwh_architecture/prueba/ durante
2026-09-06/07. Sustituye conceptualmente a vw_pago_factura_simple +
fact_pagos_compensados + fact_facturas_compensadas, pero NO los elimina: esos objetos
se quedan vivos hasta que el modelo nuevo este completo y tenga su propio reporte
(decision del usuario 2026-09-07). Conviven sin conflicto - nombres distintos, cargas
independientes.

    gold.fact_pagos                 el dinero que entro          ~614K filas (2022->hoy)
    gold.fact_facturas              lo que se debe               ~3.27M filas
    gold.fact_aplicacion_pagos      el puente pago<->factura     ~3-3.5M filas
    gold.fact_pagos_sin_aplicacion  el dinero sin factura        ~2-3K filas

--- ESTE ARCHIVO NO ES ddl_gold.sql, Y ES A PROPOSITO ---
ddl_gold.sql hace DROP de TODAS las tablas de la capa. Meter aqui una tabla nueva
obligaria a correr ese archivo completo para crearla, con el riesgo de borrar gold
entero. Va aparte. Cada bloque de abajo es autonomo: se puede correr solo el que se
necesite.

--- LA DECISION CENTRAL: EL PUENTE NO LLEVA MONTO ---
fact_aplicacion_pagos esta al grano (pago x factura) y ahi NINGUN monto es aditivo -
ni el del pago ni el de la factura: los dos vienen heredados de un grano mas grueso.
Medido en julio 2026: SUM sobre el join da $11,427,680,334 contra los $147,293,472
correctos, 83x inflado. El puente responde "que facturas toco este pago". El dinero se
suma desde fact_pagos y fact_facturas con EXISTS.
Consecuencia deliberada: NO existe un "monto asignado" por pareja pago-factura. En un
grupo con varios pagos y varias facturas ese reparto seria inventado. vw_pago_factura_simple
si lo calcula (monto_pago_asignado); este modelo se niega, y cualquier medida que lo use
tendra que rediseñarse, no traducirse.

--- HISTORIA COMPLETA DESDE 2022 (decision del usuario 2026-09-07) ---
Las facturas compensadas se cargan completas, no en ventana movil. Eso elimina el
"margen empirico" que necesitaba el modelo de prueba: con toda la historia, la factura
del grupo final SIEMPRE esta, asi que la regla del segundo salto deja de depender de una
cobertura observada y pasa a ser exacta.
========================================================================================
*/


-- ========================================================================================
-- 1. gold.fact_pagos  -  el dinero que ENTRO. 1 fila = 1 linea de pago.
--
-- QUE CUENTA COMO PAGO (validado contra SAP en julio 2026: $149,244,694.89 exacto):
--   clave 11 = deposito virgen (el dinero llegando al banco)
--   clave 15 en documento que NO es hijo = pago directo (dinero real sin deposito previo)
--   claves 05/08 sueltas = reversos y traspasos, ajustes negativos de pagos que si estan
-- Se EXCLUYEN las lineas de un DOCUMENTO HIJO: su clave 15 reaplica dinero ya contado en
-- la clave 11 y su clave 08 es el espejo. Sin ese filtro se cuenta el mismo deposito dos
-- veces (+$1,807,278 en julio, 123 lineas) - mismo bug que ya tuvo fact_pagos_compensados.
-- ========================================================================================
IF OBJECT_ID('gold.fact_pagos', 'U') IS NOT NULL
    DROP TABLE gold.fact_pagos;
GO

CREATE TABLE gold.fact_pagos (
    sociedad                VARCHAR(4)    NOT NULL,
    cliente_id              VARCHAR(10)   NOT NULL,
    ejercicio               INT           NOT NULL,
    documento_id            VARCHAR(10)   NOT NULL,
    posicion                INT           NOT NULL,

    documento_compensacion  VARCHAR(10),
    ejercicio_compensacion  INT,

    fecha_documento         DATE,   -- fecha real del deposito
    fecha_contabilizacion   DATE,   -- el campo que cuadra con el reporte mensual de SAP
    fecha_compensacion      DATE,   -- cuando SAP liquido la linea

    monto                   DECIMAL(15,2) NOT NULL,  -- YA FIRMADO: 'H' positivo, 'S' negativo
    texto                   VARCHAR(50),
    clave_contabilizacion   VARCHAR(2),

    cliente_comercial_sk    INT,    -- version SCD2 vigente el dia de fecha_contabilizacion
    cliente_credito_sk      INT,

    fecha_carga             DATETIME DEFAULT GETDATE(),
    CONSTRAINT PK_fact_pagos PRIMARY KEY CLUSTERED
        (sociedad, cliente_id, ejercicio, documento_id, posicion)
);
GO

-- El puente une por el grupo de compensacion.
CREATE INDEX IX_fact_pagos_grupo ON gold.fact_pagos (documento_compensacion, ejercicio_compensacion);
GO
-- Toda consulta de cobranza filtra por periodo.
CREATE INDEX IX_fact_pagos_periodo ON gold.fact_pagos (fecha_compensacion);
GO
PRINT 'Table gold.fact_pagos created successfully.';
GO


-- ========================================================================================
-- 2. gold.fact_facturas  -  lo que se DEBE. 1 fila = 1 linea de factura.
--
-- Dos poblaciones separadas por flag_compensada:
--   compensadas (bsad) -> historia completa desde 2022, tienen documento_compensacion
--   abiertas    (bsid) -> FOTO DEL PRESENTE, documento_compensacion NULL siempre
-- Las abiertas NO participan del puente (no tienen grupo). Estan para cartera y para la
-- regla REFERENCIA.
--
-- RESET DE COMPENSACION (FBRA): hay lineas que estan en bsad Y en bsid a la vez - se
-- compensaron y despues alguien deshizo la compensacion. GANA BSID, que es el estado de
-- hoy. Sin excluirlas del lado compensado la PK revienta, y peor: el modelo diria que
-- una factura esta pagada cuando sigue abierta.
--
-- Incluye D1 (deuda) ademas de F%. Las clases reales son F1-F5 y D1; F6 no existe.
-- ========================================================================================
IF OBJECT_ID('gold.fact_facturas', 'U') IS NOT NULL
    DROP TABLE gold.fact_facturas;
GO

CREATE TABLE gold.fact_facturas (
    sociedad                VARCHAR(4)    NOT NULL,
    cliente_id              VARCHAR(10)   NOT NULL,
    ejercicio               INT           NOT NULL,
    documento_id            VARCHAR(10)   NOT NULL,
    posicion                INT           NOT NULL,

    documento_compensacion  VARCHAR(10),   -- NULL en las abiertas, siempre
    ejercicio_compensacion  INT,
    clase_documento         VARCHAR(2)    NOT NULL,  -- distingue factura (F*) de deuda (D1)

    fecha_documento         DATE,
    fecha_vencimiento       DATE,
    fecha_contabilizacion   DATE,
    fecha_compensacion      DATE,

    monto                   DECIMAL(15,2) NOT NULL,
    clave_contabilizacion   VARCHAR(2),
    flag_compensada         BIT           NOT NULL,

    cliente_comercial_sk    INT,
    cliente_credito_sk      INT,

    fecha_carga             DATETIME DEFAULT GETDATE(),
    CONSTRAINT PK_fact_facturas PRIMARY KEY CLUSTERED
        (sociedad, cliente_id, ejercicio, documento_id, posicion)
);
GO

CREATE INDEX IX_fact_facturas_grupo ON gold.fact_facturas (documento_compensacion, ejercicio_compensacion);
GO
CREATE INDEX IX_fact_facturas_abiertas ON gold.fact_facturas (flag_compensada, fecha_vencimiento);
GO
PRINT 'Table gold.fact_facturas created successfully.';
GO


-- ========================================================================================
-- 3. gold.fact_aplicacion_pagos  -  EL PUENTE. 1 fila = 1 pago toco 1 factura.
--
-- SIN COLUMNA DE MONTO, a proposito (ver la cabecera del archivo).
--
-- PK = la PK del pago + la PK de la factura. Se ve pesada pero hace imposible el
-- duplicado por construccion. Con menos no alcanza: hay documentos de pago con dos
-- lineas apuntando al mismo grupo.
--
-- LAS TRES REGLAS (columna `regla`):
--   GRUPO          el grupo del pago YA contiene las facturas. Caso normal, 91% del dinero.
--   SEGUNDO_SALTO  el grupo del pago es un documento intermedio ("hijo") que reemite con
--                  lineas clave 15 hacia su propio grupo final, y ahi estan las facturas.
--   REFERENCIA     el hijo tiene una linea clave 15 ABIERTA con REBZG hacia una factura
--                  que TAMBIEN sigue abierta. Es el pago parcial.
-- Las tres usan llaves nativas de SAP. Cero reparto proporcional, cero heuristica.
--
-- QUE SIGNIFICA CADA FILA - leer antes de reportar:
--   GRUPO y SEGUNDO_SALTO dicen "este pago LIQUIDO esta factura".
--   REFERENCIA dice "este pago ABONO a esta factura, que sigue abierta".
-- GRUPO y SEGUNDO_SALTO son excluyentes entre si; REFERENCIA no lo es, a proposito: un
-- deposito puede liquidar tres facturas y abonar a una cuarta. Contar pagos por regla NO
-- suma al total, y es correcto que no sume.
-- ========================================================================================
IF OBJECT_ID('gold.fact_aplicacion_pagos', 'U') IS NOT NULL
    DROP TABLE gold.fact_aplicacion_pagos;
GO

CREATE TABLE gold.fact_aplicacion_pagos (
    sociedad                VARCHAR(4)  NOT NULL,
    cliente_id              VARCHAR(10) NOT NULL,

    ejercicio_pago          INT         NOT NULL,
    pago_id                 VARCHAR(10) NOT NULL,
    posicion_pago           INT         NOT NULL,

    ejercicio_factura       INT         NOT NULL,
    factura_id              VARCHAR(10) NOT NULL,
    posicion_factura        INT         NOT NULL,

    -- El grupo donde REALMENTE esta la factura. En SEGUNDO_SALTO es el grupo final, no
    -- el del pago: hace la cadena auditable hacia atras.
    documento_compensacion  VARCHAR(10) NOT NULL,
    fecha_compensacion      DATE,
    regla                   VARCHAR(20) NOT NULL,

    fecha_carga             DATETIME DEFAULT GETDATE(),
    CONSTRAINT PK_fact_aplicacion_pagos PRIMARY KEY CLUSTERED (
        sociedad, ejercicio_pago, pago_id, posicion_pago,
        ejercicio_factura, factura_id, posicion_factura
    )
);
GO

-- Para navegar en el otro sentido: que pagos liquidaron esta factura.
CREATE INDEX IX_fap_factura ON gold.fact_aplicacion_pagos
    (ejercicio_factura, factura_id, posicion_factura);
GO
CREATE INDEX IX_fap_periodo ON gold.fact_aplicacion_pagos (fecha_compensacion, regla);
GO
PRINT 'Table gold.fact_aplicacion_pagos created successfully.';
GO


-- ========================================================================================
-- 4. gold.fact_pagos_sin_aplicacion  -  por que este dinero no liquido ninguna factura.
--
-- ESTO ES COBRANZA, NO UN HUECO. El dinero SI entro (confirmado con el usuario
-- 2026-09-07): simplemente liquido documentos que no son factura de cliente - SA
-- (ajustes y comisiones) y AB (documentos de compensacion), mayormente de pasarela de
-- pago. Caso verificable en SAP: el pago 1402614549 de KUSHKY ($354,431.39) reparte en
-- tres grupos finales y en los tres el mayor debito es clase SA.
--
-- Por eso la etiqueta dice LIQUIDA_NO_FACTURA y NO "NO_IDENTIFICADO": la segunda
-- sugeriria que fallamos en encontrar algo, y no habia factura que encontrar.
--
-- MOTIVOS:
--   LIQUIDA_NO_FACTURA  el salto llega a un grupo cuyos debitos no son facturas
--   SIN_APLICACION      el grupo del pago no reenvia a ningun lado
--   CADENA_AMBIGUA      el intermedio recibio dinero de VARIOS pagos y se mezclo ahi
--                       dentro: no se puede decir cual financio que linea, y la guarda
--                       del puente los excluye a proposito. Agregada 2026-09-07 tras el
--                       backfill de 5 anios: 62 pagos / $3,077,868.56 caian en REVISAR
--                       solo por no tener etiqueta. NO son un caso desconocido - sabemos
--                       exactamente que son y decidimos no atribuirlos. En julio y agosto
--                       eran CERO; aparecen al mirar la historia completa.
--   LINEA_TECNICA       lineas cuya clave no es 11 ni 15 (debitos espejo 08, reversos 05)
--   REVISAR             caso desconocido. Debe dar 0 - si aparece, hay algo nuevo.
--
-- VA APARTE Y NO COMO FILAS DEL PUENTE: una fila del puente afirma "este pago toco ESTA
-- factura", y estos no tocaron ninguna. Meterlos obligaria a inventar un factura_id
-- centinela y a aflojar la PK.
-- Tampoco como columna de fact_pagos: el motivo se DERIVA de la logica de aplicacion, y
-- fact_pagos debe poder cargarse sola desde silver.
--
-- INVARIANTE DEL MODELO: todo pago esta en el puente O aqui, nunca en los dos ni en
-- ninguno, y los montos de ambos suman exactamente el total de fact_pagos.
-- ========================================================================================
IF OBJECT_ID('gold.fact_pagos_sin_aplicacion', 'U') IS NOT NULL
    DROP TABLE gold.fact_pagos_sin_aplicacion;
GO

CREATE TABLE gold.fact_pagos_sin_aplicacion (
    sociedad                VARCHAR(4)  NOT NULL,
    cliente_id              VARCHAR(10) NOT NULL,
    ejercicio               INT         NOT NULL,
    documento_id            VARCHAR(10) NOT NULL,
    posicion                INT         NOT NULL,

    documento_compensacion  VARCHAR(10),   -- para trazar que SI liquido
    fecha_compensacion      DATE,
    motivo                  VARCHAR(24) NOT NULL,

    fecha_carga             DATETIME DEFAULT GETDATE(),
    CONSTRAINT PK_fact_pagos_sin_aplicacion PRIMARY KEY CLUSTERED
        (sociedad, cliente_id, ejercicio, documento_id, posicion)
);
GO

CREATE INDEX IX_fpsa_periodo ON gold.fact_pagos_sin_aplicacion (fecha_compensacion, motivo);
GO
PRINT 'Table gold.fact_pagos_sin_aplicacion created successfully.';
GO
