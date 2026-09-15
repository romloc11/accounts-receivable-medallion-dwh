/* ============================================================================
   Silver tables
   Purpose : Cleaned SAP tables: trimmed text, real dates, customer ids without
             leading zeros, mandante 400 only, curated columns.
   Run     : on an empty server only. Every table is dropped and recreated, and
             the history loaded by the silver backfills is lost.
   Notes   : Amounts are never signed: apply debe_haber.
             sap_bsid and sap_bsad have the same columns in a different order;
             a UNION between them must list the columns.
   ============================================================================ */
USE ANALISIS_DATOS;
GO

-- ----------------------------------------------------------------------------
-- silver.sap_kna1: customer master
-- ----------------------------------------------------------------------------
IF OBJECT_ID('silver.sap_kna1', 'U') IS NOT NULL DROP TABLE silver.sap_kna1;
CREATE TABLE silver.sap_kna1 (
    mandante                VARCHAR(3)   NOT NULL,
    cliente_id              VARCHAR(10)  NOT NULL,
    rfc                     VARCHAR(16),   -- STCD1
    nombre                  VARCHAR(35),   -- NAME1
    nombre2                 VARCHAR(35),   -- NAME2
    pais                    VARCHAR(3),    -- LAND1
    estado                  VARCHAR(3),    -- REGIO
    poblacion                VARCHAR(35),  -- ORT01
    codigo_postal           VARCHAR(10),   -- PSTLZ
    calle                   VARCHAR(35),   -- STRAS
    bloqueo_pedido          VARCHAR(2),    -- AUFSD
    regimen_fiscal          VARCHAR(10),   -- SORTL
    telefono                VARCHAR(16),   -- TELF1
    telefono_extra          VARCHAR(16),   -- TELF2
    whatsapp                VARCHAR(31),   -- TELFX
    fecha_creacion          DATE,          -- ERDAT
    grupo_cuentas           VARCHAR(4),    -- KTOKD
    proveedor_vinculado     VARCHAR(10),   -- LIFNR
    flag_bloqueado          BIT,           -- SPERR
    flag_cliente_ocasional  BIT,           -- XCPDK
    flag_persona_fisica     BIT,           -- STKZN
    flag_sujeto_iva         BIT,           -- STKZU
    tipo_servicio_paq1      VARCHAR(2),    -- KATR1
    tipo_servicio_paq2      VARCHAR(2),    -- KATR2
    tipo_servicio_paq3      VARCHAR(2),    -- KATR3
    tiempo_entrega_paq1     VARCHAR(3),    -- KATR6
    tiempo_entrega_paq2     VARCHAR(3),    -- KATR7
    tiempo_entrega_paq3     VARCHAR(3),    -- KATR8
    fecha_carga             DATETIME DEFAULT GETDATE(),
    CONSTRAINT PK_silver_sap_kna1 PRIMARY KEY (mandante, cliente_id)
);

-- ----------------------------------------------------------------------------
-- silver.sap_knvp: customer partner functions
-- ----------------------------------------------------------------------------
IF OBJECT_ID('silver.sap_knvp', 'U') IS NOT NULL DROP TABLE silver.sap_knvp;
CREATE TABLE silver.sap_knvp (
    mandante                VARCHAR(3)   NOT NULL,
    cliente_id              VARCHAR(10)  NOT NULL,
    organizacion_ventas     VARCHAR(4)   NOT NULL,
    canal_distribucion      VARCHAR(2)   NOT NULL,
    sector                  VARCHAR(2)   NOT NULL,
    funcion_interlocutor    VARCHAR(2)   NOT NULL,
    descripcion_funcion     VARCHAR(40),  -- from PARVW
    contador                VARCHAR(3)   NOT NULL,  -- PARZA
    cliente_asociado        VARCHAR(10),  -- KUNN2
    id_interlocutor         VARCHAR(8),   -- PERNR
    nombre_interlocutor     VARCHAR(40),  -- ENAME from bronze.sap_pa0001, current record
    id_paqueteria           VARCHAR(10),  -- LIFNR
    flag_default            BIT,          -- DEFPA
    fecha_carga             DATETIME DEFAULT GETDATE(),
    CONSTRAINT PK_silver_sap_knvp PRIMARY KEY (mandante, cliente_id, organizacion_ventas, canal_distribucion, sector, funcion_interlocutor, contador)
);

