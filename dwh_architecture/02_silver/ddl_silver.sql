USE ANALISIS_DATOS;
GO

/*
===============================================================================
PROJECT: Enterprise Data Warehouse (dwh-ciosa)
LAYER: Silver (Clean Data Staging)
===============================================================================
*/


-- ==========================================================
-- 1. CUSTOMER MASTER (silver.sap_kna1)
-- ==========================================================
IF OBJECT_ID('silver.sap_kna1', 'U') IS NOT NULL DROP TABLE silver.sap_kna1;
CREATE TABLE silver.sap_kna1 (
    mandante                VARCHAR(3)   NOT NULL,
    cliente_id              VARCHAR(10)  NOT NULL,
    rfc                     VARCHAR(16),   -- STCD1
    nombre                  VARCHAR(35),   -- NAME1
    nombre2                 VARCHAR(35),   -- NAME2 (when the name is too long)
    pais                    VARCHAR(3),    -- LAND1
    estado                  VARCHAR(3),    -- REGIO (customer's state code; renamed from "region" to avoid confusion with silver.sap_knvv.region, which is the sales region/BZIRK)
    poblacion                VARCHAR(35),  -- ORT01 (city)
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

-- ==========================================================
-- 2. CUSTOMER PARTNER FUNCTIONS (silver.sap_knvp)
-- ==========================================================
IF OBJECT_ID('silver.sap_knvp', 'U') IS NOT NULL DROP TABLE silver.sap_knvp;
CREATE TABLE silver.sap_knvp (
    mandante                VARCHAR(3)   NOT NULL,
    cliente_id              VARCHAR(10)  NOT NULL,
    organizacion_ventas     VARCHAR(4)   NOT NULL,
    canal_distribucion      VARCHAR(2)   NOT NULL,
    sector                  VARCHAR(2)   NOT NULL,
    funcion_interlocutor    VARCHAR(2)   NOT NULL,
    descripcion_funcion     VARCHAR(40),  -- derived from PARVW (business catalog, see sp_load_silver.sql)
    contador                VARCHAR(3)   NOT NULL,  -- PARZA, completes the PK (bronze uses the same field)
    cliente_asociado        VARCHAR(10),  -- KUNN2
    id_interlocutor         VARCHAR(8),   -- PERNR
    nombre_interlocutor     VARCHAR(40),  -- ENAME resolved from bronze.sap_pa0001 (PERNR, current record ENDDA='99991231'). Only applies when id_interlocutor is a real employee (VE/E1/GR/CC roles); used in the active/legal/inactive classification (see ciosa.py)
    id_paqueteria           VARCHAR(10),  -- LIFNR
    flag_default            BIT,          -- DEFPA
    fecha_carga             DATETIME DEFAULT GETDATE(),
    CONSTRAINT PK_silver_sap_knvp PRIMARY KEY (mandante, cliente_id, organizacion_ventas, canal_distribucion, sector, funcion_interlocutor, contador)
);

-- ==========================================================
-- 3. CREDIT LIMITS (silver.sap_knkk)
-- ==========================================================
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
    fecha_ultima_modificacion_texto DATE,        -- AETXT: date of the last modification to the text attached to the credit record. Used, among other things, to track promissory notes (confirmed with the credit department)
    grupo_credito                  VARCHAR(4),   -- GRUPP: special credit group/status code (real observed values: MORA, PPC, DEPU, ALTO, COM, ESPP, ESPI, FOT1-3, CV1-2, COVI, RESP, among others); exact meaning of each code pending a business catalog
    indicador_pago_db              VARCHAR(3),   -- DBPAY: payment indicator (Dun & Bradstreet integration), observed mix of percentages ('5%','7%'...) and letter ratings ('A'-'D')
    limite_credito_recomendado_db  DECIMAL(15,2),-- DBEKR: recommended credit limit (Dun & Bradstreet). Always in MXN on p01 (see DBWAE in bronze.sap_knkk, a column with a single constant value, not replicated in silver since it adds no information)
    fecha_carga                    DATETIME DEFAULT GETDATE(),
    CONSTRAINT PK_silver_sap_knkk PRIMARY KEY (mandante, cliente_id, area_control_credito)
);

-- ==========================================================
-- NOTE: bronze.sap_knkk columns deliberately NOT included in silver:
-- XCHNG, DBRAT, ABSBT -> 0% of rows have data on p01 (confirmed by count).
-- DTREV, PAYDB, DBMON -> ~99.9%-100% of rows carry only the technical
--   default value ('00000000' or '00'), with no real variation; the rest is
--   scattered noise (a handful of loose rows). They add no business
--   information. If SAP starts actively using them in the future, revalidate
--   with the same kind of count before adding them.
-- ==========================================================

-- ==========================================================
-- 4. SALES AREA DATA (silver.sap_knvv)
-- ==========================================================
IF OBJECT_ID('silver.sap_knvv', 'U') IS NOT NULL DROP TABLE silver.sap_knvv;
CREATE TABLE silver.sap_knvv (
    mandante               VARCHAR(3)   NOT NULL,
    cliente_id             VARCHAR(10)  NOT NULL,
    organizacion_ventas    VARCHAR(4)   NOT NULL,
    canal_distribucion     VARCHAR(2)   NOT NULL,
    sector                 VARCHAR(2)   NOT NULL,

    -- Commercial Organization and Structure
    oficina_ventas         VARCHAR(4),   -- VKBUR
    grupo_vendedores       VARCHAR(3),   -- VKGRP
    region                 VARCHAR(6),   -- BZIRK
    ruta                   VARCHAR(3),   -- KVGR1 (SAP route code)
    ruta_nombre            VARCHAR(20),  -- BEZEI resolved from bronze.sap_tvv1t (MANDT+SPRAS='S'+KVGR1), used in the active/legal/inactive classification (see ciosa.py)
    centro_suministrador   VARCHAR(4),   -- VWERK

    -- Classification and Categories
    grupo_clientes         VARCHAR(2),   -- KDGRP
    grupo_precios          VARCHAR(2),   -- KONDA
    lista_precios          VARCHAR(2),   -- PLTYP

    -- Incoterms and Deliveries
    incoterm               VARCHAR(3),   -- INCO1
    incoterm_descripcion   VARCHAR(28),  -- INCO2
    entregas_parciales_max DECIMAL(1,0), -- ANTLF
    prioridad_entrega      VARCHAR(2),   -- LPRIO
    tiempo_entrega         VARCHAR(3),   -- KVGR2
    tipo_servicio          VARCHAR(3),   -- KVGR3
    tipo_servicio_2        VARCHAR(3),   -- KVGR4
    condicion_expedicion   VARCHAR(2),   -- VSBED: normalized ('1' -> '01') to line up with the 2-digit code already present in the source, see sp_load_silver.sql

    -- Financial Terms
    condicion_pago         VARCHAR(4),   -- ZTERM
    moneda                 VARCHAR(5),   -- WAERS

    -- Blocks and Control Flags
    bloqueo_entrega        VARCHAR(2),   -- LIFSD
    bloqueo_factura        VARCHAR(2),   -- FAKSD
    bloqueo_pedido         VARCHAR(2),   -- AUFSD
    bloqueo_contacto_deudor VARCHAR(2),  -- CASSD: "Dunning contact block" (sales area), confirmed via SE11. Real flag (X/blank, 4.3% of rows), distinct from AUFSD

    -- Dates and Audit
    fecha_creacion         DATE,         -- ERDAT
    creado_por             VARCHAR(12),  -- ERNAM
    fecha_carga            DATETIME DEFAULT GETDATE(),

    CONSTRAINT PK_silver_sap_knvv PRIMARY KEY (mandante, cliente_id, organizacion_ventas, canal_distribucion, sector)
);

-- ==========================================================
-- NOTE: bronze.sap_knvv columns deliberately NOT included in silver
-- (beyond the ~50 execution-logistics/pricing/beverage-industry columns
-- already dropped for scope, see the bkpf/vbrk/vbrp note in ddl_bronze.sql):
-- LOEVM -> not replicated as a column, used as an exclusion FILTER
--   (75 of 29,374 rows flagged 'X', same criterion as kna1).
-- KLABC -> 0.03% of rows have data, no real use.
-- KKBER -> 0% of rows have data at this level (already available via silver.sap_knkk).
-- VERSG -> 98.4% of rows share the same constant value, no real variation.
-- KTGRD -> 97.3% of rows share the same constant value ('Z1'), no real variation.
-- AWAHR -> 99.7% of rows at '100' (order probability, SAP default), no real variation.
-- KVGR5 -> 0% of rows have data.
-- ==========================================================

-- ==========================================================
-- 5. OPEN ITEMS (silver.sap_bsid)
-- ==========================================================
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
    documento_ventas         VARCHAR(10),   -- VBELN: reference to the sales document (SD), 86,961 distinct values out of 88,022 rows, virtually 1:1
    posicion                 INT          NOT NULL,
    fecha_contabilizacion    DATE,          -- BUDAT
    fecha_documento          DATE,          -- BLDAT
    fecha_registro_sistema   DATE,          -- CPUDT
    fecha_vencimiento        DATE,          -- ZFBDT
    clase_documento          VARCHAR(2),    -- BLART
    codigo_impuesto          VARCHAR(2),    -- MWSKZ: VAT code (real observed catalog: B4, B5, B0, WJ)
    debe_haber               CHAR(1),       -- SHKZG
    monto_moneda_local       DECIMAL(15,2), -- DMBTR
    monto_moneda_doc         DECIMAL(15,2), -- WRBTR
    moneda                   VARCHAR(5),    -- WAERS
    condicion_pago           VARCHAR(4),    -- ZTERM
    dias_plazo               DECIMAL(15,2), -- ZBD1T

    -- Dunning at the line-item level
    area_reclamacion              VARCHAR(2), -- MABER
    nivel_reclamacion             CHAR(1),    -- MANST
    clave_reclamacion_legal       CHAR(1),    -- MSCHL
    bloqueo_reclamacion_temporal  CHAR(1),    -- MANSP
    fecha_ultima_reclamacion      DATE,       -- MADAT

    fecha_carga              DATETIME DEFAULT GETDATE(),
    CONSTRAINT PK_silver_sap_bsid PRIMARY KEY (mandante, sociedad, cliente_id, ejercicio, documento_id, posicion)
);

