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
    mandante VARCHAR(3) NOT NULL,
    cliente_id VARCHAR(10) NOT NULL,
    nombre VARCHAR(100),
    poblacion VARCHAR(50),
    pais VARCHAR(3),
    region VARCHAR(3),
    codigo_postal VARCHAR(10),
    rfc_vat VARCHAR(20),
    fecha_creacion DATE,
    grupo_cuentas VARCHAR(4),
    fecha_carga DATETIME DEFAULT GETDATE(),
    CONSTRAINT PK_silver_sap_kna1 PRIMARY KEY (mandante, cliente_id)
);

-- ==========================================================
-- 2. INTERLOCUTORES DE CLIENTES (silver.sap_knvp)
-- ==========================================================
IF OBJECT_ID('silver.sap_knvp', 'U') IS NOT NULL DROP TABLE silver.sap_knvp;
CREATE TABLE silver.sap_knvp (
    mandante VARCHAR(3) NOT NULL,
    cliente_id VARCHAR(10) NOT NULL,
    organizacion_ventas VARCHAR(4) NOT NULL,
    canal_distribucion VARCHAR(2) NOT NULL,
    sector VARCHAR(2) NOT NULL,
    funcion_interlocutor VARCHAR(2) NOT NULL,
    interlocutor_id VARCHAR(10) NOT NULL,
    fecha_carga DATETIME DEFAULT GETDATE(),
    CONSTRAINT PK_silver_sap_knvp PRIMARY KEY (mandante, cliente_id, organizacion_ventas, canal_distribucion, sector, funcion_interlocutor, interlocutor_id)
);

-- ==========================================================
-- 3. LÍMITES DE CRÉDITO (silver.sap_knkk)
-- ==========================================================
IF OBJECT_ID('silver.sap_knkk', 'U') IS NOT NULL DROP TABLE silver.sap_knkk;
CREATE TABLE silver.sap_knkk (
    mandante VARCHAR(3) NOT NULL,
    cliente_id VARCHAR(10) NOT NULL,
    area_control_credito VARCHAR(4) NOT NULL,
    limite_credito DECIMAL(15,2),
    saldo_mantenido DECIMAL(15,2),
    moneda VARCHAR(5),
    bloqueado_credito CHAR(1),
    fecha_carga DATETIME DEFAULT GETDATE(),
    CONSTRAINT PK_silver_sap_knkk PRIMARY KEY (mandante, cliente_id, area_control_credito)
);



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
    oficina_ventas         VARCHAR(4),   -- VKBUR (Oficina de ventas)
    grupo_ventas           VARCHAR(3),   -- VKGRP (Grupo de vendedores)
    distrito_ventas        VARCHAR(6),   -- BZIRK (Distrito / Región de ventas)
    centro_suministrador   VARCHAR(4),   -- VWERK (Centro / Almacén por defecto)
    
    -- Clasificación y Categorías
    grupo_clientes         VARCHAR(2),   -- KDGRP (Grupo de clientes)
    esquema_precios        VARCHAR(2),   -- PLTYP (Tipo de tarifa/lista de precios)
    grupo_condiciones      VARCHAR(2),   -- KONDA (Grupo de condiciones)
    clasificacion_abc      VARCHAR(2),   -- KLABC (Clasificación ABC de cliente)
    
    -- Condiciones Financieras y Crédito
    condicion_pago         VARCHAR(4),   -- ZTERM (Condiciones de pago / Días de crédito)
    moneda                 VARCHAR(5),   -- WAERS (Moneda del área de ventas)
    area_control_credito   VARCHAR(4),   -- KKBER (Área de control de crédito asociada)
    
    -- Bloqueos y Marcas de Control
    bloqueo_entrega        VARCHAR(2),   -- LIFSD (Bloqueo de entrega)
    bloqueo_factura        VARCHAR(2),   -- FAKSD (Bloqueo de facturación)
    bloqueo_pedido         VARCHAR(2),   -- AUFSD (Bloqueo de pedidos)
    peticion_borrado       VARCHAR(1),   -- LOEVM (Petición de borrado a nivel área ventas)
    
    -- Fechas y Auditoría
    fecha_creacion         DATE,         -- ERDAT (Fecha de alta)
    creado_por             VARCHAR(12),  -- ERNAM (Usuario creador)
    fecha_carga            DATETIME DEFAULT GETDATE(),
    
    CONSTRAINT PK_silver_sap_knvv PRIMARY KEY (mandante, cliente_id, organizacion_ventas, canal_distribucion, sector)
);
    
-- ==========================================================
-- 4. PARTIDAS ABIERTAS (silver.sap_bsid)
-- ==========================================================
IF OBJECT_ID('silver.sap_bsid', 'U') IS NOT NULL DROP TABLE silver.sap_bsid;
CREATE TABLE silver.sap_bsid (
    mandante VARCHAR(3) NOT NULL,
    sociedad VARCHAR(4) NOT NULL,
    cliente_id VARCHAR(10) NOT NULL,
    ejercicio INT NOT NULL,
    documento_id VARCHAR(10) NOT NULL,
    posicion INT NOT NULL,
    fecha_contabilizacion DATE,
    fecha_documento DATE,
    fecha_vencimiento DATE,
    clase_documento VARCHAR(2),
    monto_moneda_local DECIMAL(15,2),
    monto_moneda_doc DECIMAL(15,2),
    moneda VARCHAR(5),
    asignacion VARCHAR(18),
    condicion_pago VARCHAR(4),
    fecha_carga DATETIME DEFAULT GETDATE(),
    CONSTRAINT PK_silver_sap_bsid PRIMARY KEY (mandante, sociedad, cliente_id, ejercicio, documento_id, posicion)
);

-- ==========================================================
-- 5. PARTIDAS COMPENSADAS (silver.sap_bsad)
-- ==========================================================
IF OBJECT_ID('silver.sap_bsad', 'U') IS NOT NULL DROP TABLE silver.sap_bsad;
CREATE TABLE silver.sap_bsad (
    mandante VARCHAR(3) NOT NULL,
    sociedad VARCHAR(4) NOT NULL,
    cliente_id VARCHAR(10) NOT NULL,
    ejercicio INT NOT NULL,
    documento_id VARCHAR(10) NOT NULL,
    posicion INT NOT NULL,
    fecha_contabilizacion DATE,
    fecha_documento DATE,
    fecha_compensacion DATE,
    documento_compensacion VARCHAR(10),
    clase_documento VARCHAR(2),
    monto_moneda_local DECIMAL(15,2),
    monto_moneda_doc DECIMAL(15,2),
    moneda VARCHAR(5),
    condicion_pago VARCHAR(4),
    fecha_carga DATETIME DEFAULT GETDATE(),
    CONSTRAINT PK_silver_sap_bsad PRIMARY KEY (mandante, sociedad, cliente_id, ejercicio, documento_id, posicion)
);
GO