-- ----------------------------------------------------------------------------
-- silver.sap_knkk: credit control
-- ----------------------------------------------------------------------------
IF OBJECT_ID('silver.sap_knkk', 'U') IS NOT NULL DROP TABLE silver.sap_knkk;
CREATE TABLE silver.sap_knkk (
    mandante                      VARCHAR(3)   NOT NULL,
    cliente_id                    VARCHAR(10)  NOT NULL,
    codigo_padre                  VARCHAR(10),  -- KNKLI
    area_control_credito          VARCHAR(4)   NOT NULL, -- KKBER
    limite_credito                DECIMAL(15,2), -- KLIMK
    monto_facturas_abiertas       DECIMAL(15,2), -- SKFOR
    monto_pedidos_no_facturados   DECIMAL(15,2), -- SAUFT
    monto_especiales_pagares      DECIMAL(15,2), -- SSOBL
    fecha_ultima_revision         DATE,          -- UEDAT
    usuario_creacion              VARCHAR(12),   -- ERNAM
    fecha_creacion                DATE,          -- ERDAT
    prioridad                     VARCHAR(3),    -- CTLPC
    bloqueo_credito                CHAR(1),      -- CRBLB
    fecha_proxima_revision         DATE,         -- NXTRV
    etiqueta_credito               VARCHAR(11),  -- KRAUS
    grupo_responsables_credito     VARCHAR(3),   -- SBGRP
    fecha_cambio_credito_contado   DATE,         -- REVDB
    fecha_ultima_modificacion      DATE,         -- AEDAT
    usuario_ultima_modificacion    VARCHAR(12),  -- AENAM
    fecha_proxima_verificacion     DATE,         -- SBDAT
    tipo_garantia                  VARCHAR(8),   -- KDGRP
    fecha_ultimo_pago              DATE,         -- CASHD
    monto_ultimo_pago              DECIMAL(15,2),-- CASHA
    moneda_ultimo_pago             VARCHAR(5),   -- CASHC
    clasificacion_riesgo           VARCHAR(5),   -- DBRTG
    fecha_ultima_modificacion_texto DATE,        -- AETXT
    grupo_credito                  VARCHAR(4),   -- GRUPP
    indicador_pago_db              VARCHAR(3),   -- DBPAY (D&B)
    limite_credito_recomendado_db  DECIMAL(15,2),-- DBEKR (D&B, MXN)
    fecha_carga                    DATETIME DEFAULT GETDATE(),
    CONSTRAINT PK_silver_sap_knkk PRIMARY KEY (mandante, cliente_id, area_control_credito)
);

-- ----------------------------------------------------------------------------
-- silver.sap_knvv: customer sales area data
-- ----------------------------------------------------------------------------
IF OBJECT_ID('silver.sap_knvv', 'U') IS NOT NULL DROP TABLE silver.sap_knvv;
CREATE TABLE silver.sap_knvv (
    mandante               VARCHAR(3)   NOT NULL,
    cliente_id             VARCHAR(10)  NOT NULL,
    organizacion_ventas    VARCHAR(4)   NOT NULL,
    canal_distribucion     VARCHAR(2)   NOT NULL,
    sector                 VARCHAR(2)   NOT NULL,
    oficina_ventas         VARCHAR(4),   -- VKBUR
    grupo_vendedores       VARCHAR(3),   -- VKGRP
    region                 VARCHAR(6),   -- BZIRK
    ruta                   VARCHAR(3),   -- KVGR1
    ruta_nombre            VARCHAR(20),  -- BEZEI from bronze.sap_tvv1t
    centro_suministrador   VARCHAR(4),   -- VWERK
    grupo_clientes         VARCHAR(2),   -- KDGRP
    grupo_precios          VARCHAR(2),   -- KONDA
    lista_precios          VARCHAR(2),   -- PLTYP
    incoterm               VARCHAR(3),   -- INCO1
    incoterm_descripcion   VARCHAR(28),  -- INCO2
    entregas_parciales_max DECIMAL(1,0), -- ANTLF
    prioridad_entrega      VARCHAR(2),   -- LPRIO
    tiempo_entrega         VARCHAR(3),   -- KVGR2
    tipo_servicio          VARCHAR(3),   -- KVGR3
    tipo_servicio_2        VARCHAR(3),   -- KVGR4
    condicion_expedicion   VARCHAR(2),   -- VSBED, padded to 2 digits
    condicion_pago         VARCHAR(4),   -- ZTERM
    moneda                 VARCHAR(5),   -- WAERS
    bloqueo_entrega        VARCHAR(2),   -- LIFSD
    bloqueo_factura        VARCHAR(2),   -- FAKSD
    bloqueo_pedido         VARCHAR(2),   -- AUFSD
    bloqueo_contacto_deudor VARCHAR(2),  -- CASSD
    fecha_creacion         DATE,         -- ERDAT
    creado_por             VARCHAR(12),  -- ERNAM
    fecha_carga            DATETIME DEFAULT GETDATE(),
    CONSTRAINT PK_silver_sap_knvv PRIMARY KEY (mandante, cliente_id, organizacion_ventas, canal_distribucion, sector)
);

