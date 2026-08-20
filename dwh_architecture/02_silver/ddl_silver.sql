USE ANALISIS_DATOS;
GO

/*
===============================================================================
PROJECT: Enterprise Data Warehouse (dwh-ciosa)
LAYER: Silver (Clean Data Staging)
===============================================================================
*/


-- ==========================================================
-- 1. MAESTRO DE CLIENTES (silver.sap_kna1)
-- ==========================================================
IF OBJECT_ID('silver.sap_kna1', 'U') IS NOT NULL DROP TABLE silver.sap_kna1;
CREATE TABLE silver.sap_kna1 (
    mandante                VARCHAR(3)   NOT NULL,
    cliente_id              VARCHAR(10)  NOT NULL,
    rfc                     VARCHAR(16),   -- STCD1
    nombre                  VARCHAR(35),   -- NAME1
    nombre2                 VARCHAR(35),   -- NAME2 (cuando el nombre es muy largo)
    pais                    VARCHAR(3),    -- LAND1
    estado                  VARCHAR(3),    -- REGIO (clave del estado del cliente; renombrado de "region" para no confundirse con silver.sap_knvv.region, que es la region de ventas/BZIRK)
    poblacion                VARCHAR(35),  -- ORT01 (ciudad)
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
-- 2. INTERLOCUTORES DE CLIENTES (silver.sap_knvp)
-- ==========================================================
IF OBJECT_ID('silver.sap_knvp', 'U') IS NOT NULL DROP TABLE silver.sap_knvp;
CREATE TABLE silver.sap_knvp (
    mandante                VARCHAR(3)   NOT NULL,
    cliente_id              VARCHAR(10)  NOT NULL,
    organizacion_ventas     VARCHAR(4)   NOT NULL,
    canal_distribucion      VARCHAR(2)   NOT NULL,
    sector                  VARCHAR(2)   NOT NULL,
    funcion_interlocutor    VARCHAR(2)   NOT NULL,
    descripcion_funcion     VARCHAR(40),  -- derivado de PARVW (catalogo de negocio, ver sp_load_silver.sql)
    contador                VARCHAR(3)   NOT NULL,  -- PARZA, completa la PK (bronze usa el mismo campo)
    cliente_asociado        VARCHAR(10),  -- KUNN2
    id_interlocutor         VARCHAR(8),   -- PERNR
    nombre_interlocutor     VARCHAR(40),  -- ENAME resuelto desde bronze.sap_pa0001 (PERNR, registro vigente ENDDA='99991231'). Solo aplica cuando id_interlocutor es un empleado real (roles VE/E1/GR/CC); usado en la clasificacion activo/legal/inactivo (ver ciosa.py)
    id_paqueteria           VARCHAR(10),  -- LIFNR
    flag_default            BIT,          -- DEFPA
    fecha_carga             DATETIME DEFAULT GETDATE(),
    CONSTRAINT PK_silver_sap_knvp PRIMARY KEY (mandante, cliente_id, organizacion_ventas, canal_distribucion, sector, funcion_interlocutor, contador)
);

-- ==========================================================
-- 3. LÍMITES DE CRÉDITO (silver.sap_knkk)
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
    fecha_ultima_modificacion_texto DATE,        -- AETXT: fecha de la ultima modificacion del texto asociado al registro de credito. Se usa para dar seguimiento a pagares, entre otras cosas (confirmado con el area de credito)
    grupo_credito                  VARCHAR(4),   -- GRUPP: codigo de grupo/estado especial de credito (valores reales observados: MORA, PPC, DEPU, ALTO, COM, ESPP, ESPI, FOT1-3, CV1-2, COVI, RESP, entre otros); significado exacto de cada codigo pendiente de catalogo de negocio
    indicador_pago_db              VARCHAR(3),   -- DBPAY: indicador de pago (integracion Dun & Bradstreet), mezcla observada de porcentajes ('5%','7%'...) y calificaciones por letra ('A'-'D')
    limite_credito_recomendado_db  DECIMAL(15,2),-- DBEKR: limite de credito recomendado (Dun & Bradstreet). Siempre en MXN en p01 (ver DBWAE en bronze.sap_knkk, columna con un unico valor constante, no se replico en silver por no aportar informacion)
    fecha_carga                    DATETIME DEFAULT GETDATE(),
    CONSTRAINT PK_silver_sap_knkk PRIMARY KEY (mandante, cliente_id, area_control_credito)
);

-- ==========================================================
-- NOTA: columnas de bronze.sap_knkk deliberadamente NO incluidas en silver:
-- XCHNG, DBRAT, ABSBT -> 0% de filas con dato en p01 (confirmado por conteo).
-- DTREV, PAYDB, DBMON -> ~99.9%-100% de las filas traen unicamente el valor
--   por defecto tecnico ('00000000' o '00'), sin variacion real; el resto es
--   ruido disperso (un puñado de filas sueltas). No aportan informacion de
--   negocio. Si SAP llega a usarlos activamente en el futuro, revalidar con
--   el mismo tipo de conteo antes de incorporarlos.
-- ==========================================================