-- ==========================================================
-- NOTE: bronze.sap_bsid columns deliberately NOT included in silver:
-- ZLSPR, RSTGR, BSTAT, UMSKS, UMSKZ, GSBER -> 0% of rows have data on p01.
-- ZLSCH -> 0.05% of rows (43 of 91,235), scattered noise.
-- SKNTO, WSKTO -> 0% of rows (the early-payment discount amount taken is
--   never recorded, even though a discount base exists in SKFBT).
-- SKFBT -> dropped despite 95.1% coverage: in 86,774 of 86,799 rows
--   (99.97%) it's identical to DMBTR, i.e. it's not a real discount base
--   distinct from the total amount, just a copy. The high number of distinct
--   values that seemed to suggest real data is actually inherited from DMBTR.
-- ==========================================================

-- ==========================================================
-- 6. CLEARED ITEMS (silver.sap_bsad)
-- ==========================================================
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
    documento_ventas VARCHAR(10), -- VBELN: reference to the sales document (SD), same as in silver.sap_bsid
    posicion INT NOT NULL,
    fecha_contabilizacion DATE,
    fecha_documento DATE,
    fecha_registro_sistema DATE, -- CPUDT
    fecha_compensacion DATE,
    documento_compensacion VARCHAR(10),
    ejercicio_compensacion INT, -- AUGGJ: fiscal year of documento_compensacion - AUGBL gets reassigned every fiscal year, so without this field the same documento_compensacion number could correspond to different settlements in different years. Added 2026-08-12 to be able to walk the raw-payment -> child -> invoice chain (see gold.fact_pago_factura).
    clase_documento VARCHAR(2),
    codigo_impuesto VARCHAR(2), -- MWSKZ: VAT code, same as in silver.sap_bsid
    debe_haber CHAR(1), -- SHKZG
    fecha_vencimiento DATE, -- ZFBDT: kept from bsid to be able to measure late payments (fecha_compensacion - fecha_vencimiento)
    monto_moneda_local DECIMAL(15,2),
    monto_moneda_doc DECIMAL(15,2),
    moneda VARCHAR(5),
    condicion_pago VARCHAR(4),
    dias_plazo DECIMAL(15,2), -- ZBD1T
    sgtxt VARCHAR(50), -- SGTXT: line item text. 'Asignación Aut. Deposito' identifies the raw payment (the original bank deposit before being applied to invoices) - see gold.fact_pago_factura.
    factura_referencia_documento VARCHAR(10), -- REBZG: invoice document this line directly references (native SAP field) - added 2026-08-13, much more precise than the shared documento_compensacion for tying a payment/credit note/debit note/return/adjustment to ITS specific invoice when the same compensation group bundles several invoices and several applications (see gold.fact_aplicacion_pagos).
    factura_referencia_ejercicio INT, -- REBZJ: fiscal year of factura_referencia_documento
    factura_referencia_posicion INT, -- REBZZ: line item of factura_referencia_documento

    -- Dunning at the line-item level
    area_reclamacion              VARCHAR(2), -- MABER
    nivel_reclamacion             CHAR(1),    -- MANST
    clave_reclamacion_legal       CHAR(1),    -- MSCHL
    bloqueo_reclamacion_temporal  CHAR(1),    -- MANSP
    fecha_ultima_reclamacion      DATE,       -- MADAT

    fecha_carga DATETIME DEFAULT GETDATE(),
    CONSTRAINT PK_silver_sap_bsad PRIMARY KEY (mandante, sociedad, cliente_id, ejercicio, documento_id, posicion)
);

