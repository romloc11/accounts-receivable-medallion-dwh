/* ============================================================================
   gold.load_presupuesto_cobranza
   Purpose : Calculates the collections budget of one month into
             gold.fact_presupuesto_cobranza (daily) and
             gold.fact_presupuesto_cartera (segment).
   Run     : EXEC gold.load_presupuesto_cobranza;   once a month, on the 4th
             business day. Not part of gold.load_gold: a budget recalculated
             every night chases the actuals and stops being a forecast.
   Params  : @mes          first day of the month; NULL = current month
             @fecha_corte  calculation day; NULL = 4th business day of @mes
             @forzar       0 refuses to replace a budget issued with another
                           cut-off; rerunning with the same cut-off is allowed
   Notes   : Scope resolved at the cut-off against the SCD2: channels 10/40/60
             and not FUERA_DE_ALCANCE. Rates by bucket x tipo_gestion, calibrated
             on the 24 closed months before @mes; a cell with fewer than
             @min_hist invoices falls back to the bucket rate (tasa_origen
             BUCKET). Model and validation in modelo_presupuesto.sql and DESIGN.md.
   ============================================================================ */
USE ANALISIS_DATOS;
GO

IF OBJECT_ID('gold.load_presupuesto_cobranza') IS NOT NULL
    DROP PROCEDURE gold.load_presupuesto_cobranza;
GO

