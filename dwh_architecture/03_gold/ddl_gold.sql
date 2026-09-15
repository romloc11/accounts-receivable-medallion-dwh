/* ============================================================================
   Gold tables
   Purpose : Star schema for accounts receivable: dimensions, facts and the
             customer status view.
   Run     : on an empty server. The first eight tables are dropped and rebuilt
             (gold.load_gold refills them in minutes). The four tables of the
             payment application model are only created if missing: they hold
             the 2022-> backfill.
   Notes   : Not here, on purpose, because they keep data that cannot be rebuilt
             from silver: dim_bucket, dim_ejecutivo, dim_region, dim_canal
             (ddl_dim_presupuesto.sql) and the budget facts
             (04_pronostico/ddl_presupuesto.sql).
             The scope rules are defined only in gold.vw_cliente_canal_estatus.
   ============================================================================ */
USE ANALISIS_DATOS;
GO

-- ----------------------------------------------------------------------------
-- gold.dim_fecha: calendar from 2022-01-01 to today + 1 year, extended by
-- gold.load_dim_fecha. Business-day columns are recalculated on every load
-- from gold.dim_festivo (run dim_festivo.sql first).
-- ----------------------------------------------------------------------------
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
    dia_semana           INT NOT NULL,          -- 1 = Sunday (DATEFIRST 7)
    nombre_dia_semana    VARCHAR(15) NOT NULL,
    es_fin_de_semana     BIT NOT NULL,
    semana_anio          INT NOT NULL,           -- ISO week
    anio_mes_num  AS (anio * 100 + mes) PERSISTED NOT NULL,               -- 202608, for sorting
    anio_mes_texto AS (LEFT(nombre_mes, 3) + ' ' + CAST(anio AS VARCHAR(4))) PERSISTED NOT NULL, -- 'Ago 2026'
    es_festivo           BIT NOT NULL DEFAULT 0,
    nombre_festivo       VARCHAR(40),
    es_dia_habil         BIT NOT NULL DEFAULT 0,   -- neither weekend nor holiday
    dia_habil_del_mes    INT,                      -- 1..N business days only; NULL if not a business day
    dias_habiles_mes     INT,                      -- business days in the month
    siguiente_dia_habil  DATE,                     -- same day if business day, else the next one
    CONSTRAINT PK_dim_fecha PRIMARY KEY CLUSTERED (fecha)
);
GO

-- ----------------------------------------------------------------------------
-- gold.dim_cliente: customer identity, SCD1. Loaded with UPDATE + INSERT, never
-- TRUNCATE: it has incoming foreign keys.
-- tipo_cliente: PADRE / FILIAL / SIN_RFC / GENERICO / MARKETPLACE / TRANSITORIA
-- ----------------------------------------------------------------------------
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