-- ==========================================================
-- 7. CUSTOMER COMPANY CODE DATA (silver.sap_knb1)
-- ==========================================================
IF OBJECT_ID('silver.sap_knb1', 'U') IS NOT NULL DROP TABLE silver.sap_knb1;
CREATE TABLE silver.sap_knb1 (
    mandante                              VARCHAR(3)   NOT NULL,
    sociedad                              VARCHAR(4)   NOT NULL,
    cliente_id                            VARCHAR(10)  NOT NULL,
    fecha_creacion                        DATE,          -- ERDAT
    usuario_creacion                      VARCHAR(12),   -- ERNAM
    cuenta_mayor                          VARCHAR(10),   -- AKONT (reconciliation account)
    clave_orden_partidas                  VARCHAR(3),    -- ZUAWA
    grupo_planificacion_tesoreria         VARCHAR(10),   -- FDGRV (widened from VARCHAR(4) to VARCHAR(10): caused a "String or binary data would be truncated" error when running silver.load_silver, bronze.sap_knb1.FDGRV is NVARCHAR(10))
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
    flag_compensacion_cliente_proveedor   BIT,           -- XZVER: 88.6% of rows are 'X', real variation (vs. 11.4% blank)
    fecha_carga                           DATETIME DEFAULT GETDATE(),
    CONSTRAINT PK_silver_sap_knb1 PRIMARY KEY (mandante, sociedad, cliente_id)
);