-- ----------------------------------------------------------------------------
-- silver.sap_bsid: open customer items
-- The three clearing columns are always NULL here; they go last because the
-- server received them by ALTER.
-- ----------------------------------------------------------------------------
IF OBJECT_ID('silver.sap_bsid', 'U') IS NOT NULL DROP TABLE silver.sap_bsid;
CREATE TABLE silver.sap_bsid (
    mandante                 VARCHAR(3)   NOT NULL,
    sociedad                 VARCHAR(4)   NOT NULL,
    cliente_id               VARCHAR(10)  NOT NULL,
    ejercicio                INT          NOT NULL,
    mes                      VARCHAR(2),    -- MONAT
    documento_id             VARCHAR(10)  NOT NULL,
    asignacion               VARCHAR(18),   -- ZUONR
    referencia               VARCHAR(16),   -- XBLNR
    documento_ventas         VARCHAR(10),   -- VBELN
    posicion                 INT          NOT NULL,
    fecha_contabilizacion    DATE,          -- BUDAT
    fecha_documento          DATE,          -- BLDAT
    fecha_registro_sistema   DATE,          -- CPUDT
    fecha_vencimiento        DATE,          -- ZFBDT + ZBD1T
    clase_documento          VARCHAR(2),    -- BLART
    codigo_impuesto          VARCHAR(2),    -- MWSKZ
    debe_haber               CHAR(1),       -- SHKZG
    monto_moneda_local       DECIMAL(15,2), -- DMBTR
    monto_moneda_doc         DECIMAL(15,2), -- WRBTR
    moneda                   VARCHAR(5),    -- WAERS
    condicion_pago           VARCHAR(4),    -- ZTERM
    dias_plazo               DECIMAL(15,2), -- ZBD1T
    clave_contabilizacion         VARCHAR(2),  -- BSCHL
    sgtxt                         VARCHAR(50), -- SGTXT
    factura_referencia_documento  VARCHAR(10), -- REBZG ('V' = no invoice reference)
    factura_referencia_ejercicio  INT,         -- REBZJ
    factura_referencia_posicion   INT,         -- REBZZ
    area_reclamacion              VARCHAR(2), -- MABER
    nivel_reclamacion             CHAR(1),    -- MANST
    clave_reclamacion_legal       CHAR(1),    -- MSCHL
    bloqueo_reclamacion_temporal  CHAR(1),    -- MANSP
    fecha_ultima_reclamacion      DATE,       -- MADAT
    fecha_compensacion            DATE,        -- AUGDT
    documento_compensacion        VARCHAR(10), -- AUGBL
    ejercicio_compensacion        INT,         -- AUGGJ
    fecha_carga              DATETIME DEFAULT GETDATE(),
    CONSTRAINT PK_silver_sap_bsid PRIMARY KEY (mandante, sociedad, cliente_id, ejercicio, documento_id, posicion)
);

