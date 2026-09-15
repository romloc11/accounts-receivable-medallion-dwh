/* ============================================================================
   BI layer
   Objects : schema bi; views dim_fecha, dim_cliente, dim_canal, dim_region,
             dim_ejecutivo, dim_bucket, fact_cobranza, fact_facturas,
             fact_aplicacion, fact_presupuesto_segmento, fact_presupuesto_dia
   Purpose : One view per Power BI table, already in star-schema shape. Every
             fact carries conformed keys (canal, region, ejecutivo) resolved in
             SQL, so the Power BI model has no SCD2 tables and no transformations.
   Run     : any time; views only, no data is stored.
   Notes   : Facts cover the last 36 closed-or-current months (open items are
             always included); the full history stays in gold.
             Customer attributes come from the SCD2 version already stored on
             each fact row. Unknown members: 'SIN CANAL', 'SIN REGION',
             '(SIN ASIGNAR)', 'SIN DATO'.
             Use COALESCE, never ISNULL, for the defaults: ISNULL takes the length
             of its first argument and truncates the literal.
   ============================================================================ */
USE ANALISIS_DATOS;
GO

IF SCHEMA_ID('bi') IS NULL EXEC('CREATE SCHEMA bi');
GO

-- ----------------------------------------------------------------------------
-- Dimensions
-- ----------------------------------------------------------------------------
IF OBJECT_ID('bi.dim_fecha', 'V') IS NOT NULL DROP VIEW bi.dim_fecha;
GO
CREATE VIEW bi.dim_fecha
AS
SELECT
    fecha,
    anio,
    mes,
    nombre_mes,
    trimestre,
    dia,
    dia_semana,
    nombre_dia_semana,
    es_fin_de_semana,
    semana_anio,
    anio_mes_num,
    anio_mes_texto,
    DATEFROMPARTS(anio, mes, 1)                                       AS mes_inicio,
    DATEADD(DAY, -(DATEDIFF(DAY, '19000101', fecha) % 7), fecha)      AS semana_inicio,   -- Monday
    DATEDIFF(MONTH, fecha, GETDATE())                                 AS mes_relativo,    -- 0 current, 1 previous
    -- Slicer value that never goes stale: a report can default to 'Mes actual'.
    CASE WHEN DATEDIFF(MONTH, fecha, GETDATE()) = 0 THEN 'Mes actual' ELSE anio_mes_texto END AS periodo,
    CASE WHEN EXISTS (SELECT 1 FROM gold.fact_presupuesto_cobranza p
                      WHERE p.mes_presupuesto = DATEFROMPARTS(anio, mes, 1)) THEN 1 ELSE 0 END AS tiene_presupuesto,
    es_festivo,
    nombre_festivo,
    es_dia_habil,
    dia_habil_del_mes,
    dias_habiles_mes,
    siguiente_dia_habil
FROM gold.dim_fecha;
GO

IF OBJECT_ID('bi.dim_cliente', 'V') IS NOT NULL DROP VIEW bi.dim_cliente;
GO
CREATE VIEW bi.dim_cliente
AS
SELECT
    cliente_id,
    nombre,
    tipo_cliente,
    -- Report categories. TRANSITORIA must stay explicit or it falls into Mayoreo.
    CASE tipo_cliente
        WHEN 'MARKETPLACE' THEN 'Marketplace'
        WHEN 'TRANSITORIA' THEN 'Transitoria'
        WHEN 'GENERICO'    THEN 'Contado'
        ELSE 'Mayoreo'
    END AS tipo_cliente_reporte
FROM gold.dim_cliente;
GO

-- Every channel that exists on a customer version, so no fact key is orphaned;
-- names come from gold.dim_canal, where they are typed by hand.
IF OBJECT_ID('bi.dim_canal', 'V') IS NOT NULL DROP VIEW bi.dim_canal;
GO
CREATE VIEW bi.dim_canal
AS
SELECT
    k.canal_key,
    COALESCE(c.canal_nombre, k.canal_key)                          AS canal_nombre,
    CASE WHEN k.canal_key IN ('10', '40', '60') THEN 1 ELSE 0 END  AS es_alcance
