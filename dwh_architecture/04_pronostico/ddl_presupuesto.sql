/* ============================================================================
   Collections budget tables
   Objects : gold.fact_presupuesto_cobranza, gold.fact_presupuesto_cartera
   Purpose : fact_presupuesto_cobranza, one row per day of the budgeted month:
             what is expected each day. fact_presupuesto_cartera, one row per
             aging segment: where the promised money is and which rate was used.
   Run     : once. Creates the tables only if missing; never drops them.
   Notes   : Loaded by gold.load_presupuesto_cobranza. Model in
             modelo_presupuesto.sql; design rationale in DESIGN.md.
   ============================================================================ */
USE ANALISIS_DATOS;
GO

-- ----------------------------------------------------------------------------
-- gold.fact_presupuesto_cobranza: daily
-- No actual amount here on purpose: the forecast is frozen, actuals live in
-- gold.vw_cobranza_diaria and refresh on every query.
-- ----------------------------------------------------------------------------
IF OBJECT_ID('gold.fact_presupuesto_cobranza') IS NULL
CREATE TABLE gold.fact_presupuesto_cobranza (
    mes_presupuesto     DATE         NOT NULL,   -- first day of the budgeted month
    fecha               DATE         NOT NULL,
    fecha_corte         DATE         NOT NULL,   -- when the number was calculated (4th business day)
    es_dia_habil        BIT          NOT NULL,
    slot_calendario     VARCHAR(3)   NULL,       -- I01..I03 / M.. / F08..F01; NULL on non-business days
    origen              VARCHAR(10)  NOT NULL,   -- OBSERVADO before the cut-off, PRONOSTICO from it
    monto_presupuesto   DECIMAL(19,2) NOT NULL,
    fecha_carga         DATETIME     DEFAULT GETDATE(),
    CONSTRAINT PK_fact_presupuesto_cobranza PRIMARY KEY CLUSTERED (mes_presupuesto, fecha)
);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'IX_fpc_fecha' AND object_id = OBJECT_ID('gold.fact_presupuesto_cobranza'))
CREATE INDEX IX_fpc_fecha ON gold.fact_presupuesto_cobranza (fecha);
GO

-- ----------------------------------------------------------------------------
-- gold.fact_presupuesto_cartera: month x bucket x ejecutivo x region x canal x
-- estatus (~2,000 rows a month). Not by customer: the rate is a population rate.
-- Attributes are stored as resolved at the cut-off, not as SCD2 keys, so a later
-- reassignment does not move a past budget.
-- ----------------------------------------------------------------------------
IF OBJECT_ID('gold.fact_presupuesto_cartera') IS NULL
CREATE TABLE gold.fact_presupuesto_cartera (
    mes_presupuesto     DATE          NOT NULL,
    fecha_corte         DATE          NOT NULL,
    bucket_key          VARCHAR(2)    NOT NULL,  -- gold.dim_bucket
    ejecutivo_key       VARCHAR(60)   NOT NULL,  -- gold.dim_ejecutivo
    region_key          VARCHAR(10)   NOT NULL,  -- gold.dim_region
    canal_key           VARCHAR(4)    NOT NULL,  -- gold.dim_canal
    estatus_comercial   VARCHAR(20)   NOT NULL,  -- kept to verify the scope rule was applied
    monto_cartera       DECIMAL(19,2) NOT NULL,  -- open at the cut-off
    tasa_recuperacion   DECIMAL(9,6)  NOT NULL,  -- the rate used, not today's
    tasa_origen         VARCHAR(10)   NOT NULL,  -- SEGMENTO own rate / BUCKET fallback rate
    monto_esperado      DECIMAL(19,2) NOT NULL,  -- cartera x tasa
    monto_real          DECIMAL(19,2) NULL,      -- filled when the month closes
    fecha_carga         DATETIME      DEFAULT GETDATE(),
    CONSTRAINT PK_fact_presupuesto_cartera PRIMARY KEY CLUSTERED
        (mes_presupuesto, bucket_key, ejecutivo_key, region_key, canal_key, estatus_comercial)
);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'IX_fpcart_ejecutivo' AND object_id = OBJECT_ID('gold.fact_presupuesto_cartera'))
CREATE INDEX IX_fpcart_ejecutivo ON gold.fact_presupuesto_cartera (ejecutivo_key, mes_presupuesto);
GO
