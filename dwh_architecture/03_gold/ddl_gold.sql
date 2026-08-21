USE ANALISIS_DATOS;
GO

/*
===============================================================================
PROJECT: Enterprise Data Warehouse (dwh-ciosa)
LAYER: Gold (Presentation / Star Schema)
===============================================================================
*/

-- ==========================================================
-- 1. DIMENSION: gold.dim_fecha (Calendario)
-- SIN SCD. Rango CRECIENTE (no estatico): limite inferior fijo en
-- 2022-01-01 (arranque real de bronze.sap_bsad) y limite superior = hoy +
-- 1 año, extendido automaticamente por gold.load_dim_fecha en cada corrida
-- de gold.load_gold (ver sp_load_gold.sql) - el colchon de 1 año adelante
-- cubre fechas de vencimiento futuras (plazos de pago tipo NET-90) sin
-- necesidad de un rango fijo hasta 2035. REDISEÑADO 2026-08-20: antes era
-- estatico 2020-01-01/2035-12-31, poblado una sola vez via
-- populate_dim_fecha.sql (retirado, su logica de bootstrap ahora vive
-- dentro de gold.load_dim_fecha) - el usuario prefirio que el calendario
-- reflejara el periodo real de datos en vez de mostrar años sin ninguna
-- transaccion real (esto se notaba, por ejemplo, en el filtro de Año del
-- reporte de Power BI, que ofrecia 2020-2035 completos sin importar que
-- solo hubiera datos reales desde 2022).
-- ==========================================================
IF OBJECT_ID('gold.dim_fecha', 'U') IS NOT NULL
    DROP TABLE gold.dim_fecha;
GO

CREATE TABLE gold.dim_fecha (
    fecha                DATE NOT NULL,
    anio                 INT NOT NULL,
    mes                  INT NOT NULL,
    nombre_mes           VARCHAR(15) NOT NULL,
    trimestre            INT NOT NULL,
    dia                  INT NOT NULL,
    dia_semana           INT NOT NULL,          -- 1=domingo ... 7=sabado (fijado explicitamente via SET DATEFIRST 7 al poblar)
    nombre_dia_semana    VARCHAR(15) NOT NULL,
    es_fin_de_semana     BIT NOT NULL,
    semana_anio          INT NOT NULL,           -- semana ISO del anio

    -- Agregadas 2026-08-20 para el eje "mes calendario real" del reporte de
    -- Power BI (Tendencia de monto total recibido) - sin esto, agrupar por
    -- nombre_mes junta Agosto-2025 con Agosto-2026 en una sola barra.
    -- Columnas CALCULADAS (AS ... PERSISTED): se autopueblan a partir de
    -- anio/mes/nombre_mes, no requieren logica extra en gold.load_dim_fecha.
    anio_mes_num  AS (anio * 100 + mes) PERSISTED NOT NULL,               -- ej. 202608, para ordenar cronologicamente
    anio_mes_texto AS (LEFT(nombre_mes, 3) + ' ' + CAST(anio AS VARCHAR(4))) PERSISTED NOT NULL, -- ej. 'Ago 2026'

    CONSTRAINT PK_dim_fecha PRIMARY KEY CLUSTERED (fecha)
);
GO

PRINT 'Table gold.dim_fecha created successfully.';
GO

-- ==========================================================
-- 2. DIMENSION: gold.dim_cliente (SCD Tipo 1 - Identidad del Cliente)
-- Fuente: silver.sap_kna1 LEFT JOIN silver.sap_knkk (por cliente_id; knkk ya
-- viene filtrada a KKBER='2000' en silver, asi que el join es 1:1 o 1:0, sin
-- necesidad de repetir el filtro aqui).
-- SCD1: se sobrescribe completo en cada carga (TRUNCATE+INSERT), SIN
-- historial de versiones - a diferencia de dim_cliente_credito/comercial
-- (SCD2, pendientes), estos atributos casi no cambian.
-- Llave: cliente_id directo (sin llave subrogada - no hace falta para SCD1,
-- y mantiene consistencia con el resto del proyecto que usa llaves de
-- negocio). mandante NO se incluye (siempre '400', cero variacion).
-- tipo_cliente = PADRE / FILIAL / DIRECCION_ALTERNA / GENERICO, logica
-- completa en gold.load_dim_cliente (sp_load_gold.sql).
-- ==========================================================
IF OBJECT_ID('gold.dim_cliente', 'U') IS NOT NULL
    DROP TABLE gold.dim_cliente;
