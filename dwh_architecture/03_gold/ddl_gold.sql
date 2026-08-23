USE ANALISIS_DATOS;
GO

/*
===============================================================================
PROJECT: Enterprise Data Warehouse (dwh-ciosa)
LAYER: Gold (Presentation / Star Schema)
===============================================================================
*/

-- ==========================================================
-- 1. DIMENSION: gold.dim_fecha (Calendar)
-- NO SCD. GROWING range (not static): fixed lower bound at 2022-01-01
-- (bronze.sap_bsad's real start date) and upper bound = today + 1 year,
-- automatically extended by gold.load_dim_fecha on every gold.load_gold run
-- (see sp_load_gold.sql) - the 1-year cushion ahead covers future due dates
-- (NET-90-style payment terms) without needing a fixed range out to 2035.
-- REDESIGNED 2026-08-20: it used to be static 2020-01-01/2035-12-31,
-- populated once via populate_dim_fecha.sql (retired, its bootstrap logic
-- now lives inside gold.load_dim_fecha) - the user preferred the calendar
-- to reflect the real data period instead of showing years with no real
-- transactions (this was noticeable, for example, in the Power BI report's
-- Year filter, which offered the full 2020-2035 regardless of real data
-- only existing since 2022).
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
    dia_semana           INT NOT NULL,          -- 1=Sunday ... 7=Saturday (explicitly set via SET DATEFIRST 7 when populating)
    nombre_dia_semana    VARCHAR(15) NOT NULL,
    es_fin_de_semana     BIT NOT NULL,
    semana_anio          INT NOT NULL,           -- ISO week of the year

    -- Added 2026-08-20 for the "real calendar month" axis in the Power BI
    -- report (Total Amount Received Trend) - without this, grouping by
    -- nombre_mes lumps Aug-2025 together with Aug-2026 in a single bar.
    -- CALCULATED columns (AS ... PERSISTED): auto-populate from
    -- anio/mes/nombre_mes, need no extra logic in gold.load_dim_fecha.
    anio_mes_num  AS (anio * 100 + mes) PERSISTED NOT NULL,               -- e.g. 202608, for chronological sorting
    anio_mes_texto AS (LEFT(nombre_mes, 3) + ' ' + CAST(anio AS VARCHAR(4))) PERSISTED NOT NULL, -- e.g. 'Ago 2026'

    CONSTRAINT PK_dim_fecha PRIMARY KEY CLUSTERED (fecha)
);
GO

PRINT 'Table gold.dim_fecha created successfully.';
GO