-- ----------------------------------------------------------------------------
-- silver.sap_bsad: cleared customer items
-- ----------------------------------------------------------------------------
IF OBJECT_ID('silver.sap_bsad', 'U') IS NOT NULL DROP TABLE silver.sap_bsad;
CREATE TABLE silver.sap_bsad (
    mandante VARCHAR(3) NOT NULL,
    sociedad VARCHAR(4) NOT NULL,
    cliente_id VARCHAR(10) NOT NULL,
    ejercicio INT NOT NULL,
    mes VARCHAR(2), -- MONAT
    documento_id VARCHAR(10) NOT NULL,
    asignacion VARCHAR(18), -- ZUONR
    referencia VARCHAR(16), -- XBLNR
    documento_ventas VARCHAR(10), -- VBELN
    posicion INT NOT NULL,
    fecha_contabilizacion DATE, -- BUDAT
    fecha_documento DATE, -- BLDAT
    fecha_registro_sistema DATE, -- CPUDT
    fecha_compensacion DATE, -- AUGDT
    documento_compensacion VARCHAR(10), -- AUGBL
    ejercicio_compensacion INT, -- AUGGJ: AUGBL numbers restart every fiscal year
    clase_documento VARCHAR(2), -- BLART
    codigo_impuesto VARCHAR(2), -- MWSKZ
    debe_haber CHAR(1), -- SHKZG
    clave_contabilizacion VARCHAR(2), -- BSCHL: 11 deposit, 15 payment, 08 mirror, 02/05 reversal
    fecha_vencimiento DATE, -- ZFBDT + ZBD1T
    monto_moneda_local DECIMAL(15,2), -- DMBTR
    monto_moneda_doc DECIMAL(15,2), -- WRBTR
    moneda VARCHAR(5), -- WAERS
    condicion_pago VARCHAR(4), -- ZTERM
    dias_plazo DECIMAL(15,2), -- ZBD1T
    sgtxt VARCHAR(50), -- SGTXT
    factura_referencia_documento VARCHAR(10), -- REBZG ('V' = no invoice reference)
    factura_referencia_ejercicio INT, -- REBZJ
    factura_referencia_posicion INT, -- REBZZ
    area_reclamacion              VARCHAR(2), -- MABER
    nivel_reclamacion             CHAR(1),    -- MANST
    clave_reclamacion_legal       CHAR(1),    -- MSCHL
    bloqueo_reclamacion_temporal  CHAR(1),    -- MANSP
    fecha_ultima_reclamacion      DATE,       -- MADAT
    fecha_carga DATETIME DEFAULT GETDATE(),
    CONSTRAINT PK_silver_sap_bsad PRIMARY KEY (mandante, sociedad, cliente_id, ejercicio, documento_id, posicion)
);

-- Gold's child-document rule and second-hop chains look bsad up by clearing
-- document. Filtered: only used with ANSI_NULLS and QUOTED_IDENTIFIER ON.
CREATE NONCLUSTERED INDEX IX_sap_bsad_dz_compensacion
    ON silver.sap_bsad (documento_compensacion, clave_contabilizacion)
    WHERE clase_documento = 'DZ' AND documento_compensacion IS NOT NULL;

-- ----------------------------------------------------------------------------
-- silver.sap_knb1: customer company code data
-- ----------------------------------------------------------------------------
IF OBJECT_ID('silver.sap_knb1', 'U') IS NOT NULL DROP TABLE silver.sap_knb1;
CREATE TABLE silver.sap_knb1 (
    mandante                              VARCHAR(3)   NOT NULL,
    sociedad                              VARCHAR(4)   NOT NULL,
    cliente_id                            VARCHAR(10)  NOT NULL,
    fecha_creacion                        DATE,          -- ERDAT
    usuario_creacion                      VARCHAR(12),   -- ERNAM
    cuenta_mayor                          VARCHAR(10),   -- AKONT (reconciliation account)
    clave_orden_partidas                  VARCHAR(3),    -- ZUAWA
    grupo_planificacion_tesoreria         VARCHAR(10),   -- FDGRV
    condicion_pago                        VARCHAR(4),    -- ZTERM
    indicador_intereses                   VARCHAR(2),    -- VZSKZ
    fecha_ultima_liquidacion_intereses     DATE,          -- ZINDT
    flag_borrado                          CHAR(1),       -- LOEVM
    bloqueo_contabilizacion               CHAR(1),       -- SPERR
    grupo_autorizacion                    VARCHAR(4),    -- BEGRU
    pais_fiscal                           VARCHAR(3),    -- QLAND
    flag_compensacion_acreedor            CHAR(1),       -- XAUSZ
    cuenta_anterior                       VARCHAR(12),   -- ALTKN
    cuenta_pagador_alterno                VARCHAR(10),   -- KNRZE
    banco_propio                          VARCHAR(5),    -- HBKID
    vias_pago                             VARCHAR(10),   -- ZWELS
    flag_compensacion_cliente_proveedor   BIT,           -- XZVER
    fecha_carga                           DATETIME DEFAULT GETDATE(),
    CONSTRAINT PK_silver_sap_knb1 PRIMARY KEY (mandante, sociedad, cliente_id)
);