FROM (
    SELECT DISTINCT LTRIM(RTRIM(canal_distribucion)) AS canal_key
    FROM gold.dim_cliente_comercial
    WHERE canal_distribucion IS NOT NULL
    UNION
    SELECT 'SIN CANAL'
) k
LEFT JOIN gold.dim_canal c ON c.canal_key = k.canal_key;
GO

IF OBJECT_ID('bi.dim_region', 'V') IS NOT NULL DROP VIEW bi.dim_region;
GO
CREATE VIEW bi.dim_region
AS
SELECT
    k.region_key,
    COALESCE(r.region_nombre, k.region_key)  AS region_nombre,
    COALESCE(r.es_comercial, 1)              AS es_comercial
FROM (
    SELECT DISTINCT COALESCE(UPPER(NULLIF(LTRIM(RTRIM(region)), '')), 'SIN REGION') AS region_key
    FROM gold.dim_cliente_comercial
    UNION
    SELECT 'SIN REGION'
) k
LEFT JOIN gold.dim_region r ON r.region_key = k.region_key;
GO

IF OBJECT_ID('bi.dim_ejecutivo', 'V') IS NOT NULL DROP VIEW bi.dim_ejecutivo;
GO
CREATE VIEW bi.dim_ejecutivo
AS
SELECT ejecutivo_key, ejecutivo_nombre, tipo_gestion, es_cobrable, es_persona, revisado
FROM gold.dim_ejecutivo;
GO

IF OBJECT_ID('bi.dim_bucket', 'V') IS NOT NULL DROP VIEW bi.dim_bucket;
GO
CREATE VIEW bi.dim_bucket
AS
SELECT bucket_key, bucket_nombre, bucket_corto, bucket_grupo, bucket_orden, dias_desde, dias_hasta, es_recuperable
FROM gold.dim_bucket;
GO

-- ----------------------------------------------------------------------------
-- bi.fact_cobranza: one payment line. Official date: fecha_documento.
-- Every payment is either in the bridge (APLICADO) or has a motivo.
-- ----------------------------------------------------------------------------
IF OBJECT_ID('bi.fact_cobranza', 'V') IS NOT NULL DROP VIEW bi.fact_cobranza;
GO
CREATE VIEW bi.fact_cobranza
AS
SELECT
    p.pago_key,
    p.cliente_id,
    p.fecha_documento,
    p.fecha_contabilizacion,
    p.fecha_compensacion,
    COALESCE(LTRIM(RTRIM(dcc.canal_distribucion)), 'SIN CANAL')                  AS canal_key,
    COALESCE(UPPER(NULLIF(LTRIM(RTRIM(dcc.region)), '')), 'SIN REGION')          AS region_key,
    COALESCE(UPPER(NULLIF(LTRIM(RTRIM(dk.analista_credito_nombre)), '')), '(SIN ASIGNAR)') AS ejecutivo_key,
    COALESCE(dcc.estatus_comercial, 'SIN DATO')                                  AS estatus_comercial,
    p.documento_id                                                               AS documento_pago,
    p.posicion,
    p.documento_compensacion,
    p.clave_contabilizacion,
    p.texto,
    p.cuenta_mayor,
    -- Same account ranges bronze loads: 113* bank accounts, 111* payment-gateway clearing accounts.
    CASE WHEN p.cuenta_mayor LIKE '0000113%' THEN 'Banco'
         WHEN p.cuenta_mayor LIKE '0000111%' THEN 'Pasarela de pago'
         WHEN p.cuenta_mayor IS NULL         THEN 'Sin cuenta de efectivo'
         ELSE 'Otra cuenta' END                                                  AS tipo_cuenta,
    CASE WHEN s.motivo IS NULL THEN 'APLICADO' ELSE 'SIN APLICACION' END         AS estatus_aplicacion,
    COALESCE(s.motivo, 'APLICADO')                                               AS motivo_aplicacion,
    CASE WHEN p.fecha_compensacion IS NULL THEN 1 ELSE 0 END                     AS es_abierto,
    p.monto