GO

CREATE TABLE gold.dim_cliente (
    cliente_id              VARCHAR(10) NOT NULL,
    rfc                     VARCHAR(16),
    tipo_cliente            VARCHAR(20) NOT NULL,
    nombre                  VARCHAR(35),
    nombre2                 VARCHAR(35),
    pais                    VARCHAR(3),
    estado                  VARCHAR(3),
    poblacion               VARCHAR(35),
    codigo_postal           VARCHAR(10),
    calle                   VARCHAR(35),
    bloqueo_pedido          VARCHAR(2),
    regimen_fiscal          VARCHAR(10),
    telefono                VARCHAR(16),
    telefono_extra          VARCHAR(16),
    whatsapp                VARCHAR(31),
    fecha_creacion          DATE,
    grupo_cuentas           VARCHAR(4),
    proveedor_vinculado     VARCHAR(10),
    flag_bloqueado          BIT,
    flag_cliente_ocasional  BIT,
    flag_persona_fisica     BIT,
    flag_sujeto_iva         BIT,
    tipo_servicio_paq1      VARCHAR(2),
    tipo_servicio_paq2      VARCHAR(2),
    tipo_servicio_paq3      VARCHAR(2),
    tiempo_entrega_paq1     VARCHAR(3),
    tiempo_entrega_paq2     VARCHAR(3),
    tiempo_entrega_paq3     VARCHAR(3),
    fecha_actualizacion     DATETIME DEFAULT GETDATE(),
    CONSTRAINT PK_dim_cliente PRIMARY KEY CLUSTERED (cliente_id)
);
GO

PRINT 'Table gold.dim_cliente created successfully.';
GO

-- ==========================================================
-- 3. VIEW: gold.vw_cliente_canal_estatus
-- Clasificacion ACTIVO/LEGAL/INACTIVO/REVISAR/FUERA_DE_ALCANCE por cada fila
-- cliente+canal de silver.sap_knvv (grano completo, NO reducido a 1 fila por
-- cliente todavia - eso lo hace gold.load_dim_cliente_comercial encima de
-- esta vista). Logica portada de ciosa.py (ver dwh-ciosa-project-status.md
-- en memoria para el detalle de cada regla), confirmada contra datos reales:
--   - "Bloqueo pedido" = knvv.bloqueo_pedido (nivel canal, NO kna1 - 1,429
--     clientes tienen bloqueo distinto entre canales, confirma que es el
--     campo correcto).
--   - "Zona de ventas" = knvv.region (BZIRK) - confirmado, 327 filas con
--     'MXZLEG' en datos reales.
--   - vendedor/ejecutivo_credito/gerente: de silver.sap_knvp (roles VE/E1/GR),
--     tomando el 'contador' (PARZA) mas bajo si hay mas de una asignacion
--     del mismo rol en el mismo canal (convencion SAP: numero mas bajo =
--     asignacion principal).
--   - Prefijo de cliente 5/6/7: se aplica sobre cliente_id YA sin ceros a la
--     izquierda (silver ya lo hace asi desde 2026-08-07) - coincide con como
--     ciosa.py leia el campo en Python (numerico, sin padding).
-- ==========================================================
IF OBJECT_ID('gold.vw_cliente_canal_estatus', 'V') IS NOT NULL
    DROP VIEW gold.vw_cliente_canal_estatus;
GO