-- ----------------------------------------------------------------------------
-- silver.sap_knb5: customer dunning data
-- ----------------------------------------------------------------------------
IF OBJECT_ID('silver.sap_knb5', 'U') IS NOT NULL DROP TABLE silver.sap_knb5;
CREATE TABLE silver.sap_knb5 (
    mandante                    VARCHAR(3)   NOT NULL,
    cliente_id                  VARCHAR(10)  NOT NULL,
    sociedad                    VARCHAR(4)   NOT NULL,
    area_reclamacion            VARCHAR(2)   NOT NULL, -- MABER
    procedimiento_reclamacion   VARCHAR(4),   -- MAHNA
    bloqueo_reclamacion         CHAR(1),      -- MAHNS
    fecha_ultima_reclamacion    DATE,         -- MADAT
    fecha_carga                 DATETIME DEFAULT GETDATE(),
    CONSTRAINT PK_silver_sap_knb5 PRIMARY KEY (mandante, cliente_id, sociedad, area_reclamacion)
);

-- ----------------------------------------------------------------------------
-- silver.sap_pa0001: employees, current record only
-- ----------------------------------------------------------------------------
IF OBJECT_ID('silver.sap_pa0001', 'U') IS NOT NULL DROP TABLE silver.sap_pa0001;
CREATE TABLE silver.sap_pa0001 (
    mandante                VARCHAR(3)   NOT NULL,
    id_empleado             VARCHAR(8)   NOT NULL,  -- PERNR, not zero-stripped: matches sap_knvp.id_interlocutor
    nombre                  VARCHAR(40),             -- ENAME
    fecha_carga             DATETIME DEFAULT GETDATE(),
    CONSTRAINT PK_silver_sap_pa0001 PRIMARY KEY (mandante, id_empleado)
);
GO

-- ----------------------------------------------------------------------------
-- silver.sap_bkpf: document headers (DZ only)
-- ----------------------------------------------------------------------------
IF OBJECT_ID('silver.sap_bkpf', 'U') IS NOT NULL
    DROP TABLE silver.sap_bkpf;
GO

CREATE TABLE silver.sap_bkpf (
    mandante                VARCHAR(3)  NOT NULL,
    sociedad                VARCHAR(4)  NOT NULL,
    ejercicio               INT         NOT NULL,
    documento_id            VARCHAR(10) NOT NULL,
    clase_documento         VARCHAR(2),   -- BLART
    fecha_documento         DATE,         -- BLDAT
    fecha_contabilizacion   DATE,         -- BUDAT
    fecha_registro_sistema  DATE,         -- CPUDT
    mes                     VARCHAR(2),   -- MONAT
    usuario                 VARCHAR(12),  -- USNAM
    transaccion             VARCHAR(20),  -- TCODE: OS_APPLICATION, FBZ1, FB05, FB08, FBZ2
    referencia              VARCHAR(16),  -- XBLNR
    texto_cabecera          VARCHAR(25),  -- BKTXT
    documento_reversa       VARCHAR(10),  -- STBLG: the other document of a reversal pair
    ejercicio_reversa       INT,          -- STJAH
    motivo_reversa          VARCHAR(2),   -- STGRD
    indicador_reversa       VARCHAR(1),   -- XREVERSAL: 1 = reversed original, 2 = reversal
    moneda                  VARCHAR(5),   -- WAERS
    fecha_carga             DATETIME DEFAULT GETDATE(),
    CONSTRAINT PK_silver_sap_bkpf PRIMARY KEY (mandante, sociedad, ejercicio, documento_id)
);
GO

-- ----------------------------------------------------------------------------
-- silver.sap_bsas / silver.sap_bsis: cleared and open G/L lines, cash accounts
-- Same columns in both, so gold can UNION them. cuenta_mayor keeps its
-- leading zeros. On a cash account S (debit) is money in.
-- ----------------------------------------------------------------------------
IF OBJECT_ID('silver.sap_bsas', 'U') IS NOT NULL
    DROP TABLE silver.sap_bsas;
GO