-- ==========================================================
-- 4. DATOS AREA DE VENTAS (silver.sap_knvv)
-- ==========================================================
IF OBJECT_ID('silver.sap_knvv', 'U') IS NOT NULL DROP TABLE silver.sap_knvv;
CREATE TABLE silver.sap_knvv (
    mandante               VARCHAR(3)   NOT NULL,
    cliente_id             VARCHAR(10)  NOT NULL,
    organizacion_ventas    VARCHAR(4)   NOT NULL,
    canal_distribucion     VARCHAR(2)   NOT NULL,
    sector                 VARCHAR(2)   NOT NULL,

    -- Organización y Estructura Comercial
    oficina_ventas         VARCHAR(4),   -- VKBUR
    grupo_vendedores       VARCHAR(3),   -- VKGRP
    region                 VARCHAR(6),   -- BZIRK
    ruta                   VARCHAR(3),   -- KVGR1 (codigo sap de la ruta)
    ruta_nombre            VARCHAR(20),  -- BEZEI resuelto desde bronze.sap_tvv1t (MANDT+SPRAS='S'+KVGR1), usado en la clasificacion activo/legal/inactivo (ver ciosa.py)
    centro_suministrador   VARCHAR(4),   -- VWERK

    -- Clasificación y Categorías
    grupo_clientes         VARCHAR(2),   -- KDGRP
    grupo_precios          VARCHAR(2),   -- KONDA
    lista_precios          VARCHAR(2),   -- PLTYP

    -- Incoterms y Entregas
    incoterm               VARCHAR(3),   -- INCO1
    incoterm_descripcion   VARCHAR(28),  -- INCO2
    entregas_parciales_max DECIMAL(1,0), -- ANTLF
    prioridad_entrega      VARCHAR(2),   -- LPRIO
    tiempo_entrega         VARCHAR(3),   -- KVGR2
    tipo_servicio          VARCHAR(3),   -- KVGR3
    tipo_servicio_2        VARCHAR(3),   -- KVGR4
    condicion_expedicion   VARCHAR(2),   -- VSBED: normalizado ('1' -> '01') para unificar con el codigo de 2 digitos ya existente en el origen, ver sp_load_silver.sql

    -- Condiciones Financieras
    condicion_pago         VARCHAR(4),   -- ZTERM
    moneda                 VARCHAR(5),   -- WAERS

    -- Bloqueos y Marcas de Control
    bloqueo_entrega        VARCHAR(2),   -- LIFSD
    bloqueo_factura        VARCHAR(2),   -- FAKSD
    bloqueo_pedido         VARCHAR(2),   -- AUFSD
    bloqueo_contacto_deudor VARCHAR(2),  -- CASSD: "Bloqueo de contacto para deudores" (area de ventas), confirmado via SE11. Flag real (X/blanco, 4.3% de las filas), distinto de AUFSD

    -- Fechas y Auditoría
    fecha_creacion         DATE,         -- ERDAT
    creado_por             VARCHAR(12),  -- ERNAM
    fecha_carga            DATETIME DEFAULT GETDATE(),

    CONSTRAINT PK_silver_sap_knvv PRIMARY KEY (mandante, cliente_id, organizacion_ventas, canal_distribucion, sector)
);

-- ==========================================================
-- NOTA: columnas de bronze.sap_knvv deliberadamente NO incluidas en silver
-- (fuera de las ~50 de logistica de ejecucion/pricing/industria de bebidas
-- ya descartadas por alcance, ver nota de bkpf/vbrk/vbrp en ddl_bronze.sql):
-- LOEVM -> no se replica como columna, se usa como FILTRO de exclusion
--   (75 de 29,374 filas marcadas 'X', mismo criterio que kna1).
-- KLABC -> 0.03% de las filas con dato, sin uso real.
-- KKBER -> 0% de las filas con dato a este nivel (ya se tiene via silver.sap_knkk).
-- VERSG -> 98.4% de las filas con el mismo valor constante, sin variacion real.
-- KTGRD -> 97.3% de las filas con el mismo valor constante ('Z1'), sin variacion real.
-- AWAHR -> 99.7% de las filas en '100' (probabilidad de pedido, default SAP), sin variacion real.
-- KVGR5 -> 0% de las filas con dato.
-- ==========================================================