-- ----------------------------------------------------------------------------
-- gold.vw_cliente_canal_estatus: ACTIVO / LEGAL / INACTIVO / REVISAR /
-- FUERA_DE_ALCANCE per customer and channel. The one place the scope rules
-- are defined. Salesperson, credit executive and manager: the lowest PARZA
-- wins (SAP's primary assignment).
-- ----------------------------------------------------------------------------
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
        -- Channels 10/20/40/60 are real customers; which of them a report uses
        -- is a report decision, not this one. Ids starting 5/6/7/9 are not customers.
        WHEN v.canal_distribucion NOT IN ('10', '20', '40', '60')
             OR v.cliente_id LIKE '5%' OR v.cliente_id LIKE '6%'
             OR v.cliente_id LIKE '7%' OR v.cliente_id LIKE '9%'
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

-- ----------------------------------------------------------------------------
-- gold.dim_cliente_comercial: SCD2, one representative channel per customer
-- (ACTIVO > LEGAL > REVISAR > INACTIVO > FUERA_DE_ALCANCE, then lowest channel).
-- The channel columns let dim_cliente_credito reuse that choice.
-- ----------------------------------------------------------------------------
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

-- ----------------------------------------------------------------------------
-- gold.dim_cliente_credito: SCD2 credit attributes. Credit analyst and
-- collector are resolved on the channel dim_cliente_comercial chose.
-- ----------------------------------------------------------------------------
IF OBJECT_ID('gold.dim_cliente_credito', 'U') IS NOT NULL
    DROP TABLE gold.dim_cliente_credito;
GO

CREATE TABLE gold.dim_cliente_credito (
    id_surrogate             INT IDENTITY(1,1) NOT NULL,
    cliente_id               VARCHAR(10) NOT NULL,
    limite_credito           DECIMAL(15,2),
    bloqueo_credito          CHAR(1),
    clasificacion_riesgo     VARCHAR(5),
    etiqueta_credito         VARCHAR(11),   -- KRAUS as-is
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

-- ----------------------------------------------------------------------------
-- gold.fact_saldo_cartera: daily snapshot of each customer's open balance.
-- Cannot be backfilled (silver.sap_bsid keeps no history). No scope filter on
-- purpose: it is the whole company's balance; gold.vw_cartera_abierta is the
-- scoped view. Amounts signed by debe_haber, SA documents excluded, 1-16 days
-- overdue is a grace period.
-- ----------------------------------------------------------------------------
IF OBJECT_ID('gold.fact_saldo_cartera', 'U') IS NOT NULL
    DROP TABLE gold.fact_saldo_cartera;
GO

CREATE TABLE gold.fact_saldo_cartera (
    cliente_id                  VARCHAR(10) NOT NULL,
    fecha_snapshot               DATE        NOT NULL,
    saldo_total                  DECIMAL(18,2) NOT NULL,
    saldo_no_vencido              DECIMAL(18,2) NOT NULL,  -- not due yet
    saldo_1_16                   DECIMAL(18,2) NOT NULL,  -- grace period
    saldo_vencido                DECIMAL(18,2) NOT NULL,  -- 17+ days
    num_documentos_abiertos      INT NOT NULL,
    dias_vencido_max             INT NULL,  -- worst case, grace period included
    saldo_17_31                  DECIMAL(18,2) NOT NULL,
    saldo_32_180                 DECIMAL(18,2) NOT NULL,
    saldo_181_mas                DECIMAL(18,2) NOT NULL,
    documentos_con_reclamacion   INT NOT NULL,
    nivel_reclamacion_max        CHAR(1) NULL,
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

-- ----------------------------------------------------------------------------
-- gold.fact_pagos_compensados: legacy raw deposits from silver.sap_bsad, source
-- of gold.vw_pago_factura_simple. Kept until the report moves to fact_pagos.
-- ----------------------------------------------------------------------------
IF OBJECT_ID('gold.fact_pagos_compensados', 'U') IS NOT NULL
    DROP TABLE gold.fact_pagos_compensados;
GO

CREATE TABLE gold.fact_pagos_compensados (
    sociedad                VARCHAR(4)    NOT NULL,
    cliente_id               VARCHAR(10)   NOT NULL,
    ejercicio                 INT           NOT NULL,
    documento_id               VARCHAR(10)   NOT NULL,
    posicion                   INT           NOT NULL,
    fecha_documento             DATE, -- deposit date
    fecha_contabilizacion       DATE, -- the date SAP's monthly payment report uses
    fecha_compensacion          DATE,
    monto_moneda_local          DECIMAL(15,2),
    documento_compensacion      VARCHAR(10), -- clearing group shared with the invoices
    ejercicio_compensacion      INT,
    fecha_carga                 DATETIME DEFAULT GETDATE(),
    CONSTRAINT PK_fact_pagos_compensados PRIMARY KEY CLUSTERED (sociedad, cliente_id, ejercicio, documento_id, posicion)
);
GO

CREATE INDEX IX_fact_pagos_compensados_grupo ON gold.fact_pagos_compensados (documento_compensacion, ejercicio_compensacion);
GO

-- ----------------------------------------------------------------------------
-- gold.fact_facturas_compensadas: legacy cleared invoices (F1-F6) from
-- silver.sap_bsad.
-- ----------------------------------------------------------------------------
IF OBJECT_ID('gold.fact_facturas_compensadas', 'U') IS NOT NULL
    DROP TABLE gold.fact_facturas_compensadas;
GO

CREATE TABLE gold.fact_facturas_compensadas (
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
    CONSTRAINT PK_fact_facturas_compensadas PRIMARY KEY CLUSTERED (sociedad, cliente_id, ejercicio, documento_id, posicion)
);
GO

CREATE INDEX IX_fact_facturas_compensadas_grupo ON gold.fact_facturas_compensadas (documento_compensacion, ejercicio_compensacion);
GO

-- ----------------------------------------------------------------------------
-- gold.dim_empleado: employees, SCD1. Role-playing dimension for salesperson,
-- manager, credit analyst and collector. No foreign keys point to it:
-- ex-employees drop out of silver.sap_pa0001.
-- ----------------------------------------------------------------------------
IF OBJECT_ID('gold.dim_empleado', 'U') IS NOT NULL
    DROP TABLE gold.dim_empleado;
GO

CREATE TABLE gold.dim_empleado (
    id_empleado             VARCHAR(8) NOT NULL,   -- PERNR as-is
    nombre                  VARCHAR(40),
    fecha_actualizacion     DATETIME DEFAULT GETDATE(),
    CONSTRAINT PK_dim_empleado PRIMARY KEY CLUSTERED (id_empleado)
);
GO

-- ============================================================================
-- Payment application model
-- Created only if missing: these four tables hold the 2022-> backfill
-- (backfill_fact_aplicacion_pagos.sql). To rebuild them, drop them by hand and
-- run the backfill again.
--   gold.fact_pagos                 money received, one row per payment line
--   gold.fact_facturas              invoices, cleared and open
--   gold.fact_aplicacion_pagos      bridge: which invoices each payment touched
--   gold.fact_pagos_sin_aplicacion  payments that touched no invoice, and why
-- The bridge carries no amount: at payment x invoice grain no amount adds up.
-- Sum money from fact_pagos and fact_facturas with EXISTS.
-- Columns added later by ALTER are kept last, in the server's column order.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- gold.fact_pagos
-- A payment: DZ line with text 'Asignación Aut. Deposito', or key 11 (automatic
-- deposit) with empty text, that is not a line of a child document (those
-- re-apply money already counted). A reversal (FB08) of a counted line enters
-- with its negative amount. Open payments (bsid) are a snapshot with
-- fecha_compensacion NULL; a line in bsad and bsid at once: bsid wins.
-- ----------------------------------------------------------------------------
IF OBJECT_ID('gold.fact_pagos', 'U') IS NULL
CREATE TABLE gold.fact_pagos (
    sociedad                VARCHAR(4)    NOT NULL,
    cliente_id              VARCHAR(10)   NOT NULL,
    ejercicio               INT           NOT NULL,
    documento_id            VARCHAR(10)   NOT NULL,
    posicion                INT           NOT NULL,
    documento_compensacion  VARCHAR(10),
    ejercicio_compensacion  INT,
    fecha_documento         DATE,   -- deposit date
    fecha_contabilizacion   DATE,   -- the date of SAP's monthly payment report
    fecha_compensacion      DATE,   -- NULL = open payment
    monto                   DECIMAL(15,2) NOT NULL,  -- signed: H positive, S negative
    texto                   VARCHAR(50),
    clave_contabilizacion   VARCHAR(2),
    cliente_comercial_sk    INT,    -- SCD2 version at fecha_contabilizacion
    cliente_credito_sk      INT,
    fecha_carga             DATETIME DEFAULT GETDATE(),
    pago_key AS (CAST(sociedad AS VARCHAR(4)) + '|' + CAST(ejercicio AS VARCHAR(4)) + '|'
                 + documento_id + '|' + CAST(posicion AS VARCHAR(6))) PERSISTED,   -- Power BI key
    cuenta_mayor            VARCHAR(10),    -- cash account of the document; NULL = no cash line
    CONSTRAINT PK_fact_pagos PRIMARY KEY CLUSTERED
        (sociedad, cliente_id, ejercicio, documento_id, posicion)
);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'IX_fact_pagos_grupo' AND object_id = OBJECT_ID('gold.fact_pagos'))
CREATE INDEX IX_fact_pagos_grupo ON gold.fact_pagos (documento_compensacion, ejercicio_compensacion);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'IX_fact_pagos_periodo' AND object_id = OBJECT_ID('gold.fact_pagos'))
CREATE INDEX IX_fact_pagos_periodo ON gold.fact_pagos (fecha_compensacion);
GO

-- ----------------------------------------------------------------------------
-- gold.fact_facturas
-- Cleared invoices (bsad, full history) and open invoices (bsid, snapshot),
-- split by flag_compensada. Classes F1-F5 and D1. A line in bsad and bsid at
-- once: bsid wins. The effective-payment columns are filled by
-- gold.load_fact_facturas_pago_efectivo, after the bridge.
-- ----------------------------------------------------------------------------
IF OBJECT_ID('gold.fact_facturas', 'U') IS NULL
CREATE TABLE gold.fact_facturas (
    sociedad                VARCHAR(4)    NOT NULL,
    cliente_id              VARCHAR(10)   NOT NULL,
    ejercicio               INT           NOT NULL,
    documento_id            VARCHAR(10)   NOT NULL,
    posicion                INT           NOT NULL,
    documento_compensacion  VARCHAR(10),   -- always NULL when open
    ejercicio_compensacion  INT,
    clase_documento         VARCHAR(2)    NOT NULL,  -- F* invoice, D1 debt
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
    fecha_pago_efectiva     DATE,          -- fecha_documento of the last payment that settled it
    dias_pago               INT,           -- from due date; negative = paid before due
    clasificacion_cobranza  VARCHAR(20),   -- PAGO_A_VENCIMIENTO / PAGO_A_MES / PAGO_ANTICIPADO
    factura_key AS (CAST(sociedad AS VARCHAR(4)) + '|' + CAST(ejercicio AS VARCHAR(4)) + '|'
                    + documento_id + '|' + CAST(posicion AS VARCHAR(6))) PERSISTED,   -- Power BI key
    CONSTRAINT PK_fact_facturas PRIMARY KEY CLUSTERED
        (sociedad, cliente_id, ejercicio, documento_id, posicion)
);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'IX_fact_facturas_grupo' AND object_id = OBJECT_ID('gold.fact_facturas'))
CREATE INDEX IX_fact_facturas_grupo ON gold.fact_facturas (documento_compensacion, ejercicio_compensacion);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'IX_fact_facturas_abiertas' AND object_id = OBJECT_ID('gold.fact_facturas'))
CREATE INDEX IX_fact_facturas_abiertas ON gold.fact_facturas (flag_compensada, fecha_vencimiento);
GO