CREATE PROCEDURE gold.load_presupuesto_cobranza
    @mes         DATE = NULL,
    @fecha_corte DATE = NULL,
    @forzar      BIT  = 0
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @proc VARCHAR(128) = 'gold.load_presupuesto_cobranza',
            @step VARCHAR(128) = 'start',
            @t0   DATETIME2(0) = SYSDATETIME(),
            @t    DATETIME2(0) = SYSDATETIME(),
            @rows INT,
            @err  VARCHAR(4000),
            @line INT,
            @msg  VARCHAR(400);
    DECLARE @min_hist INT = 500;   -- minimum invoices to trust a segmented cell

    BEGIN TRY
        -- ------------------------------------------------------------------------
        -- Parameters and guards
        -- ------------------------------------------------------------------------
        SET @step = 'parameters';

        IF @mes IS NULL
            SET @mes = DATEADD(MONTH, DATEDIFF(MONTH, 0, GETDATE()), 0);
        SET @mes = DATEFROMPARTS(YEAR(@mes), MONTH(@mes), 1);

        DECLARE @fin DATE = EOMONTH(@mes);

        IF @fecha_corte IS NULL
            SET @fecha_corte = (SELECT MIN(fecha) FROM gold.dim_fecha
                                WHERE fecha >= @mes AND fecha <= @fin AND dia_habil_del_mes = 4);

        IF @fecha_corte IS NULL
        BEGIN
            SET @msg = 'No se pudo resolver el 4o dia habil de ' + CONVERT(VARCHAR(10), @mes, 120)
                     + '. Revisar que gold.dim_fecha cubra el mes y traiga dia_habil_del_mes.';
            THROW 50001, @msg, 1;
        END

        IF @fecha_corte < @mes OR @fecha_corte > @fin
        BEGIN
            SET @msg = 'La fecha de corte ' + CONVERT(VARCHAR(10), @fecha_corte, 120)
                     + ' cae fuera del mes ' + CONVERT(VARCHAR(10), @mes, 120) + '.';
            THROW 50002, @msg, 1;
        END

        -- Refreshed here instead of required beforehand: it only inserts what is
        -- missing, and a forgotten run would leave a new ejecutivo unclassified.
        SET @step = 'gold.load_dim_presupuesto';
        IF OBJECT_ID('gold.load_dim_presupuesto') IS NOT NULL
            EXEC gold.load_dim_presupuesto;

        SET @step = 'parameters';
        IF NOT EXISTS (SELECT 1 FROM gold.dim_ejecutivo)
        BEGIN
            SET @msg = 'gold.dim_ejecutivo esta vacia y no se pudo poblar. Revisar que exista'
                     + ' gold.load_dim_presupuesto (03_gold/ddl_dim_presupuesto.sql): sin'
                     + ' tipo_gestion las tasas no se pueden segmentar.';
            THROW 50004, @msg, 1;
        END

        DECLARE @corte_previo DATE =
            (SELECT TOP 1 fecha_corte FROM gold.fact_presupuesto_cobranza WHERE mes_presupuesto = @mes);

        IF @corte_previo IS NOT NULL AND @corte_previo <> @fecha_corte AND @forzar = 0
        BEGIN
            SET @msg = 'Ya hay presupuesto de ' + CONVERT(VARCHAR(10), @mes, 120)
                     + ' con corte ' + CONVERT(VARCHAR(10), @corte_previo, 120)
                     + ' y se esta pidiendo con corte ' + CONVERT(VARCHAR(10), @fecha_corte, 120)
                     + '. Ese numero puede ser contra el que se mide el equipo. Si de verdad'
                     + ' se quiere reemplazar, correr con @forzar = 1.';
            THROW 50003, @msg, 1;
        END

        DECLARE @cal_ini DATE = DATEADD(MONTH, -24, @mes);

        SET @step = 'month ' + CONVERT(VARCHAR(10), @mes, 120)
                  + ', cut-off ' + CONVERT(VARCHAR(10), @fecha_corte, 120)
                  + ', calibration from ' + CONVERT(VARCHAR(10), @cal_ini, 120)
                  + CASE WHEN @fecha_corte > CAST(GETDATE() AS DATE)
                         THEN ' (future cut-off: T2 incomplete)' ELSE '' END;
        EXEC control.log_step @proc, @step, @t0;

        -- ------------------------------------------------------------------------
        -- 1. Calibration months and their cut-off
        -- ------------------------------------------------------------------------
        SET @step = 'calibration months and cash'; SET @t = SYSDATETIME();
        IF OBJECT_ID('tempdb..#cal') IS NOT NULL DROP TABLE #cal;
        SELECT DATEFROMPARTS(anio, mes, 1) AS ini,
               EOMONTH(DATEFROMPARTS(anio, mes, 1)) AS fin,
               MIN(CASE WHEN dia_habil_del_mes = 4 THEN fecha END) AS corte
        INTO   #cal
        FROM   gold.dim_fecha
        WHERE  fecha >= @cal_ini AND fecha < @mes
        GROUP BY anio, mes
        OPTION (RECOMPILE);

        -- Cash materialized once: it is used in four places (T2, the T3 factor, the
        -- calendar profile, observed days), always with the same definition.
        IF OBJECT_ID('tempdb..#caja') IS NOT NULL DROP TABLE #caja;
        SELECT c.fecha, c.monto_real AS monto
        INTO   #caja
        FROM   gold.vw_cobranza_diaria c
        WHERE  c.fecha >= @cal_ini AND c.fecha <= @fin
        OPTION (RECOMPILE);
        SET @rows = @@ROWCOUNT;
        CREATE UNIQUE CLUSTERED INDEX ix_caja ON #caja(fecha);
        EXEC control.log_step @proc, @step, @t, @rows;

        -- ------------------------------------------------------------------------
        -- 2. Historical portfolio at each cut-off, with the same scope rules as the
        --    target month
        -- ------------------------------------------------------------------------
        SET @step = 'historical portfolio'; SET @t = SYSDATETIME();
        IF OBJECT_ID('tempdb..#hist') IS NOT NULL DROP TABLE #hist;
        SELECT c.ini, f.monto, e.tipo_gestion,
               CASE
                 WHEN DATEDIFF(DAY, f.fecha_vencimiento, c.corte) <  0
                      AND f.fecha_vencimiento <= c.fin                  THEN 'A1'
                 WHEN DATEDIFF(DAY, f.fecha_vencimiento, c.corte) <  0   THEN 'A2'
                 WHEN DATEDIFF(DAY, f.fecha_vencimiento, c.corte) <=  30 THEN 'B'
                 WHEN DATEDIFF(DAY, f.fecha_vencimiento, c.corte) <=  60 THEN 'C'
                 WHEN DATEDIFF(DAY, f.fecha_vencimiento, c.corte) <=  90 THEN 'D'
                 WHEN DATEDIFF(DAY, f.fecha_vencimiento, c.corte) <= 180 THEN 'E'
                 WHEN DATEDIFF(DAY, f.fecha_vencimiento, c.corte) <= 365 THEN 'F'
                 ELSE 'G'
               END AS bucket,
               CASE WHEN f.fecha_pago_efectiva BETWEEN c.corte AND c.fin
                    THEN f.monto ELSE 0 END AS cobrado
        INTO   #hist
        FROM   #cal c
        JOIN   gold.fact_facturas f
               ON  f.fecha_documento < c.ini
               AND (f.fecha_compensacion IS NULL OR f.fecha_compensacion >= c.corte)
               AND f.fecha_vencimiento IS NOT NULL
        JOIN   gold.dim_cliente_comercial d
               ON  d.cliente_id = f.cliente_id
               AND c.corte >= d.fecha_inicio_vigencia
               AND (d.fecha_fin_vigencia IS NULL OR c.corte <= d.fecha_fin_vigencia)
               AND d.canal_distribucion IN (10, 40, 60)
               AND d.estatus_comercial <> 'FUERA_DE_ALCANCE'
        LEFT JOIN gold.dim_cliente_credito k
               ON  k.cliente_id = f.cliente_id
               AND c.corte >= k.fecha_inicio_vigencia
               AND (k.fecha_fin_vigencia IS NULL OR c.corte <= k.fecha_fin_vigencia)
        JOIN   gold.dim_ejecutivo e
               ON  e.ejecutivo_key =
                   UPPER(ISNULL(NULLIF(LTRIM(RTRIM(k.analista_credito_nombre)),''),'(SIN ASIGNAR)'))
        OPTION (RECOMPILE);
        SET @rows = @@ROWCOUNT;
        EXEC control.log_step @proc, @step, @t, @rows;

        -- ------------------------------------------------------------------------
        -- 3. Rates: segmented, per bucket, and the chosen one. Weighted by amount.
        -- ------------------------------------------------------------------------
        SET @step = 'rates and T3 factor'; SET @t = SYSDATETIME();
        IF OBJECT_ID('tempdb..#t_seg') IS NOT NULL DROP TABLE #t_seg;
        SELECT bucket, tipo_gestion, COUNT(*) AS n,
               SUM(cobrado) / NULLIF(SUM(monto), 0) AS tasa
        INTO   #t_seg FROM #hist GROUP BY bucket, tipo_gestion;

        IF OBJECT_ID('tempdb..#t_bk') IS NOT NULL DROP TABLE #t_bk;
        SELECT bucket, SUM(cobrado) / NULLIF(SUM(monto), 0) AS tasa
        INTO   #t_bk FROM #hist GROUP BY bucket;

        -- CROSS JOIN so no combination is left without a rate: a tipo_gestion with no
        -- history in a bucket would otherwise drop out of the JOIN and shorten the total.
        IF OBJECT_ID('tempdb..#tasa') IS NOT NULL DROP TABLE #tasa;
        SELECT b.bucket, g.tipo_gestion,
               CASE WHEN s.n >= @min_hist THEN s.tasa ELSE b.tasa END AS tasa,
               CASE WHEN s.n >= @min_hist THEN 'SEGMENTO' ELSE 'BUCKET' END AS tasa_origen
        INTO   #tasa
        FROM   #t_bk b
        CROSS JOIN (SELECT DISTINCT tipo_gestion FROM gold.dim_ejecutivo) g
        LEFT JOIN  #t_seg s ON s.bucket = b.bucket AND s.tipo_gestion = g.tipo_gestion;

        -- ------------------------------------------------------------------------
        -- 4. T3 factor over the same window
        -- ------------------------------------------------------------------------
        IF OBJECT_ID('tempdb..#hm') IS NOT NULL DROP TABLE #hm;
        SELECT c.ini, t1.v AS t1, t2.v AS t2, caja.v AS real_caja
        INTO   #hm
        FROM   #cal c
        CROSS APPLY (SELECT SUM(h.monto * t.tasa) v FROM #hist h
                     JOIN #tasa t ON t.bucket = h.bucket AND t.tipo_gestion = h.tipo_gestion
                     WHERE h.ini = c.ini) t1
        CROSS APPLY (SELECT SUM(k.monto) v FROM #caja k
                     WHERE k.fecha >= c.ini AND k.fecha < c.corte) t2
        CROSS APPLY (SELECT SUM(k.monto) v FROM #caja k
                     WHERE k.fecha >= c.ini AND k.fecha <= c.fin) caja
        OPTION (RECOMPILE);

        DECLARE @k DECIMAL(12,6) = (SELECT SUM(real_caja - t1 - t2) / NULLIF(SUM(t1), 0) FROM #hm);
        EXEC control.log_step @proc, @step, @t;

        -- ------------------------------------------------------------------------
        -- 5. Calendar slots, one expression for calibration and target month.
        --    Weekday from DATEDIFF against a known Monday (1900-01-01), not
        --    DATEPART(WEEKDAY), which depends on SET DATEFIRST.
        -- ------------------------------------------------------------------------
        SET @step = 'calendar profile'; SET @t = SYSDATETIME();
        IF OBJECT_ID('tempdb..#slot') IS NOT NULL DROP TABLE #slot;
        SELECT d.fecha, d.es_dia_habil,
               CASE
                 WHEN d.es_dia_habil = 0 THEN NULL
                 WHEN d.dia_habil_del_mes <= 3
                      THEN 'I' + RIGHT('0' + CAST(d.dia_habil_del_mes AS VARCHAR(2)), 2)
                 WHEN d.dias_habiles_mes - d.dia_habil_del_mes + 1 <= 8
                      THEN 'F' + RIGHT('0' + CAST(d.dias_habiles_mes - d.dia_habil_del_mes + 1 AS VARCHAR(2)), 2)
                 ELSE 'M' + CASE DATEDIFF(DAY, '19000101', d.fecha) % 7
                              WHEN 0 THEN 'LU' WHEN 1 THEN 'MA' WHEN 2 THEN 'MI'
                              WHEN 3 THEN 'JU' WHEN 4 THEN 'VI' ELSE 'XX' END
               END AS slot
        INTO   #slot
        FROM   gold.dim_fecha d
        WHERE  d.fecha >= @cal_ini AND d.fecha <= @fin;
        CREATE UNIQUE CLUSTERED INDEX ix_slot ON #slot(fecha);

        -- 6. Profile: share of each day within its month's business-day cash.
        IF OBJECT_ID('tempdb..#perfil') IS NOT NULL DROP TABLE #perfil;
        SELECT s.slot, AVG(ISNULL(dia.v, 0) / NULLIF(mesc.v, 0)) AS peso
        INTO   #perfil
        FROM   #cal c
        JOIN   #slot s ON s.fecha >= c.ini AND s.fecha <= c.fin AND s.es_dia_habil = 1
        OUTER APPLY (SELECT k.monto v FROM #caja k WHERE k.fecha = s.fecha) dia
        CROSS APPLY (SELECT SUM(k.monto) v FROM #caja k
                     JOIN gold.dim_fecha d2 ON d2.fecha = k.fecha AND d2.es_dia_habil = 1
                     WHERE k.fecha >= c.ini AND k.fecha <= c.fin) mesc
        GROUP BY s.slot;
        EXEC control.log_step @proc, @step, @t;

        -- ------------------------------------------------------------------------
        -- 7. Current portfolio at the cut-off, at segment grain
        -- ------------------------------------------------------------------------
        SET @step = 'portfolio at cut-off'; SET @t = SYSDATETIME();
        IF OBJECT_ID('tempdb..#hoy') IS NOT NULL DROP TABLE #hoy;
        SELECT bk.bucket, bk.ejecutivo_key, bk.tipo_gestion,
               bk.region_key, bk.canal_key, bk.estatus_comercial,
               SUM(bk.monto) AS monto_cartera
        INTO   #hoy
        FROM (
            SELECT f.monto,
                   e.ejecutivo_key, e.tipo_gestion,
                   UPPER(ISNULL(NULLIF(LTRIM(RTRIM(d.region)),''),'(SIN REGION)')) AS region_key,
                   LTRIM(RTRIM(d.canal_distribucion))                              AS canal_key,
                   d.estatus_comercial,
                   CASE
                     WHEN DATEDIFF(DAY, f.fecha_vencimiento, @fecha_corte) <  0
                          AND f.fecha_vencimiento <= @fin                        THEN 'A1'
                     WHEN DATEDIFF(DAY, f.fecha_vencimiento, @fecha_corte) <  0   THEN 'A2'
                     WHEN DATEDIFF(DAY, f.fecha_vencimiento, @fecha_corte) <=  30 THEN 'B'
                     WHEN DATEDIFF(DAY, f.fecha_vencimiento, @fecha_corte) <=  60 THEN 'C'
                     WHEN DATEDIFF(DAY, f.fecha_vencimiento, @fecha_corte) <=  90 THEN 'D'
                     WHEN DATEDIFF(DAY, f.fecha_vencimiento, @fecha_corte) <= 180 THEN 'E'
                     WHEN DATEDIFF(DAY, f.fecha_vencimiento, @fecha_corte) <= 365 THEN 'F'
                     ELSE 'G'
                   END AS bucket
            FROM   gold.fact_facturas f
            JOIN   gold.dim_cliente_comercial d
                   ON  d.cliente_id = f.cliente_id
                   AND @fecha_corte >= d.fecha_inicio_vigencia
                   AND (d.fecha_fin_vigencia IS NULL OR @fecha_corte <= d.fecha_fin_vigencia)
                   AND d.canal_distribucion IN (10, 40, 60)
                   AND d.estatus_comercial <> 'FUERA_DE_ALCANCE'
            LEFT JOIN gold.dim_cliente_credito k
                   ON  k.cliente_id = f.cliente_id
                   AND @fecha_corte >= k.fecha_inicio_vigencia
                   AND (k.fecha_fin_vigencia IS NULL OR @fecha_corte <= k.fecha_fin_vigencia)
            JOIN   gold.dim_ejecutivo e
                   ON  e.ejecutivo_key =
                       UPPER(ISNULL(NULLIF(LTRIM(RTRIM(k.analista_credito_nombre)),''),'(SIN ASIGNAR)'))
            WHERE  f.fecha_documento < @mes
              AND (f.fecha_compensacion IS NULL OR f.fecha_compensacion >= @fecha_corte)
              AND  f.fecha_vencimiento IS NOT NULL
        ) bk
        GROUP BY bk.bucket, bk.ejecutivo_key, bk.tipo_gestion,
                 bk.region_key, bk.canal_key, bk.estatus_comercial
        OPTION (RECOMPILE);
        SET @rows = @@ROWCOUNT;
        EXEC control.log_step @proc, @step, @t, @rows;

        -- ------------------------------------------------------------------------
        -- The three terms
        -- ------------------------------------------------------------------------
        DECLARE @T1 DECIMAL(19,2) =
            (SELECT SUM(h.monto_cartera * t.tasa) FROM #hoy h
             JOIN #tasa t ON t.bucket = h.bucket AND t.tipo_gestion = h.tipo_gestion);
        DECLARE @T2 DECIMAL(19,2) =
            (SELECT ISNULL(SUM(monto), 0) FROM #caja
             WHERE fecha >= @mes AND fecha < @fecha_corte);
        DECLARE @T3 DECIMAL(19,2) = @T1 * @k;

        -- Weight renormalized over the business days from the cut-off on only: the
        -- earlier days are observed, not forecast.
        DECLARE @peso_restante DECIMAL(19,10) =
            (SELECT SUM(p.peso) FROM #slot s JOIN #perfil p ON p.slot = s.slot
             WHERE s.fecha >= @fecha_corte AND s.fecha <= @fin AND s.es_dia_habil = 1);

        -- ------------------------------------------------------------------------
        -- Write
        -- ------------------------------------------------------------------------
        BEGIN TRANSACTION;

        SET @step = 'delete month'; SET @t = SYSDATETIME();
        DELETE FROM gold.fact_presupuesto_cobranza WHERE mes_presupuesto = @mes;
        SET @rows = @@ROWCOUNT;
        DELETE FROM gold.fact_presupuesto_cartera  WHERE mes_presupuesto = @mes;
        SET @rows = @rows + @@ROWCOUNT;
        EXEC control.log_step @proc, @step, @t, @rows;

        SET @step = 'gold.fact_presupuesto_cartera insert'; SET @t = SYSDATETIME();
        INSERT INTO gold.fact_presupuesto_cartera
            (mes_presupuesto, fecha_corte, bucket_key, ejecutivo_key, region_key, canal_key,
             estatus_comercial, monto_cartera, tasa_recuperacion, tasa_origen, monto_esperado, monto_real)
        SELECT @mes, @fecha_corte, h.bucket, h.ejecutivo_key, h.region_key, h.canal_key,
               h.estatus_comercial, h.monto_cartera, t.tasa, t.tasa_origen,
               h.monto_cartera * t.tasa, NULL
        FROM   #hoy h
        JOIN   #tasa t ON t.bucket = h.bucket AND t.tipo_gestion = h.tipo_gestion;
        SET @rows = @@ROWCOUNT;
        EXEC control.log_step @proc, @step, @t, @rows;

        SET @step = 'gold.fact_presupuesto_cobranza insert'; SET @t = SYSDATETIME();
        INSERT INTO gold.fact_presupuesto_cobranza
            (mes_presupuesto, fecha, fecha_corte, es_dia_habil, slot_calendario,
             origen, monto_presupuesto)
        SELECT @mes, s.fecha, @fecha_corte, s.es_dia_habil, s.slot,
               CASE WHEN s.fecha < @fecha_corte THEN 'OBSERVADO' ELSE 'PRONOSTICO' END,
               CASE
                 -- Before the cut-off the money is already in the bank: copied, not forecast.
                 WHEN s.fecha < @fecha_corte THEN ISNULL(caja.v, 0)
                 -- Non-business days: 0.23% historically, budgeted at zero.
                 WHEN s.es_dia_habil = 0     THEN 0
                 ELSE (@T1 + @T3) * p.peso / NULLIF(@peso_restante, 0)
               END
        FROM   #slot s
        LEFT JOIN #perfil p ON p.slot = s.slot
        OUTER APPLY (SELECT k.monto v FROM #caja k WHERE k.fecha = s.fecha) caja
        WHERE  s.fecha >= @mes AND s.fecha <= @fin
        OPTION (RECOMPILE);
        SET @rows = @@ROWCOUNT;
        EXEC control.log_step @proc, @step, @t, @rows;

        COMMIT TRANSACTION;

        -- ------------------------------------------------------------------------
        -- Summary
        -- ------------------------------------------------------------------------
        DECLARE @tot   DECIMAL(19,2) = @T1 + @T2 + @T3;
        DECLARE @cob   DECIMAL(19,2) =
            (SELECT SUM(c.monto_esperado) FROM gold.fact_presupuesto_cartera c
             JOIN gold.dim_ejecutivo e ON e.ejecutivo_key = c.ejecutivo_key
             WHERE c.mes_presupuesto = @mes AND e.es_cobrable = 1);
        DECLARE @seg   INT = (SELECT COUNT(*) FROM gold.fact_presupuesto_cartera WHERE mes_presupuesto = @mes);
        DECLARE @resp  INT = (SELECT COUNT(*) FROM gold.fact_presupuesto_cartera
                              WHERE mes_presupuesto = @mes AND tasa_origen = 'BUCKET');

        SET @t = SYSDATETIME();
        SET @step = 'T1 portfolio x rate: ' + CONVERT(VARCHAR(20), CAST(@T1/1000000.0 AS DECIMAL(12,1))) + ' MM';
        EXEC control.log_step @proc, @step, @t;
        SET @step = 'T2 already in bank: ' + CONVERT(VARCHAR(20), CAST(@T2/1000000.0 AS DECIMAL(12,1))) + ' MM';
        EXEC control.log_step @proc, @step, @t;
        SET @step = 'T3 in-month (k=' + CONVERT(VARCHAR(10), CAST(@k AS DECIMAL(6,3))) + '): '
                  + CONVERT(VARCHAR(20), CAST(@T3/1000000.0 AS DECIMAL(12,1))) + ' MM';
        EXEC control.log_step @proc, @step, @t;
        SET @step = 'BUDGET TOTAL: ' + CONVERT(VARCHAR(20), CAST(@tot/1000000.0 AS DECIMAL(12,1))) + ' MM'
                  + ' (T1 cobrable ' + CONVERT(VARCHAR(20), CAST(@cob/1000000.0 AS DECIMAL(12,1))) + ' MM)';
        EXEC control.log_step @proc, @step, @t;
        SET @step = 'segments (rows) / with fallback rate: ' + CAST(@resp AS VARCHAR(8));
        EXEC control.log_step @proc, @step, @t, @seg;

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