-- ==========================================================
-- 5. PARTIDAS ABIERTAS (silver.sap_bsid)
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
    documento_ventas         VARCHAR(10),   -- VBELN: referencia al documento de ventas (SD), 86,961 valores distintos de 88,022 filas, practicamente 1:1
    posicion                 INT          NOT NULL,
    fecha_contabilizacion    DATE,          -- BUDAT
    fecha_documento          DATE,          -- BLDAT
    fecha_registro_sistema   DATE,          -- CPUDT
    fecha_vencimiento        DATE,          -- ZFBDT
    clase_documento          VARCHAR(2),    -- BLART
    codigo_impuesto          VARCHAR(2),    -- MWSKZ: codigo de IVA (catalogo real observado: B4, B5, B0, WJ)
    debe_haber               CHAR(1),       -- SHKZG
    monto_moneda_local       DECIMAL(15,2), -- DMBTR
    monto_moneda_doc         DECIMAL(15,2), -- WRBTR
    moneda                   VARCHAR(5),    -- WAERS
    condicion_pago           VARCHAR(4),    -- ZTERM
    dias_plazo               DECIMAL(15,2), -- ZBD1T

    -- Reclamacion / Cobranza (dunning) a nivel de partida
    area_reclamacion              VARCHAR(2), -- MABER
    nivel_reclamacion             CHAR(1),    -- MANST
    clave_reclamacion_legal       CHAR(1),    -- MSCHL
    bloqueo_reclamacion_temporal  CHAR(1),    -- MANSP
    fecha_ultima_reclamacion      DATE,       -- MADAT

    fecha_carga              DATETIME DEFAULT GETDATE(),
    CONSTRAINT PK_silver_sap_bsid PRIMARY KEY (mandante, sociedad, cliente_id, ejercicio, documento_id, posicion)
);

-- ==========================================================
-- NOTA: columnas de bronze.sap_bsid deliberadamente NO incluidas en silver:
-- ZLSPR, RSTGR, BSTAT, UMSKS, UMSKZ, GSBER -> 0% de filas con dato en p01.
-- ZLSCH -> 0.05% de las filas (43 de 91,235), ruido disperso.
-- SKNTO, WSKTO -> 0% de las filas (nunca se registra el importe de descuento
--   por pronto pago tomado, aunque exista una base de descuento en SKFBT).
-- SKFBT -> descartado pese a 95.1% de cobertura: en 86,774 de 86,799 filas
--   (99.97%) es identico a DMBTR, es decir, no es una base de descuento real
--   distinta del monto total, solo una copia. La alta cantidad de valores
--   distintos que parecia sugerir datos reales en realidad la hereda de DMBTR.
-- ==========================================================

-- ==========================================================
-- 6. PARTIDAS COMPENSADAS (silver.sap_bsad)
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
    documento_ventas VARCHAR(10), -- VBELN: referencia al documento de ventas (SD), igual que en silver.sap_bsid
    posicion INT NOT NULL,
    fecha_contabilizacion DATE,
    fecha_documento DATE,
    fecha_registro_sistema DATE, -- CPUDT
    fecha_compensacion DATE,
    documento_compensacion VARCHAR(10),
    ejercicio_compensacion INT, -- AUGGJ: ejercicio fiscal del documento_compensacion - AUGBL se reasigna cada año fiscal, asi que sin este campo un mismo numero de documento_compensacion puede corresponder a compensaciones distintas en años distintos. Agregado 2026-08-12 para poder caminar la cadena pago virgen -> hijo -> factura (ver gold.fact_pago_factura).
    clase_documento VARCHAR(2),
    codigo_impuesto VARCHAR(2), -- MWSKZ: codigo de IVA, igual que en silver.sap_bsid
    debe_haber CHAR(1), -- SHKZG
    fecha_vencimiento DATE, -- ZFBDT: se conserva desde bsid para poder medir pagos tardios (fecha_compensacion - fecha_vencimiento)
    monto_moneda_local DECIMAL(15,2),
    monto_moneda_doc DECIMAL(15,2),
    moneda VARCHAR(5),
    condicion_pago VARCHAR(4),
    dias_plazo DECIMAL(15,2), -- ZBD1T
    sgtxt VARCHAR(50), -- SGTXT: texto de la posicion. 'Asignación Aut. Deposito' identifica el pago virgen (deposito bancario original antes de aplicarse a facturas) - ver gold.fact_pago_factura.
    factura_referencia_documento VARCHAR(10), -- REBZG: documento de la factura a la que esta linea hace referencia directa (nativo de SAP) - agregado 2026-08-13, mucho mas preciso que documento_compensacion compartido para ligar pago/NC/ND/devolucion/ajuste a SU factura especifica cuando un mismo grupo de compensacion agrupa varias facturas y varias aplicaciones (ver gold.fact_aplicacion_pagos).
    factura_referencia_ejercicio INT, -- REBZJ: ejercicio fiscal de factura_referencia_documento
    factura_referencia_posicion INT, -- REBZZ: posicion de factura_referencia_documento

    -- Reclamacion / Cobranza (dunning) a nivel de partida
    area_reclamacion              VARCHAR(2), -- MABER
    nivel_reclamacion             CHAR(1),    -- MANST
    clave_reclamacion_legal       CHAR(1),    -- MSCHL
    bloqueo_reclamacion_temporal  CHAR(1),    -- MANSP
    fecha_ultima_reclamacion      DATE,       -- MADAT

    fecha_carga DATETIME DEFAULT GETDATE(),
    CONSTRAINT PK_silver_sap_bsad PRIMARY KEY (mandante, sociedad, cliente_id, ejercicio, documento_id, posicion)
);