-- ----------------------------------------------------------------------------
-- gold.fact_aplicacion_pagos
-- One row = one payment touched one invoice. regla:
--   GRUPO          the payment's clearing group holds the invoices
--   SEGUNDO_SALTO  the group is a child document that clears on to a final group
--   REFERENCIA     partial payment: an open key-15 line points to an open invoice
-- GRUPO and SEGUNDO_SALTO settle the invoice; REFERENCIA pays part of it.
-- ----------------------------------------------------------------------------
IF OBJECT_ID('gold.fact_aplicacion_pagos', 'U') IS NULL
CREATE TABLE gold.fact_aplicacion_pagos (
    sociedad                VARCHAR(4)  NOT NULL,
    cliente_id              VARCHAR(10) NOT NULL,
    ejercicio_pago          INT         NOT NULL,
    pago_id                 VARCHAR(10) NOT NULL,
    posicion_pago           INT         NOT NULL,
    ejercicio_factura       INT         NOT NULL,
    factura_id              VARCHAR(10) NOT NULL,
    posicion_factura        INT         NOT NULL,
    documento_compensacion  VARCHAR(10) NOT NULL,   -- group where the invoice is (final group for SEGUNDO_SALTO)
    fecha_compensacion      DATE,
    regla                   VARCHAR(20) NOT NULL,
    fecha_carga             DATETIME DEFAULT GETDATE(),
    -- No pago_key: a second relationship to fact_pagos makes Power BI refuse the model.
    factura_key AS (CAST(sociedad AS VARCHAR(4)) + '|' + CAST(ejercicio_factura AS VARCHAR(4)) + '|'
                    + factura_id + '|' + CAST(posicion_factura AS VARCHAR(6))) PERSISTED,
    CONSTRAINT PK_fact_aplicacion_pagos PRIMARY KEY CLUSTERED (
        sociedad, ejercicio_pago, pago_id, posicion_pago,
        ejercicio_factura, factura_id, posicion_factura
    )
);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'IX_fap_factura' AND object_id = OBJECT_ID('gold.fact_aplicacion_pagos'))
CREATE INDEX IX_fap_factura ON gold.fact_aplicacion_pagos
    (ejercicio_factura, factura_id, posicion_factura);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'IX_fap_periodo' AND object_id = OBJECT_ID('gold.fact_aplicacion_pagos'))
