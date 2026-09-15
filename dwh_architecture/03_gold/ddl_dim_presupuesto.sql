/* ============================================================================
   Budget dimensions
   Objects : gold.dim_bucket, gold.dim_ejecutivo, gold.dim_region, gold.dim_canal
             gold.load_dim_presupuesto
   Purpose : Small conformed dimensions of the collections budget report.
   Run     : tables once. EXEC gold.load_dim_presupuesto; after gold.load_gold.
   Notes   : Not in ddl_gold.sql on purpose: that file drops its tables, and
             dim_ejecutivo, dim_region and dim_canal keep classification typed by
             hand. The procedure only inserts new values, never updates.
             The collation is binary ('PEREZ' <> 'Perez', a trailing space breaks
             a join): the ejecutivo key is always UPPER(LTRIM(RTRIM(name))), here
             and in the fact.
   ============================================================================ */
USE ANALISIS_DATOS;
GO

-- ----------------------------------------------------------------------------
-- gold.dim_bucket: static aging buckets
-- ----------------------------------------------------------------------------
IF OBJECT_ID('gold.dim_bucket') IS NULL
CREATE TABLE gold.dim_bucket (
    bucket_key      VARCHAR(2)   NOT NULL,
    bucket_nombre   VARCHAR(40)  NOT NULL,
    bucket_corto    VARCHAR(16)  NOT NULL,   -- chart axis label
    bucket_grupo    VARCHAR(12)  NOT NULL,   -- Por vencer / Vencida
    bucket_orden    TINYINT      NOT NULL,   -- without it the BI sorts alphabetically
    dias_desde      INT          NULL,
    dias_hasta      INT          NULL,
    es_recuperable  BIT          NOT NULL,   -- 0 = historically recovers almost nothing (G)
    CONSTRAINT PK_dim_bucket PRIMARY KEY CLUSTERED (bucket_key)
);
GO

IF NOT EXISTS (SELECT 1 FROM gold.dim_bucket)
INSERT INTO gold.dim_bucket
    (bucket_key, bucket_nombre, bucket_corto, bucket_grupo, bucket_orden, dias_desde, dias_hasta, es_recuperable)
VALUES
    ('A2','Vence en meses posteriores','Vence despues','Por vencer',1, NULL, NULL, 1),
    ('A1','Vence este mes',            'Vence este mes','Por vencer',2, NULL, NULL, 1),
    ('B' ,'Vencida 1 a 30 dias',       '1-30 d',        'Vencida',   3,    1,   30, 1),
    ('C' ,'Vencida 31 a 60 dias',      '31-60 d',       'Vencida',   4,   31,   60, 1),
    ('D' ,'Vencida 61 a 90 dias',      '61-90 d',       'Vencida',   5,   61,   90, 1),
    ('E' ,'Vencida 91 a 180 dias',     '91-180 d',      'Vencida',   6,   91,  180, 1),
    ('F' ,'Vencida 181 a 365 dias',    '181-365 d',     'Vencida',   7,  181,  365, 1),
    ('G' ,'Vencida mas de 365 dias',   '+365 d',        'Vencida',   8,  366, NULL, 0);
GO

-- ----------------------------------------------------------------------------
-- gold.dim_ejecutivo: credit analysts and process pools
-- tipo_gestion separates people from process pools. es_cobrable decides what
-- enters the team target (JURIDICO in, EXTRAJUDICIAL out); changing it is an
-- UPDATE and the budget follows without recalculating.
-- ----------------------------------------------------------------------------
IF OBJECT_ID('gold.dim_ejecutivo') IS NULL
CREATE TABLE gold.dim_ejecutivo (
    ejecutivo_key     VARCHAR(60)  NOT NULL,  -- UPPER(LTRIM(RTRIM(nombre)))
    ejecutivo_nombre  VARCHAR(60)  NOT NULL,
    analista_id       VARCHAR(10)  NULL,
    tipo_gestion      VARCHAR(16)  NOT NULL,  -- GESTIONABLE / SIN_ASIGNAR / EXTRAJUDICIAL / JURIDICO / INACTIVO
    es_cobrable       BIT          NOT NULL,  -- enters the team target
    es_persona        BIT          NOT NULL,  -- 0 = process pool, not someone to measure
    revisado          BIT          NOT NULL DEFAULT 0,   -- 1 = a person confirmed the classification
    fecha_alta        DATETIME     DEFAULT GETDATE(),
    CONSTRAINT PK_dim_ejecutivo PRIMARY KEY CLUSTERED (ejecutivo_key)
);
GO

-- ----------------------------------------------------------------------------
-- gold.dim_region: region_nombre starts as the SAP code and is typed by hand.
-- es_comercial = 0 for administrative codes that are not a sales region.
-- ----------------------------------------------------------------------------
IF OBJECT_ID('gold.dim_region') IS NULL
CREATE TABLE gold.dim_region (
    region_key      VARCHAR(10)  NOT NULL,
    region_nombre   VARCHAR(60)  NOT NULL,
    es_comercial    BIT          NOT NULL,
    fecha_alta      DATETIME     DEFAULT GETDATE(),
    CONSTRAINT PK_dim_region PRIMARY KEY CLUSTERED (region_key)
);
GO

-- ----------------------------------------------------------------------------
-- gold.dim_canal
-- ----------------------------------------------------------------------------
IF OBJECT_ID('gold.dim_canal') IS NULL
CREATE TABLE gold.dim_canal (
    canal_key       VARCHAR(4)   NOT NULL,
    canal_nombre    VARCHAR(40)  NOT NULL,
    fecha_alta      DATETIME     DEFAULT GETDATE(),
    CONSTRAINT PK_dim_canal PRIMARY KEY CLUSTERED (canal_key)
);
GO