-- ==========================================================
-- 7. DATOS DE SOCIEDAD DEL CLIENTE (silver.sap_knb1)
-- ==========================================================
IF OBJECT_ID('silver.sap_knb1', 'U') IS NOT NULL DROP TABLE silver.sap_knb1;
CREATE TABLE silver.sap_knb1 (
    mandante                              VARCHAR(3)   NOT NULL,
    sociedad                              VARCHAR(4)   NOT NULL,
    cliente_id                            VARCHAR(10)  NOT NULL,
    fecha_creacion                        DATE,          -- ERDAT
    usuario_creacion                      VARCHAR(12),   -- ERNAM
    cuenta_mayor                          VARCHAR(10),   -- AKONT (cuenta de enlace)
    clave_orden_partidas                  VARCHAR(3),    -- ZUAWA
    grupo_planificacion_tesoreria         VARCHAR(10),   -- FDGRV (ensanchado de VARCHAR(4) a VARCHAR(10): causaba "String or binary data would be truncated" al ejecutar silver.load_silver, bronze.sap_knb1.FDGRV es NVARCHAR(10))
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
    flag_compensacion_cliente_proveedor   BIT,           -- XZVER: 88.6% de las filas en 'X', variacion real (vs 11.4% en blanco)
    fecha_carga                           DATETIME DEFAULT GETDATE(),
    CONSTRAINT PK_silver_sap_knb1 PRIMARY KEY (mandante, sociedad, cliente_id)
);

-- ==========================================================
-- NOTA: bronze.sap_knb1.QSSKZ NO EXISTE - la columna "indicador_retencion"
-- (mapeada aqui desde QSSKZ) estaba definida en versiones anteriores de este
-- archivo pero QSSKZ nunca fue una columna real de bronze.sap_knb1 (ver
-- ddl_bronze.sql, la tabla no la tiene). sp_load_silver.sql referenciaba esa
-- columna inexistente en el SELECT - nunca se detecto porque silver.load_silver
-- nunca se habia ejecutado con exito. Se elimino la columna de silver.
--
-- NOTA: columnas de bronze.sap_knb1 deliberadamente NO incluidas en silver:
-- BUSAB, ZAHLS, VRBKZ, VLIBB, VRSNR, CESSION_KZ, KVERM -> 0% (o practicamente
--   0%, BUSAB con 1 de 24,244) de las filas con dato.
-- VRSPR -> 100% de las filas en 0 (constante), sin variacion real.
-- VERDT -> 100% de las filas en '00000000' (default), sin variacion real.
--   (Los tres campos de seguro de credito VRBKZ/VRSPR/VRSNR/VERDT en 0% o
--   constante son consistentes entre si: el modulo de seguro de credito no
--   esta en uso en este cliente SAP).
-- ==========================================================

-- ==========================================================
-- 8. DATOS DE RECLAMACION DEL CLIENTE (silver.sap_knb5)
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
-- NOTA: bronze.sap_knb5 NO tiene columnas MANST, MSCHL ni ZTERM - existen en
-- bsid/bsad (mismo bloque de "reclamacion/cobranza a nivel de partida") pero
-- KNB5 es una tabla distinta y mas pequeña (solo 11 columnas: MANDT, KUNNR,
-- BUKRS, MABER, MAHNA, MANSP, MADAT, MAHNS, KNRMA, GMVDT, BUSAB). Las
-- columnas "nivel_reclamacion"/"clave_reclamacion_legal"/"condicion_pago"
-- (mapeadas antes desde MANST/MSCHL/ZTERM) se eliminaron por el mismo motivo
-- que QSSKZ en silver.sap_knb1: referenciaban columnas que nunca existieron
-- en el bronze real, nunca detectado porque silver.load_silver nunca se
-- habia ejecutado con exito.
--
-- NOTA: columnas reales de bronze.sap_knb5 deliberadamente NO incluidas:
-- KNRMA, GMVDT, BUSAB, MANSP -> 0% (o practicamente 0%, BUSAB 1 de 15,726)
--   de las filas con dato.
-- ==========================================================
GO