CREATE TABLE silver.sap_bsas (
    mandante                          VARCHAR(3)  NOT NULL,
    sociedad                          VARCHAR(4)  NOT NULL,
    cuenta_mayor                      VARCHAR(10) NOT NULL, -- HKONT
    ejercicio                         INT         NOT NULL, -- GJAHR
    documento_id                      VARCHAR(10) NOT NULL, -- BELNR
    posicion                          INT         NOT NULL, -- BUZEI
    mes                               VARCHAR(2),           -- MONAT
    clase_documento                   VARCHAR(2),           -- BLART
    fecha_contabilizacion             DATE,                 -- BUDAT
    fecha_documento                   DATE,                 -- BLDAT
    fecha_valor                       DATE,                 -- VALUT
    debe_haber                        CHAR(1),              -- SHKZG
    monto_moneda_local                DECIMAL(15,2),        -- DMBTR
    monto_moneda_doc                  DECIMAL(15,2),        -- WRBTR
    moneda                            VARCHAR(5),           -- WAERS
    asignacion                        VARCHAR(18),          -- ZUONR
    referencia                        VARCHAR(16),          -- XBLNR
    sgtxt                             VARCHAR(50),          -- SGTXT
    fecha_compensacion                DATE,                 -- AUGDT
    documento_compensacion            VARCHAR(10),          -- AUGBL
    ejercicio_compensacion            INT,                  -- AUGGJ ('0000' -> NULL)
    indicador_partidas_abiertas       VARCHAR(1),           -- XOPVW: 'X' = account whose lines get cleared
    indicador_compensacion_revertida  VARCHAR(1),           -- XRAGL: the clearing was reset once
    fecha_carga                       DATETIME DEFAULT GETDATE(),
    CONSTRAINT PK_silver_sap_bsas PRIMARY KEY (mandante, sociedad, cuenta_mayor, ejercicio, documento_id, posicion)
);
GO

-- The PK leads with the account; gold looks lines up by document and by date.
CREATE NONCLUSTERED INDEX IX_silver_sap_bsas_documento ON silver.sap_bsas (documento_id, ejercicio);
CREATE NONCLUSTERED INDEX IX_silver_sap_bsas_fecha ON silver.sap_bsas (fecha_contabilizacion)
    INCLUDE (cuenta_mayor, clase_documento, debe_haber, monto_moneda_local);
GO

IF OBJECT_ID('silver.sap_bsis', 'U') IS NOT NULL
    DROP TABLE silver.sap_bsis;
GO

CREATE TABLE silver.sap_bsis (
    mandante                          VARCHAR(3)  NOT NULL,
    sociedad                          VARCHAR(4)  NOT NULL,
    cuenta_mayor                      VARCHAR(10) NOT NULL, -- HKONT
    ejercicio                         INT         NOT NULL, -- GJAHR
    documento_id                      VARCHAR(10) NOT NULL, -- BELNR
    posicion                          INT         NOT NULL, -- BUZEI
    mes                               VARCHAR(2),           -- MONAT
    clase_documento                   VARCHAR(2),           -- BLART
    fecha_contabilizacion             DATE,                 -- BUDAT
    fecha_documento                   DATE,                 -- BLDAT
    fecha_valor                       DATE,                 -- VALUT
    debe_haber                        CHAR(1),              -- SHKZG
    monto_moneda_local                DECIMAL(15,2),        -- DMBTR
    monto_moneda_doc                  DECIMAL(15,2),        -- WRBTR
    moneda                            VARCHAR(5),           -- WAERS
    asignacion                        VARCHAR(18),          -- ZUONR
    referencia                        VARCHAR(16),          -- XBLNR
    sgtxt                             VARCHAR(50),          -- SGTXT
    fecha_compensacion                DATE,                 -- AUGDT, always NULL here
    documento_compensacion            VARCHAR(10),          -- AUGBL, always NULL here
    ejercicio_compensacion            INT,                  -- AUGGJ, always NULL here
    indicador_partidas_abiertas       VARCHAR(1),           -- XOPVW
    indicador_compensacion_revertida  VARCHAR(1),           -- XRAGL
    fecha_carga                       DATETIME DEFAULT GETDATE(),
    CONSTRAINT PK_silver_sap_bsis PRIMARY KEY (mandante, sociedad, cuenta_mayor, ejercicio, documento_id, posicion)
);
GO

CREATE NONCLUSTERED INDEX IX_silver_sap_bsis_documento ON silver.sap_bsis (documento_id, ejercicio);
CREATE NONCLUSTERED INDEX IX_silver_sap_bsis_fecha ON silver.sap_bsis (fecha_contabilizacion)
    INCLUDE (cuenta_mayor, clase_documento, debe_haber, monto_moneda_local);
GO