FROM gold.fact_pagos p
LEFT JOIN gold.fact_pagos_sin_aplicacion s
       ON  s.sociedad = p.sociedad AND s.cliente_id = p.cliente_id AND s.ejercicio = p.ejercicio
       AND s.documento_id = p.documento_id AND s.posicion = p.posicion
LEFT JOIN gold.dim_cliente_comercial dcc ON dcc.id_surrogate = p.cliente_comercial_sk
LEFT JOIN gold.dim_cliente_credito   dk  ON dk.id_surrogate  = p.cliente_credito_sk
WHERE p.fecha_documento >= DATEADD(MONTH, DATEDIFF(MONTH, 0, GETDATE()) - 36, 0)
   OR p.fecha_compensacion IS NULL;
GO

-- ----------------------------------------------------------------------------
-- bi.fact_facturas: one invoice line, cleared and open. Official date:
-- fecha_pago_efectiva (NULL for open invoices).
-- rebanada: the monthly collections breakdown (desglose_cobranza_mes.sql).
-- bucket_key: aging as of today, open invoices only (same rule as the budget).
-- ----------------------------------------------------------------------------
IF OBJECT_ID('bi.fact_facturas', 'V') IS NOT NULL DROP VIEW bi.fact_facturas;
GO
CREATE VIEW bi.fact_facturas
AS
SELECT
    f.factura_key,
    f.cliente_id,
    f.fecha_pago_efectiva,
    f.fecha_documento,
    f.fecha_vencimiento,
    f.fecha_compensacion,
    COALESCE(LTRIM(RTRIM(dcc.canal_distribucion)), 'SIN CANAL')                  AS canal_key,
    COALESCE(UPPER(NULLIF(LTRIM(RTRIM(dcc.region)), '')), 'SIN REGION')          AS region_key,
    COALESCE(UPPER(NULLIF(LTRIM(RTRIM(dk.analista_credito_nombre)), '')), '(SIN ASIGNAR)') AS ejecutivo_key,
    COALESCE(dcc.estatus_comercial, 'SIN DATO')                                  AS estatus_comercial,
    x.bucket_key,
    f.documento_id                                                               AS documento_factura,
    f.posicion,
    f.clase_documento,
    f.documento_compensacion,
    CASE WHEN f.flag_compensada = 1 THEN 'COBRADA' ELSE 'ABIERTA' END            AS estatus_factura,
    f.clasificacion_cobranza,
    CASE
        WHEN f.fecha_pago_efectiva IS NULL THEN NULL
        WHEN f.fecha_documento >= DATEFROMPARTS(YEAR(f.fecha_pago_efectiva), MONTH(f.fecha_pago_efectiva), 1) THEN 2
        WHEN f.clasificacion_cobranza = 'PAGO_A_MES'      THEN 1
        WHEN f.clasificacion_cobranza = 'PAGO_ANTICIPADO' THEN 3
        ELSE 4
    END                                                                          AS rebanada_orden,
    CASE
        WHEN f.fecha_pago_efectiva IS NULL THEN NULL
        WHEN f.fecha_documento >= DATEFROMPARTS(YEAR(f.fecha_pago_efectiva), MONTH(f.fecha_pago_efectiva), 1) THEN 'Facturado y cobrado en el mes'
        WHEN f.clasificacion_cobranza = 'PAGO_A_MES'      THEN 'Cartera del mes'
        WHEN f.clasificacion_cobranza = 'PAGO_ANTICIPADO' THEN 'Anticipado'
        ELSE 'Cartera vencida'
    END                                                                          AS rebanada,
    f.dias_pago,
    x.dias_vencido,
    f.monto