CREATE VIEW gold.vw_cliente_canal_estatus
AS
WITH vendedor AS (
    SELECT
        p.cliente_id, p.organizacion_ventas, p.canal_distribucion, p.sector,
        p.id_interlocutor AS vendedor_id, p.nombre_interlocutor AS vendedor_nombre,
        ROW_NUMBER() OVER (
            PARTITION BY p.cliente_id, p.organizacion_ventas, p.canal_distribucion, p.sector
            ORDER BY p.contador
        ) AS rn
    FROM silver.sap_knvp p
    WHERE p.funcion_interlocutor = 'VE'
),
ejecutivo AS (
    SELECT
        p.cliente_id, p.organizacion_ventas, p.canal_distribucion, p.sector,
        p.id_interlocutor AS ejecutivo_id, p.nombre_interlocutor AS ejecutivo_nombre,
        ROW_NUMBER() OVER (
            PARTITION BY p.cliente_id, p.organizacion_ventas, p.canal_distribucion, p.sector
            ORDER BY p.contador
        ) AS rn
    FROM silver.sap_knvp p
    WHERE p.funcion_interlocutor = 'E1'
),
gerente AS (
    SELECT
        p.cliente_id, p.organizacion_ventas, p.canal_distribucion, p.sector,
        p.id_interlocutor AS gerente_id, p.nombre_interlocutor AS gerente_nombre,
        ROW_NUMBER() OVER (
            PARTITION BY p.cliente_id, p.organizacion_ventas, p.canal_distribucion, p.sector
            ORDER BY p.contador
        ) AS rn
    FROM silver.sap_knvp p
    WHERE p.funcion_interlocutor = 'GR'
)
SELECT
    v.cliente_id,
    v.organizacion_ventas,
    v.canal_distribucion,
    v.sector,
    v.region,
    v.ruta,
    v.ruta_nombre,
    v.condicion_pago,
    v.bloqueo_pedido,
    ve.vendedor_id,
    ve.vendedor_nombre,
    ej.ejecutivo_id,
    ej.ejecutivo_nombre,
    ge.gerente_id,
    ge.gerente_nombre,
    k.rfc,
    CASE
        -- 2026-08-14: se probo reducir el alcance de canal a 10/40/60 (excluir
        -- el 20/menudeo) a nivel de TODO el proyecto - REVERTIDO 2026-08-17.
        -- La regla de negocio original (confirmada por el usuario) es que
        -- clientes REALES viven en canal 10 (mayoreo) / 20 (menudeo) / 40
        -- (directos) / 60 (mayoreo via ATM, tambien cuenta) - los 4 son
        -- clientes reales, "10/40/60 = solo mayoreo" es una decision de
        -- ALCANCE DE REPORTE (que canales entran al analisis de comportamiento
        -- de pago mayoreo), no una decision de "es esto un cliente real". Se
        -- confundieron ambas preguntas al hacer el cambio original - un
        -- cliente de menudeo (canal 20) SI es un cliente real, solo que no
        -- aplica para ese reporte en particular. El filtro "solo mayoreo" vive
        -- exclusivamente en el reporte, nunca aqui.
        -- Canal '50' investigado 2026-08-17: confirmado que NO es canal de
        -- cliente real - la cuenta mas grande ahi (90000002, $171.5M) es del
        -- DUEÑO de la empresa (Jorge Armando Huguenin Bolaños). Ninguna cuenta
        -- de canal 50 tiene ruta_nombre. Probable cuenta relacionada/accionista,
        -- correctamente cae en FUERA_DE_ALCANCE con la regla de abajo (no esta
        -- en 10/20/40/60).
        WHEN v.canal_distribucion NOT IN ('10', '20', '40', '60')
             OR v.cliente_id LIKE '5%' OR v.cliente_id LIKE '6%' OR v.cliente_id LIKE '7%'
            THEN 'FUERA_DE_ALCANCE'
        WHEN v.ruta_nombre IN ('CC131-E04', 'CC131-G01', 'C131-E200', 'C131-R014')
             OR ve.vendedor_nombre IN ('COBRADOR EXTRAJUDICIAL INTERNO', 'CLIENTES JURIDICO', 'CUENTAS CRITICAS JURIDICO', 'COBRADOR EXTRAJUDICIAL ABOGADO', 'COBRADOR RUTA DOS CIENTOS')
             OR v.region = 'MXZLEG'
             OR ej.ejecutivo_nombre IN ('COBRADOR EXTRAJUDICIAL INTERNO', 'CLIENTES JURIDICO', 'CUENTAS CRITICAS JURIDICO', 'COBRADOR EXTRAJUDICIAL ABOGADO', 'COBRADOR RUTA DOS CIENTOS')
            THEN 'LEGAL'
        WHEN v.ruta_nombre LIKE '6%' OR ve.vendedor_nombre LIKE '%INACTIVOS%'
            THEN 'INACTIVO'
        WHEN k.rfc IS NOT NULL
             AND k.rfc NOT IN ('XAXX010101000', 'XEXX010101000')
             AND v.bloqueo_pedido IS NULL
             AND ve.vendedor_id IS NOT NULL
            THEN 'ACTIVO'
        ELSE 'REVISAR'
    END AS estatus_comercial