-- ==========================================================
-- NOTE: bronze.sap_knb1.QSSKZ DOES NOT EXIST - the "indicador_retencion"
-- column (mapped here from QSSKZ) was defined in earlier versions of this
-- file, but QSSKZ was never a real column of bronze.sap_knb1 (see
-- ddl_bronze.sql, the table doesn't have it). sp_load_silver.sql referenced
-- that nonexistent column in its SELECT - never caught because
-- silver.load_silver had never run successfully. The column was removed
-- from silver.
--
-- NOTE: bronze.sap_knb1 columns deliberately NOT included in silver:
-- BUSAB, ZAHLS, VRBKZ, VLIBB, VRSNR, CESSION_KZ, KVERM -> 0% (or practically
--   0%, BUSAB with 1 of 24,244) of rows have data.
-- VRSPR -> 100% of rows at 0 (constant), no real variation.
-- VERDT -> 100% of rows at '00000000' (default), no real variation.
--   (The three credit-insurance fields VRBKZ/VRSPR/VRSNR/VERDT at 0% or
--   constant are consistent with each other: the credit insurance module
--   isn't in use for this SAP client.)
-- ==========================================================

-- ==========================================================
-- 8. CUSTOMER DUNNING DATA (silver.sap_knb5)
-- ==========================================================
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

-- ==========================================================
-- NOTE: bronze.sap_knb5 does NOT have MANST, MSCHL, or ZTERM columns - they
-- exist in bsid/bsad (same "line-item dunning" block) but KNB5 is a
-- different, smaller table (only 11 columns: MANDT, KUNNR, BUKRS, MABER,
-- MAHNA, MANSP, MADAT, MAHNS, KNRMA, GMVDT, BUSAB). The
-- "nivel_reclamacion"/"clave_reclamacion_legal"/"condicion_pago" columns
-- (previously mapped from MANST/MSCHL/ZTERM) were removed for the same
-- reason as QSSKZ in silver.sap_knb1: they referenced columns that never
-- existed in the real bronze table, never caught because
-- silver.load_silver had never run successfully.
--
-- NOTE: real bronze.sap_knb5 columns deliberately NOT included:
-- KNRMA, GMVDT, BUSAB, MANSP -> 0% (or practically 0%, BUSAB 1 of 15,726)
--   of rows have data.
-- ==========================================================
GO