-- ==========================================================
-- 2. DIMENSION: gold.dim_cliente (SCD Type 1 - Customer Identity)
-- Source: silver.sap_kna1 LEFT JOIN silver.sap_knkk (by cliente_id; knkk is
-- already filtered to KKBER='2000' in silver, so the join is 1:1 or 1:0,
-- with no need to repeat the filter here).
-- SCD1: fully overwritten on every load (TRUNCATE+INSERT), with NO version
-- history - unlike dim_cliente_credito/comercial (SCD2, below), these
-- attributes almost never change.
-- Key: cliente_id directly (no surrogate key - not needed for SCD1, and
-- keeps consistency with the rest of the project, which uses business
-- keys). mandante is NOT included (always '400', zero variation).
-- tipo_cliente = PADRE / FILIAL / DIRECCION_ALTERNA / GENERICO, full logic
-- in gold.load_dim_cliente (sp_load_gold.sql).
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
-- ACTIVO/LEGAL/INACTIVO/REVISAR/FUERA_DE_ALCANCE classification for each
-- customer+channel row of silver.sap_knvv (full grain, NOT yet reduced to 1
-- row per customer - gold.load_dim_cliente_comercial does that on top of
-- this view). Logic ported from ciosa.py (see dwh-ciosa-project-status.md
-- in memory for the detail of each rule), confirmed against real data:
--   - "Order block" = knvv.bloqueo_pedido (channel level, NOT kna1 - 1,429
--     customers have a different block between channels, confirming it's
--     the right field).
--   - "Sales zone" = knvv.region (BZIRK) - confirmed, 327 rows with
--     'MXZLEG' in real data.
--   - salesperson/credit_executive/manager: from silver.sap_knvp (roles
--     VE/E1/GR), taking the lowest 'contador' (PARZA) when there's more
--     than one assignment of the same role in the same channel (SAP
--     convention: lowest number = primary assignment).
--   - Customer prefix 5/6/7: applied on cliente_id ALREADY without leading
--     zeros (silver has done it that way since 2026-08-07) - matches how
--     ciosa.py read the field in Python (numeric, unpadded).
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
        -- 2026-08-14: scoping channel down to 10/40/60 (excluding
        -- 20/retail) was tried across the WHOLE project - REVERTED
        -- 2026-08-17. The original business rule (confirmed by the user) is
        -- that REAL customers live in channel 10 (wholesale) / 20 (retail)
        -- / 40 (direct) / 60 (wholesale via ATM, also counts) - all 4 are
        -- real customers, "10/40/60 = wholesale only" is a REPORT SCOPE
        -- decision (which channels go into the wholesale payment-behavior
        -- analysis), not an "is this a real customer" decision. Both
        -- questions got mixed up when the original change was made - a
        -- retail customer (channel 20) IS a real customer, it just doesn't
        -- apply to that particular report. The "wholesale only" filter
        -- lives exclusively in the report, never here.
        -- Channel '50' investigated 2026-08-17: confirmed it's NOT a real
        -- customer channel - the largest account there (90000002, $171.5M)
        -- belongs to the company's OWNER (Jorge Armando Huguenin Bolaños).
        -- No channel-50 account has a ruta_nombre. Likely a related/
        -- shareholder account, correctly falls into FUERA_DE_ALCANCE under
        -- the rule below (it's not in 10/20/40/60).
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
-- 4. DIMENSION: gold.dim_cliente_comercial (SCD Type 2)
-- Grain: cliente_id (one representative per customer, chosen among their
-- channels via gold.vw_cliente_canal_estatus with priority ACTIVO > LEGAL >
-- REVISAR > INACTIVO > FUERA_DE_ALCANCE, final tiebreak by lowest
-- canal_distribucion - see gold.load_dim_cliente_comercial in
-- sp_load_gold.sql).
-- organizacion_ventas/canal_distribucion/sector are kept as columns (even
-- though the PK is only cliente_id) so gold.dim_cliente_credito can reuse
-- "which channel was chosen" when looking up analista_credito/cobrador.
-- SCD2: id_surrogate is the technical key the facts use. A unique filtered
-- index guarantees a single active version (es_vigente=1) per customer.
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
-- 5. DIMENSION: gold.dim_cliente_credito (SCD Type 2)
-- Grain: cliente_id. Attributes from silver.sap_knkk (already ~1:1 per
-- customer thanks to the KKBER='2000' filter in silver) + analista_credito
-- (role E1) and cobrador (role CC) from silver.sap_knvp, resolved on the
-- channel gold.dim_cliente_comercial ALREADY chose as the customer's
-- representative (which channel isn't re-decided here - that decision is
-- reused via a join to dim_cliente_comercial, a single source of truth).
-- SCD2: same mechanics as dim_cliente_comercial (id_surrogate, hash-diff,
-- versioning), already validated in production.
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
    etiqueta_credito         VARCHAR(11),   -- raw KRAUS (includes FILIAL/LEGAL/BAJA*/CREDITOC/etc.)
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
-- "Periodic snapshot fact": every run of gold.load_fact_saldo_cartera adds
-- a new snapshot (fecha_snapshot = today) of each customer's open balance,
-- WITHOUT deleting previous snapshots - this is how the history that
-- silver.sap_bsid can't provide gets accumulated (bronze/silver.sap_bsid
-- are fully reloaded every day, with no MERGE or backfill, unlike bsad -
-- there was never a way to reconstruct a past date's balance). IMPORTANT
-- CONSEQUENCE: this fact CANNOT be backfilled historically - it only
-- starts accumulating from the first real day its load runs.
--
-- GRAIN: cliente_id + fecha_snapshot (decided 2026-08-11 over line grain -
-- see dwh-ciosa-project-status.md in memory for the full comparison).
-- Collapses 'sociedad' the same way dim_cliente_comercial/dim_cliente_credito
-- do (there's no dim_sociedad in this model). With ~91,593 line items /
-- ~4,568 customers with a balance today, line grain would have kept growing
-- ~33M rows/year indefinitely on a server with the already-known 2GB log
-- limit; customer grain grows ~1.67M rows/year, manageable.
--
-- AGGREGATED MEASURES (from silver.sap_bsid, per customer, as of the
-- snapshot date, amount signed by debe_haber and excluding
-- clase_documento='SA' - see the full note in the CREATE TABLE below):
--   saldo_total/saldo_no_vencido/saldo_1_16 (grace period)/saldo_vencido
--   (REAL, 17+ days), num_documentos_abiertos, dias_vencido_max, aging
--   buckets (17-31/32-180/181+, only over real saldo_vencido),
--   documentos_con_reclamacion/nivel_reclamacion_max (MANST, worst level
--   among its open documents).
--
-- DPP (average days to pay) and weighted DPP: NOT computed from bsid (open
-- items - we don't know how long they'll take to be paid) but from ALREADY
-- settled documents, as historical payment-behavior context laid over the
-- current balance snapshot. Two rolling windows (3 and 12 months back from
-- fecha_snapshot), each simple and amount-weighted (larger invoices carry
-- more weight in the average).
-- 2026-08-19: DPP and % on-time/late are computed from
-- gold.fact_pagos_compensados/gold.fact_facturas_compensadas (see
-- gold.load_fact_saldo_cartera Step 2) - migrated from
-- gold.fact_aplicacion_pagos, whose 3-tier matching logic (REBZG/
-- GRUPO_INAMBIGUO/no-match) turned out to have real over-attribution bugs
-- (a match candidate could "explain" invoices worth far more than it
-- actually covers - confirmed with real cases, e.g. a $137 document
-- attributed to $2.5M in invoices within a massive compensation group).
-- fact_pagos_compensados/fact_facturas_compensadas use a deliberately
-- simpler design: they only relate compensation groups with EXACTLY 1
-- candidate raw payment, with no match tiers or partial-application
-- splitting. It only covers real payments (not credit notes/returns/
-- adjustments/reversals, out of scope for this design) - that's why these
-- percentages deliberately will NOT add up to 100% of a customer's total
-- balance, they specifically cover the portion with an unambiguously
-- identified payment.
-- ==========================================================
IF OBJECT_ID('gold.fact_saldo_cartera', 'U') IS NOT NULL
    DROP TABLE gold.fact_saldo_cartera;
GO

CREATE TABLE gold.fact_saldo_cartera (
    cliente_id                  VARCHAR(10) NOT NULL,
    fecha_snapshot               DATE        NOT NULL,

    -- balance and aging - REDESIGNED 2026-08-18 after reconciling against
    -- an external portfolio report and finding 3 real discrepancies:
    --   1. silver.sap_bsid's monto_moneda_local NEVER carries a sign (same
    --      as bsad) - debe_haber='H' (payments/credit notes/returns/
    --      adjustments sitting as an unapplied open item) was being added
    --      as debt instead of subtracted. It's now signed before
    --      aggregating (see gold.load_fact_saldo_cartera Step 1).
    --   2. clase_documento='SA' (GL journal entries) is excluded entirely -
    --      these aren't real customer documents.
    --   3. Real business rule: invoices overdue by 1-16 days are treated as
    --      "healthy balance" (grace period), NOT as truly overdue -
    --      confirmed by the user and validated with data (real overdue
    --      with just this adjustment came out to $15.79M against the
    --      external report's $15.38M, ~2.6% difference, within what's
    --      expected from timing between snapshots).
    -- Aging buckets were also redesigned with the same cutoffs as the
    -- external report (17-31/32-180/181+) to be directly comparable.
    saldo_total                  DECIMAL(18,2) NOT NULL,
    saldo_no_vencido              DECIMAL(18,2) NOT NULL,  -- fecha_vencimiento NULL or >= today (within terms)
    saldo_1_16                   DECIMAL(18,2) NOT NULL,  -- grace period: 1-16 days overdue, treated as healthy by the business
    saldo_vencido                DECIMAL(18,2) NOT NULL,  -- REAL OVERDUE: 17+ days (saldo_17_31+saldo_32_180+saldo_181_mas)
    num_documentos_abiertos      INT NOT NULL,
    dias_vencido_max             INT NULL,  -- max days overdue across ALL overdue documents (includes the grace period, it's the worst case regardless of the "real overdue" cutoff)

    -- aging buckets (only over REAL saldo_vencido, 17+ days)
    saldo_17_31                  DECIMAL(18,2) NOT NULL,
    saldo_32_180                 DECIMAL(18,2) NOT NULL,
    saldo_181_mas                DECIMAL(18,2) NOT NULL,

    -- dunning / collections (aggregated from line level)
    documentos_con_reclamacion   INT NOT NULL,
    nivel_reclamacion_max        CHAR(1) NULL,

    -- historical payment behavior (from gold.fact_pagos_compensados/
    -- gold.fact_facturas_compensadas via gold.load_fact_saldo_cartera Step
    -- 2 - see the note above the CREATE TABLE. History: this migrated
    -- 2026-08-19 from gold.fact_aplicacion_pagos due to the
    -- over-attribution bugs already documented above).
    dpp_3m                       DECIMAL(9,2) NULL,
    dpp_ponderado_3m             DECIMAL(9,2) NULL,
    dpp_12m                      DECIMAL(9,2) NULL,
    dpp_ponderado_12m            DECIMAL(9,2) NULL,
    pct_pagos_a_tiempo_3m        DECIMAL(5,2) NULL,  -- % of the amount paid (PAGO) in the last 3m with dias_anticipacion_vencimiento <= 0
    pct_pagos_tarde_3m           DECIMAL(5,2) NULL,
    pct_pagos_a_tiempo_12m       DECIMAL(5,2) NULL,
    pct_pagos_tarde_12m          DECIMAL(5,2) NULL,

    -- SCD2 surrogate keys, resolved via a temporal join to fecha_snapshot
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
-- gold.fact_aplicacion_pagos (bridge table invoice<->applied document, with
-- 3-tier REBZG/GRUPO_INAMBIGUO/no-match matching) was REMOVED 2026-08-19:
-- the matching logic turned out to have real over-attribution bugs (an
-- "unambiguous" candidate could explain invoices worth far more than it
-- actually covers - e.g. a $137 Z1 document attributed to $2.5M across
-- 4,724 invoices within a massive compensation group; confirmed in several
-- real cases before deciding to retire it).
-- Replaced by the simple gold.fact_pagos_compensados/gold.fact_facturas_compensadas +
-- gold.vw_pago_factura_simple design (only relates groups with EXACTLY 1
-- candidate payment, with no match tiers or partial application). The DPP
-- block of gold.fact_saldo_cartera that depended on this table was already
-- migrated before it was removed (see gold.load_fact_saldo_cartera Step 2).
-- ==========================================================
-- 6. FACT: gold.fact_pagos_compensados
-- Grain: 1 row = 1 "raw" deposit (silver.sap_bsad, clase_documento='DZ'
-- AND sgtxt='Asignación Aut. Deposito' AND debe_haber<>'S' AND
-- monto_moneda_local>0) - a customer payment not yet allocated to invoices.
-- Filtered mirror, with no matching logic (unlike fact_aplicacion_pagos) -
-- the payment<->invoice relationship lives in gold.vw_pago_factura_simple
-- (a query, not a table), which only relates compensation groups with
-- EXACTLY 1 candidate payment.
-- debe_haber<>'S' FILTER added 2026-08-19 after analyzing July's
-- GRUPO_AMBIGUO_2+PAGOS cases: 4 of 5 sample groups turned out to be a
-- single real payment duplicated, not genuine ambiguity - a compensation's
-- "child" document always carries its own mirror/offsetting line (same
-- documento_id=documento_compensacion, debe_haber='S', same amount and same
-- sgtxt='Asignación Aut. Deposito' as the real deposit), which without this
-- filter was counted as a second candidate raw payment. Measured: applying
-- this filter reduced July's GRUPO_AMBIGUO_2+PAGOS from 92 payments/$1.52M
-- to 29 payments/$249K (-84% in amount), with almost no impact on
-- MATCHEADO_OK (most of the "disambiguated" payments had no invoice
-- anyway, they fell into SIN_FACTURA_EN_GRUPO). Same filter already
-- validated earlier in the gold.fact_aplicacion_pagos design (now retired)
-- for the same purpose.
-- monto_moneda_local>0 FILTER added 2026-08-19 (same session), after
-- analyzing the 29 payments that remained ambiguous: 6 of 14 sample groups
-- turned out to be the child's own "H" line but with a $0.00 amount
-- (technical residual, not real money) inflating the candidate count
-- alongside the real deposit. The other 8 groups in that sample (the
-- child's own "H" line WITH a real amount competing with an external raw
-- payment for the same money, or cleanup batches with multiple real
-- deposits/invoices from several months) are left as an accepted residual
-- on purpose - resolving them would require the "own vs. external" logic
-- that already caused several rounds of bugs in the fact_aplicacion_pagos
-- design, not worth it for a ~0.17% residual of the universe.
-- Load: gold.load_fact_pagos_compensados (sp_load_gold.sql) - incremental,
-- current + previous month by fecha_compensacion, the same pattern
-- silver.load_silver uses for bsad. Historical backfill:
-- 03_gold/backfill_fact_pagos_facturas_compensados.sql.
-- ==========================================================
IF OBJECT_ID('gold.fact_pagos_compensados', 'U') IS NOT NULL
    DROP TABLE gold.fact_pagos_compensados;
GO

CREATE TABLE gold.fact_pagos_compensados (
    sociedad                VARCHAR(4)    NOT NULL,
    cliente_id               VARCHAR(10)   NOT NULL,
    ejercicio                 INT           NOT NULL,
    documento_id               VARCHAR(10)   NOT NULL,
    posicion                   INT           NOT NULL,
    fecha_documento             DATE, -- real deposit date ("payment date")
    fecha_compensacion          DATE,
    monto_moneda_local          DECIMAL(15,2),
    documento_compensacion      VARCHAR(10), -- compensation group shared with the invoices it covers
    ejercicio_compensacion      INT,
    fecha_carga                 DATETIME DEFAULT GETDATE(),
    CONSTRAINT PK_fact_pagos_compensados PRIMARY KEY CLUSTERED (sociedad, cliente_id, ejercicio, documento_id, posicion)
);
GO

-- Index on the compensation group: gold.vw_pago_factura_simple (and any
-- ad-hoc analysis) groups/joins on this pair of columns constantly -
-- without this index it's a full table scan every time (confirmed
-- 2026-08-19, the reconciliation query was taking a long time).
CREATE INDEX IX_fact_pagos_compensados_grupo ON gold.fact_pagos_compensados (documento_compensacion, ejercicio_compensacion);
GO

PRINT 'Table gold.fact_pagos_compensados created successfully.';
GO

-- ==========================================================
-- 7. FACT: gold.fact_facturas_compensadas
-- Grain: 1 row = 1 already-cleared invoice (silver.sap_bsad,
-- clase_documento IN F1-F6). Same filtered mirror as fact_pagos_compensados,
-- with no matching logic.
-- Load: gold.load_fact_facturas_compensadas (sp_load_gold.sql) -
-- incremental, same pattern. Historical backfill:
-- 03_gold/backfill_fact_pagos_facturas_compensados.sql (run 2026-08-19,
-- complete history since 2022-01-01).
-- ==========================================================
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

-- Same reason as gold.fact_pagos_compensados: gold.vw_pago_factura_simple
-- constantly joins on this pair of columns.
CREATE INDEX IX_fact_facturas_compensadas_grupo ON gold.fact_facturas_compensadas (documento_compensacion, ejercicio_compensacion);
GO

PRINT 'Table gold.fact_facturas_compensadas created successfully.';
GO