FROM silver.sap_knvv v
LEFT JOIN silver.sap_kna1 k ON k.cliente_id = v.cliente_id
LEFT JOIN vendedor ve ON ve.cliente_id = v.cliente_id AND ve.organizacion_ventas = v.organizacion_ventas
    AND ve.canal_distribucion = v.canal_distribucion AND ve.sector = v.sector AND ve.rn = 1
LEFT JOIN ejecutivo ej ON ej.cliente_id = v.cliente_id AND ej.organizacion_ventas = v.organizacion_ventas
    AND ej.canal_distribucion = v.canal_distribucion AND ej.sector = v.sector AND ej.rn = 1
LEFT JOIN gerente ge ON ge.cliente_id = v.cliente_id AND ge.organizacion_ventas = v.organizacion_ventas
    AND ge.canal_distribucion = v.canal_distribucion AND ge.sector = v.sector AND ge.rn = 1;
GO

PRINT 'View gold.vw_cliente_canal_estatus created successfully.';
GO

-- ==========================================================
-- 4. DIMENSION: gold.dim_cliente_comercial (SCD Tipo 2)
-- Grano: cliente_id (un representante por cliente, elegido entre sus canales
-- via gold.vw_cliente_canal_estatus con prioridad ACTIVO > LEGAL > REVISAR >
-- INACTIVO > FUERA_DE_ALCANCE, desempate final por canal_distribucion mas
-- bajo - ver gold.load_dim_cliente_comercial en sp_load_gold.sql).
-- organizacion_ventas/canal_distribucion/sector se conservan como columnas
-- (aunque la PK es solo cliente_id) para que gold.dim_cliente_credito pueda
-- reusar "cual canal se eligio" al buscar analista_credito/cobrador.
-- SCD2: id_surrogate es la llave tecnica que usan los hechos. Un indice unico
-- filtrado garantiza una sola version vigente (es_vigente=1) por cliente.
-- ==========================================================
IF OBJECT_ID('gold.dim_cliente_comercial', 'U') IS NOT NULL
    DROP TABLE gold.dim_cliente_comercial;
GO

CREATE TABLE gold.dim_cliente_comercial (
    id_surrogate            INT IDENTITY(1,1) NOT NULL,
    cliente_id              VARCHAR(10) NOT NULL,
    organizacion_ventas     VARCHAR(4),
    canal_distribucion      VARCHAR(2),
    sector                  VARCHAR(2),
    region                  VARCHAR(6),
    ruta                    VARCHAR(3),
    ruta_nombre             VARCHAR(20),
    condicion_pago          VARCHAR(4),
    vendedor_id             VARCHAR(8),
    vendedor_nombre         VARCHAR(40),
    gerente_id              VARCHAR(8),
    gerente_nombre          VARCHAR(40),
    estatus_comercial       VARCHAR(20) NOT NULL,
    hash_atributos          VARBINARY(32) NOT NULL,
    fecha_inicio_vigencia   DATE NOT NULL,
    fecha_fin_vigencia      DATE NULL,
    es_vigente              BIT NOT NULL,
    fecha_carga             DATETIME DEFAULT GETDATE(),
    CONSTRAINT PK_dim_cliente_comercial PRIMARY KEY CLUSTERED (id_surrogate)
);
GO

CREATE UNIQUE INDEX UX_dim_cliente_comercial_vigente
    ON gold.dim_cliente_comercial (cliente_id)
    WHERE es_vigente = 1;
GO

PRINT 'Table gold.dim_cliente_comercial created successfully.';
GO

-- ==========================================================
-- 5. DIMENSION: gold.dim_cliente_credito (SCD Tipo 2)
-- Grano: cliente_id. Atributos de silver.sap_knkk (ya ~1:1 por cliente
-- gracias al filtro KKBER='2000' en silver) + analista_credito (rol E1) y
-- cobrador (rol CC) de silver.sap_knvp, resueltos en el canal que
-- gold.dim_cliente_comercial YA eligio como representante del cliente (no
-- se vuelve a decidir "cual canal" aqui - se reutiliza esa decision via
-- join a dim_cliente_comercial, una sola fuente de verdad).
-- SCD2: misma mecanica que dim_cliente_comercial (id_surrogate, hash-diff,
-- vigencia), ya validada en produccion.
-- ==========================================================
IF OBJECT_ID('gold.dim_cliente_credito', 'U') IS NOT NULL
    DROP TABLE gold.dim_cliente_credito;
GO