-- ----------------------------------------------------------------------------
-- gold.load_dim_presupuesto: inserts new values only
-- ----------------------------------------------------------------------------
IF OBJECT_ID('gold.load_dim_presupuesto') IS NOT NULL
    DROP PROCEDURE gold.load_dim_presupuesto;
GO

CREATE PROCEDURE gold.load_dim_presupuesto
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @proc VARCHAR(128) = 'gold.load_dim_presupuesto',
            @step VARCHAR(128) = 'start',
            @t0   DATETIME2(0) = SYSDATETIME(),
            @t    DATETIME2(0) = SYSDATETIME(),
            @err  VARCHAR(4000),
            @line INT;
    DECLARE @e INT, @r INT, @c INT, @pend INT;

    BEGIN TRY
        BEGIN TRANSACTION;

        -- Process pools follow naming conventions, so they are recognized by pattern.
        -- A name that matches no pattern is a person: GESTIONABLE and cobrable, with
        -- revisado = 0 until someone confirms it.
        SET @step = 'gold.dim_ejecutivo insert new'; SET @t = SYSDATETIME();
        INSERT INTO gold.dim_ejecutivo
            (ejecutivo_key, ejecutivo_nombre, analista_id, tipo_gestion, es_cobrable, es_persona, revisado)
        SELECT s.k, s.k, MAX(s.id),
               CASE
                 WHEN s.k = '(SIN ASIGNAR)' OR s.k LIKE 'VACANTE%'        THEN 'SIN_ASIGNAR'
                 WHEN s.k LIKE '%EXTRAJUDICIAL%'
                   OR s.k = 'COBRADOR RUTA DOS CIENTOS'                   THEN 'EXTRAJUDICIAL'
                 WHEN s.k LIKE '%JURIDICO%'                               THEN 'JURIDICO'
                 WHEN s.k LIKE 'INACTIVOS%'                               THEN 'INACTIVO'
                 ELSE 'GESTIONABLE'
               END,
               CASE
                 WHEN s.k = '(SIN ASIGNAR)' OR s.k LIKE 'VACANTE%'        THEN 0
                 WHEN s.k LIKE '%EXTRAJUDICIAL%'
                   OR s.k = 'COBRADOR RUTA DOS CIENTOS'                   THEN 0
                 WHEN s.k LIKE 'INACTIVOS%'                               THEN 0
                 ELSE 1
               END,
               CASE
                 WHEN s.k = '(SIN ASIGNAR)' OR s.k LIKE 'VACANTE%'        THEN 0
                 WHEN s.k LIKE '%EXTRAJUDICIAL%'
                   OR s.k = 'COBRADOR RUTA DOS CIENTOS'                   THEN 0
                 WHEN s.k LIKE '%JURIDICO%'                               THEN 0
                 WHEN s.k LIKE 'INACTIVOS%'                               THEN 0
                 WHEN s.k LIKE 'CAJERA%'      OR s.k LIKE '%CALL CENTER%'
                   OR s.k LIKE 'BTOB%'        OR s.k LIKE 'VERIFICACION%' THEN 0
                 ELSE 1
               END,
               0
        FROM (SELECT UPPER(ISNULL(NULLIF(LTRIM(RTRIM(analista_credito_nombre)),''),'(SIN ASIGNAR)')) AS k,
                     analista_credito_id AS id
              FROM   gold.dim_cliente_credito) s
        WHERE NOT EXISTS (SELECT 1 FROM gold.dim_ejecutivo d WHERE d.ejecutivo_key = s.k)
        GROUP BY s.k;
        SET @e = @@ROWCOUNT;
        EXEC control.log_step @proc, @step, @t, @e;

        SET @step = 'gold.dim_region insert new'; SET @t = SYSDATETIME();
        INSERT INTO gold.dim_region (region_key, region_nombre, es_comercial)
        SELECT s.k, s.k, 1
        FROM  (SELECT DISTINCT UPPER(LTRIM(RTRIM(region))) AS k
               FROM gold.dim_cliente_comercial WHERE region IS NOT NULL AND LTRIM(RTRIM(region)) <> '') s
        WHERE NOT EXISTS (SELECT 1 FROM gold.dim_region d WHERE d.region_key = s.k);
        SET @r = @@ROWCOUNT;
        EXEC control.log_step @proc, @step, @t, @r;

        SET @step = 'gold.dim_canal insert new'; SET @t = SYSDATETIME();
        INSERT INTO gold.dim_canal (canal_key, canal_nombre)
        SELECT s.k, s.k
        FROM  (SELECT DISTINCT LTRIM(RTRIM(canal_distribucion)) AS k
               FROM gold.dim_cliente_comercial
               WHERE canal_distribucion IN (10, 40, 60)) s
        WHERE NOT EXISTS (SELECT 1 FROM gold.dim_canal d WHERE d.canal_key = s.k);
        SET @c = @@ROWCOUNT;
        EXEC control.log_step @proc, @step, @t, @c;

        COMMIT TRANSACTION;

        SET @step = 'check: ejecutivos not reviewed'; SET @t = SYSDATETIME();
        SET @pend = (SELECT COUNT(*) FROM gold.dim_ejecutivo WHERE revisado = 0);
        EXEC control.log_step @proc, @step, @t, @pend;

        EXEC control.log_step @proc, 'total', @t0;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        SELECT @err = ERROR_MESSAGE(), @line = ERROR_LINE();
        EXEC control.log_step @proc, @step, @t, NULL, @err, @line;
        THROW;
    END CATCH
END;
GO