CREATE INDEX IX_fap_periodo ON gold.fact_aplicacion_pagos (fecha_compensacion, regla);
GO

-- ----------------------------------------------------------------------------
-- gold.fact_pagos_sin_aplicacion
-- Money that came in and settled no customer invoice. motivo:
--   REVERSADO             the document was reversed, or is the reversal (net zero)
--   LIQUIDA_NO_FACTURA    the chain reaches a group with no invoices (SA, AB)
--   SIN_APLICACION        the payment's group leads nowhere
--   CADENA_AMBIGUA        the intermediate document mixes several payments
--   LINEA_TECNICA         key other than 11/15 (mirrors, reversals)
--   PENDIENTE_DE_APLICAR  open payment, not applied yet
--   REVISAR               unknown case; must be 0
-- Every payment is in the bridge or here: never both, never neither.
-- ----------------------------------------------------------------------------
IF OBJECT_ID('gold.fact_pagos_sin_aplicacion', 'U') IS NULL
CREATE TABLE gold.fact_pagos_sin_aplicacion (
    sociedad                VARCHAR(4)  NOT NULL,
    cliente_id              VARCHAR(10) NOT NULL,
    ejercicio               INT         NOT NULL,
    documento_id            VARCHAR(10) NOT NULL,
    posicion                INT         NOT NULL,
    documento_compensacion  VARCHAR(10),   -- what it did settle
    fecha_compensacion      DATE,
    motivo                  VARCHAR(24) NOT NULL,
    fecha_carga             DATETIME DEFAULT GETDATE(),
    pago_key AS (CAST(sociedad AS VARCHAR(4)) + '|' + CAST(ejercicio AS VARCHAR(4)) + '|'
                 + documento_id + '|' + CAST(posicion AS VARCHAR(6))) PERSISTED,   -- same expression as fact_pagos.pago_key
    CONSTRAINT PK_fact_pagos_sin_aplicacion PRIMARY KEY CLUSTERED
        (sociedad, cliente_id, ejercicio, documento_id, posicion)
);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'IX_fpsa_periodo' AND object_id = OBJECT_ID('gold.fact_pagos_sin_aplicacion'))
CREATE INDEX IX_fpsa_periodo ON gold.fact_pagos_sin_aplicacion (fecha_compensacion, motivo);
GO

-- ----------------------------------------------------------------------------
-- gold.cuenta_mayor_excluida: cash accounts whose payments are not cobranza.
-- Business configuration inserted by hand; account codes are not kept in this
-- repository. Read by gold.load_fact_pagos.
-- ----------------------------------------------------------------------------
IF OBJECT_ID('gold.cuenta_mayor_excluida', 'U') IS NULL
CREATE TABLE gold.cuenta_mayor_excluida (
    cuenta_mayor  VARCHAR(10)  NOT NULL,   -- with leading zeros, as in fact_pagos.cuenta_mayor
    motivo        VARCHAR(200) NOT NULL,
    fecha_alta    DATETIME     NOT NULL DEFAULT GETDATE(),
    CONSTRAINT PK_cuenta_mayor_excluida PRIMARY KEY CLUSTERED (cuenta_mayor)
);
GO