CREATE TABLE gold.dim_cliente_credito (
    id_surrogate             INT IDENTITY(1,1) NOT NULL,
    cliente_id               VARCHAR(10) NOT NULL,
    limite_credito           DECIMAL(15,2),
    bloqueo_credito          CHAR(1),
    clasificacion_riesgo     VARCHAR(5),
    etiqueta_credito         VARCHAR(11),   -- KRAUS crudo (incluye FILIAL/LEGAL/BAJA*/CREDITOC/etc.)
    grupo_credito            VARCHAR(4),
    analista_credito_id      VARCHAR(8),
    analista_credito_nombre  VARCHAR(40),
    cobrador_id              VARCHAR(8),
    cobrador_nombre          VARCHAR(40),
    hash_atributos           VARBINARY(32) NOT NULL,
    fecha_inicio_vigencia    DATE NOT NULL,
    fecha_fin_vigencia       DATE NULL,
    es_vigente               BIT NOT NULL,
    fecha_carga              DATETIME DEFAULT GETDATE(),
    CONSTRAINT PK_dim_cliente_credito PRIMARY KEY CLUSTERED (id_surrogate)
);
GO

CREATE UNIQUE INDEX UX_dim_cliente_credito_vigente
    ON gold.dim_cliente_credito (cliente_id)
    WHERE es_vigente = 1;
GO

PRINT 'Table gold.dim_cliente_credito created successfully.';
GO

-- ==========================================================
-- 6. FACT: gold.fact_saldo_cartera
-- "Periodic snapshot fact": cada corrida de gold.load_fact_saldo_cartera
-- agrega una foto nueva (fecha_snapshot = hoy) del saldo abierto de cada
-- cliente, SIN borrar fotos anteriores - asi se acumula el historial que
-- silver.sap_bsid no puede dar (bronze/silver.sap_bsid se recargan completos
-- todos los dias, sin MERGE ni backfill, a diferencia de bsad - jamas hubo
-- forma de reconstruir el saldo de una fecha pasada). CONSECUENCIA IMPORTANTE:
-- este fact NO se puede backfillear historicamente - solo empieza a acumular
-- desde el primer dia real en que se corra su carga.
--
-- GRANO: cliente_id + fecha_snapshot (decidido 2026-08-11 sobre grano linea -
-- ver dwh-ciosa-project-status.md en memoria para la comparacion completa).
-- Colapsa 'sociedad' igual que dim_cliente_comercial/dim_cliente_credito (no
-- hay dim_sociedad en este modelo). Con ~91,593 partidas / ~4,568 clientes
-- con saldo hoy, el grano linea hubiera crecido ~33M filas/anio indefinidamente
-- en un servidor con el limite de log de 2GB ya conocido; el grano cliente
-- crece ~1.67M filas/anio, manejable.
--
-- MEDIDAS AGREGADAS (desde silver.sap_bsid, por cliente, a la fecha del snapshot,
-- monto firmado por debe_haber y excluyendo clase_documento='SA' - ver nota
-- completa en el CREATE TABLE mas abajo):
--   saldo_total/saldo_no_vencido/saldo_1_16 (periodo de gracia)/saldo_vencido
--   (REAL, 17+ dias), num_documentos_abiertos, dias_vencido_max, buckets de
--   antiguedad (17-31/32-180/181+, solo sobre saldo_vencido real),
--   documentos_con_reclamacion/nivel_reclamacion_max (MANST, peor nivel entre
--   sus documentos abiertos).
--
-- DPP (dias promedio de pago) y DPP ponderado: NO se calculan de bsid (partidas
-- abiertas - no sabemos cuanto van a tardar en pagarse) sino de documentos YA
-- liquidados, como contexto de comportamiento historico de pago superpuesto a
-- la foto de saldo actual. Dos ventanas moviles (3 y 12 meses hacia atras
-- desde fecha_snapshot), cada una simple y ponderada por monto (las facturas
-- de mayor importe pesan mas en el promedio).
-- 2026-08-19: DPP y % a tiempo/tarde se calculan desde gold.fact_pagos/
-- gold.fact_facturas (ver gold.load_fact_saldo_cartera Paso 2) - migrado de
-- gold.fact_aplicacion_pagos, cuya logica de matching de 3 niveles (REBZG/
-- GRUPO_INAMBIGUO/sin match) resulto tener bugs reales de sobre-atribucion
-- (un candidato de match podia "explicar" facturas por mucho mas de lo que
-- realmente vale - confirmado con casos reales, ej. un documento de $137
-- atribuido a $2.5M en facturas dentro de un grupo de compensacion masivo).
-- fact_pagos/fact_facturas usan un diseño deliberadamente mas simple: solo
-- relacionan grupos de compensacion con EXACTAMENTE 1 pago virgen candidato,
-- sin niveles de match ni particion de aplicaciones parciales. Solo cubre
-- pagos reales (no NC/devolucion/ajuste/anulacion, fuera del alcance de este
-- diseño) - por eso estos porcentajes deliberadamente NO sumaran 100% del
-- saldo total del cliente, son especificamente sobre la porcion con pago
-- identificado de forma inambigua.
-- ==========================================================
IF OBJECT_ID('gold.fact_saldo_cartera', 'U') IS NOT NULL
    DROP TABLE gold.fact_saldo_cartera;