FROM gold.fact_facturas f
CROSS APPLY (
    SELECT
        CASE WHEN f.flag_compensada = 0 THEN DATEDIFF(DAY, f.fecha_vencimiento, CAST(GETDATE() AS DATE)) END AS dias_vencido,
        CASE
            WHEN f.flag_compensada = 1 OR f.fecha_vencimiento IS NULL THEN NULL
            WHEN f.fecha_vencimiento > CAST(GETDATE() AS DATE)
                 AND f.fecha_vencimiento <= EOMONTH(GETDATE())                                  THEN 'A1'
            WHEN f.fecha_vencimiento > CAST(GETDATE() AS DATE)                                  THEN 'A2'
            WHEN DATEDIFF(DAY, f.fecha_vencimiento, CAST(GETDATE() AS DATE)) <=  30             THEN 'B'
            WHEN DATEDIFF(DAY, f.fecha_vencimiento, CAST(GETDATE() AS DATE)) <=  60             THEN 'C'
            WHEN DATEDIFF(DAY, f.fecha_vencimiento, CAST(GETDATE() AS DATE)) <=  90             THEN 'D'
            WHEN DATEDIFF(DAY, f.fecha_vencimiento, CAST(GETDATE() AS DATE)) <= 180             THEN 'E'
            WHEN DATEDIFF(DAY, f.fecha_vencimiento, CAST(GETDATE() AS DATE)) <= 365             THEN 'F'
            ELSE 'G'
        END AS bucket_key
) x
LEFT JOIN gold.dim_cliente_comercial dcc ON dcc.id_surrogate = f.cliente_comercial_sk
LEFT JOIN gold.dim_cliente_credito   dk  ON dk.id_surrogate  = f.cliente_credito_sk
WHERE f.flag_compensada = 0
   OR f.fecha_compensacion >= DATEADD(MONTH, DATEDIFF(MONTH, 0, GETDATE()) - 36, 0);
GO

-- ----------------------------------------------------------------------------
-- bi.fact_aplicacion: payment x invoice. Related to fact_facturas only, so the
-- model keeps a single filter path; the payment side is reached with TREATAS.
-- ----------------------------------------------------------------------------
IF OBJECT_ID('bi.fact_aplicacion', 'V') IS NOT NULL DROP VIEW bi.fact_aplicacion;
GO
CREATE VIEW bi.fact_aplicacion
AS
SELECT
    a.factura_key,
    CONVERT(VARCHAR(4), a.sociedad) + '|' + CONVERT(VARCHAR(4), a.ejercicio_pago) + '|'
        + a.pago_id + '|' + CONVERT(VARCHAR(6), a.posicion_pago)  AS pago_key,
    a.pago_id                                                     AS documento_pago,
    a.factura_id                                                  AS documento_factura,
    a.documento_compensacion,
    a.fecha_compensacion,
    a.regla
FROM gold.fact_aplicacion_pagos a
WHERE a.fecha_compensacion >= DATEADD(MONTH, DATEDIFF(MONTH, 0, GETDATE()) - 36, 0);
GO

-- ----------------------------------------------------------------------------
-- Budget facts: small, full history. Attributes frozen at the cut-off.
-- ----------------------------------------------------------------------------
IF OBJECT_ID('bi.fact_presupuesto_segmento', 'V') IS NOT NULL DROP VIEW bi.fact_presupuesto_segmento;
GO
CREATE VIEW bi.fact_presupuesto_segmento
AS
SELECT
    mes_presupuesto,
    fecha_corte,
    canal_key,
    region_key,
    ejecutivo_key,
    bucket_key,
    estatus_comercial,
    tasa_origen,
    tasa_recuperacion,
    monto_cartera,
    monto_esperado,
    monto_real
FROM gold.fact_presupuesto_cartera;
GO

IF OBJECT_ID('bi.fact_presupuesto_dia', 'V') IS NOT NULL DROP VIEW bi.fact_presupuesto_dia;
GO
CREATE VIEW bi.fact_presupuesto_dia
AS
SELECT
    fecha,
    mes_presupuesto,
    fecha_corte,
    es_dia_habil,
    slot_calendario,
    origen,
    monto_presupuesto
FROM gold.fact_presupuesto_cobranza;
GO