GO

CREATE TABLE gold.fact_saldo_cartera (
    cliente_id                  VARCHAR(10) NOT NULL,
    fecha_snapshot               DATE        NOT NULL,

    -- saldo y antiguedad - REDISEÑADO 2026-08-18 tras reconciliar contra un
    -- reporte externo de cartera y encontrar 3 diferencias reales:
    --   1. monto_moneda_local de silver.sap_bsid NUNCA trae signo (igual que
    --      bsad) - debe_haber='H' (pagos/notas de credito/devoluciones/
    --      ajustes sentados como partida abierta sin aplicar) se sumaba como
    --      deuda en vez de restar. Ahora se firma antes de agregar (ver
    --      gold.load_fact_saldo_cartera Paso 1).
    --   2. clase_documento='SA' (asientos de mayor/GL) se excluye por
    --      completo - no son documentos de cliente reales.
    --   3. Regla de negocio real: facturas vencidas por 1-16 dias se tratan
    --      como "saldo sano" (periodo de gracia), NO como vencido real -
    --      confirmado por el usuario y validado con datos (el vencido real
    --      solo con este ajuste quedo en $15.79M contra los $15.38M del
    --      reporte externo, ~2.6% de diferencia, dentro de lo esperable por
    --      timing entre snapshots).
    -- Buckets de antiguedad tambien rediseñados con los mismos cortes que el
    -- reporte externo (17-31/32-180/181+) para ser directamente comparables.
    saldo_total                  DECIMAL(18,2) NOT NULL,
    saldo_no_vencido              DECIMAL(18,2) NOT NULL,  -- fecha_vencimiento NULL o >= hoy (dentro de plazo)
    saldo_1_16                   DECIMAL(18,2) NOT NULL,  -- periodo de gracia: 1-16 dias vencido, negocio lo trata como sano
    saldo_vencido                DECIMAL(18,2) NOT NULL,  -- VENCIDO REAL: 17+ dias (saldo_17_31+saldo_32_180+saldo_181_mas)
    num_documentos_abiertos      INT NOT NULL,
    dias_vencido_max             INT NULL,  -- maximo dias vencido entre TODOS los documentos vencidos (incluye periodo de gracia, es el peor caso sin importar el corte de "vencido real")

    -- buckets de antiguedad (solo sobre saldo_vencido REAL, 17+ dias)
    saldo_17_31                  DECIMAL(18,2) NOT NULL,
    saldo_32_180                 DECIMAL(18,2) NOT NULL,
    saldo_181_mas                DECIMAL(18,2) NOT NULL,

    -- reclamacion / cobranza (agregado desde nivel linea)
    documentos_con_reclamacion   INT NOT NULL,
    nivel_reclamacion_max        CHAR(1) NULL,

    -- comportamiento historico de pago (desde gold.fact_pagos/
    -- gold.fact_facturas via gold.load_fact_saldo_cartera Paso 2 - ver nota
    -- arriba del CREATE TABLE. Historial: esta migro 2026-08-19 desde
    -- gold.fact_aplicacion_pagos por los bugs de sobre-atribucion ya
    -- documentados arriba).
    dpp_3m                       DECIMAL(9,2) NULL,
    dpp_ponderado_3m             DECIMAL(9,2) NULL,
    dpp_12m                      DECIMAL(9,2) NULL,
    dpp_ponderado_12m            DECIMAL(9,2) NULL,
    pct_pagos_a_tiempo_3m        DECIMAL(5,2) NULL,  -- % del monto pagado (PAGO) en los ultimos 3m con dias_anticipacion_vencimiento <= 0
    pct_pagos_tarde_3m           DECIMAL(5,2) NULL,
    pct_pagos_a_tiempo_12m       DECIMAL(5,2) NULL,
    pct_pagos_tarde_12m          DECIMAL(5,2) NULL,

    -- llaves subrogadas SCD2, resueltas por join temporal a fecha_snapshot
    id_cliente_comercial         INT NULL,
    id_cliente_credito           INT NULL,

    fecha_carga                  DATETIME DEFAULT GETDATE(),

    CONSTRAINT PK_fact_saldo_cartera PRIMARY KEY CLUSTERED (fecha_snapshot, cliente_id),
    CONSTRAINT FK_fsc_cliente FOREIGN KEY (cliente_id) REFERENCES gold.dim_cliente (cliente_id),
    CONSTRAINT FK_fsc_fecha_snapshot FOREIGN KEY (fecha_snapshot) REFERENCES gold.dim_fecha (fecha),
    CONSTRAINT FK_fsc_cliente_comercial FOREIGN KEY (id_cliente_comercial) REFERENCES gold.dim_cliente_comercial (id_surrogate),
    CONSTRAINT FK_fsc_cliente_credito FOREIGN KEY (id_cliente_credito) REFERENCES gold.dim_cliente_credito (id_surrogate)
);
GO

PRINT 'Table gold.fact_saldo_cartera created successfully.';
GO

-- ==========================================================
-- gold.fact_aplicacion_pagos (tabla puente factura<->documento aplicado, con
-- matching de 3 niveles REBZG/GRUPO_INAMBIGUO/sin-match) fue ELIMINADA
-- 2026-08-19: la logica de matching resulto tener bugs reales de
-- sobre-atribucion (un candidato "inambiguo" podia explicar facturas por
-- mucho mas de lo que realmente vale - ej. un documento Z1 de $137
-- atribuido a $2.5M en 4,724 facturas dentro de un grupo de compensacion
-- masivo; confirmado en varios casos reales antes de decidir el retiro).
-- Reemplazada por el diseño simple gold.fact_pagos/gold.fact_facturas +
-- gold.vw_pago_factura_simple (solo relaciona grupos con EXACTAMENTE 1 pago
-- candidato, sin niveles de match ni aplicacion parcial). El bloque de DPP
-- de gold.fact_saldo_cartera que dependia de esta tabla ya fue migrado antes
-- del retiro (ver gold.load_fact_saldo_cartera Paso 2).
-- ==========================================================
-- 6. FACT: gold.fact_pagos
-- Grano: 1 fila = 1 deposito "virgen" (silver.sap_bsad, clase_documento='DZ'
-- AND sgtxt='Asignación Aut. Deposito' AND debe_haber<>'S' AND
-- monto_moneda_local>0) - un pago del cliente aun sin repartir entre
-- facturas. Espejo filtrado, sin logica de matching (a diferencia de
-- fact_aplicacion_pagos) - la relacion pago<->factura vive en
-- gold.vw_pago_factura_simple (consulta, no tabla), que solo relaciona
-- grupos de compensacion con EXACTAMENTE 1 pago candidato.
-- FILTRO debe_haber<>'S' agregado 2026-08-19 tras analizar los casos
-- GRUPO_AMBIGUO_2+PAGOS de julio: 4 de 5 grupos de muestra resultaron ser
-- un solo pago real duplicado, no ambiguedad genuina - el documento "hijo"
-- de una compensacion siempre trae su propia linea espejo/contrapartida
-- (mismo documento_id=documento_compensacion, debe_haber='S', mismo monto y
-- mismo sgtxt='Asignación Aut. Deposito' que el deposito real), que sin
-- este filtro se contaba como un segundo pago virgen candidato. Medido:
-- aplicar este filtro redujo GRUPO_AMBIGUO_2+PAGOS de julio de 92 pagos/
-- $1.52M a 29 pagos/$249K (-84% en monto), con impacto casi nulo en
-- MATCHEADO_OK (la mayoria de los pagos "desambiguados" no tenian factura
-- de cualquier forma, cayeron en SIN_FACTURA_EN_GRUPO). Mismo filtro que ya
-- se habia validado antes en el diseño de gold.fact_aplicacion_pagos (ahora
-- retirado) para el mismo proposito.
-- FILTRO monto_moneda_local>0 agregado 2026-08-19 (misma sesion), tras
-- analizar los 29 pagos que seguian ambiguos: 6 de 14 grupos de muestra
-- resultaron ser la linea "H" propia del hijo pero con monto $0.00 (residuo
-- tecnico, no dinero real) inflando el conteo de candidatos junto al
-- deposito real. Los otros 8 grupos de esa muestra (linea "H" propia del
-- hijo CON monto real compitiendo con un virgen externo por la misma plata,
-- o lotes de depuracion con multiples depositos/facturas reales de varios
-- meses) se dejan como residuo aceptado a proposito - resolverlos
-- requeriria la logica "propia vs externa" que ya causo varias rondas de
-- bugs en el diseño de fact_aplicacion_pagos, no vale la pena para un
-- residuo de ~0.17% del universo.
-- Carga: gold.load_fact_pagos (sp_load_gold.sql) - incremental, mes actual +
-- mes anterior por fecha_compensacion, mismo patron que silver.load_silver
-- usa para bsad. Backfill historico: 03_gold/backfill_fact_pagos_facturas.sql.
-- ==========================================================
IF OBJECT_ID('gold.fact_pagos', 'U') IS NOT NULL
    DROP TABLE gold.fact_pagos;
GO

CREATE TABLE gold.fact_pagos (
    sociedad                VARCHAR(4)    NOT NULL,
    cliente_id               VARCHAR(10)   NOT NULL,
    ejercicio                 INT           NOT NULL,
    documento_id               VARCHAR(10)   NOT NULL,
    posicion                   INT           NOT NULL,
    fecha_documento             DATE, -- fecha real del deposito ("fecha_pago")
    fecha_compensacion          DATE,
    monto_moneda_local          DECIMAL(15,2),
    documento_compensacion      VARCHAR(10), -- grupo de compensacion compartido con las facturas que cubre
    ejercicio_compensacion      INT,
    fecha_carga                 DATETIME DEFAULT GETDATE(),
    CONSTRAINT PK_fact_pagos PRIMARY KEY CLUSTERED (sociedad, cliente_id, ejercicio, documento_id, posicion)
);
GO

-- Indice sobre el grupo de compensacion: gold.vw_pago_factura_simple (y
-- cualquier analisis ad-hoc) agrupa/junta por esta pareja de columnas todo
-- el tiempo - sin este indice es un escaneo completo de la tabla cada vez
-- (confirmado 2026-08-19, consulta de reconciliacion se tardaba mucho).
CREATE INDEX IX_fact_pagos_grupo ON gold.fact_pagos (documento_compensacion, ejercicio_compensacion);
GO

PRINT 'Table gold.fact_pagos created successfully.';
GO

-- ==========================================================
-- 7. FACT: gold.fact_facturas
-- Grano: 1 fila = 1 factura ya compensada (silver.sap_bsad,
-- clase_documento IN F1-F6). Mismo espejo filtrado que fact_pagos, sin
-- logica de matching.
-- Carga: gold.load_fact_facturas (sp_load_gold.sql) - incremental, mismo
-- patron. Backfill historico: 03_gold/backfill_fact_pagos_facturas.sql
-- (corrido 2026-08-19, historico completo desde 2022-01-01).
-- ==========================================================
IF OBJECT_ID('gold.fact_facturas', 'U') IS NOT NULL
    DROP TABLE gold.fact_facturas;
GO

CREATE TABLE gold.fact_facturas (
    sociedad                VARCHAR(4)    NOT NULL,
    cliente_id               VARCHAR(10)   NOT NULL,
    ejercicio                 INT           NOT NULL,
    documento_id               VARCHAR(10)   NOT NULL,
    posicion                   INT           NOT NULL,
    fecha_documento             DATE,
    fecha_vencimiento           DATE,
    fecha_compensacion          DATE,
    monto_moneda_local          DECIMAL(15,2),
    documento_compensacion      VARCHAR(10),
    ejercicio_compensacion      INT,
    fecha_carga                 DATETIME DEFAULT GETDATE(),
    CONSTRAINT PK_fact_facturas PRIMARY KEY CLUSTERED (sociedad, cliente_id, ejercicio, documento_id, posicion)
);
GO

-- Mismo motivo que gold.fact_pagos: gold.vw_pago_factura_simple junta por
-- esta pareja de columnas constantemente.
CREATE INDEX IX_fact_facturas_grupo ON gold.fact_facturas (documento_compensacion, ejercicio_compensacion);
GO

PRINT 'Table gold.fact_facturas created successfully.';
GO
