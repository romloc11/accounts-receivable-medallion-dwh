/* ============================================================================
   silver.load_silver
   Purpose : Daily load from bronze into silver: trimmed text, real dates,
             customer ids without leading zeros, mandante 400 only.
   Run     : EXEC silver.load_silver;   after bronze.load_bronze
   Loads   : full reload   kna1, knvp, knkk, knvv, bsid, knb1, knb5, pa0001
             merge window  bsad (AUGDT), bkpf (BUDAT), bsas (AUGDT),
                           bsis (two steps, see the section)
             The window starts on the first day of the previous month. Older
             history comes from the backfill scripts in this folder.
   Notes   : SAP dates arrive as 'YYYYMMDD' text or '00000000':
             TRY_CONVERT(DATE, NULLIF(LTRIM(RTRIM(x)), '00000000'), 112).
   ============================================================================ */
USE ANALISIS_DATOS;
GO

IF OBJECT_ID('silver.load_silver', 'P') IS NOT NULL
    DROP PROCEDURE silver.load_silver;
GO

CREATE PROCEDURE silver.load_silver
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @proc VARCHAR(128) = 'silver.load_silver',
            @step VARCHAR(128) = 'start',
            @t0   DATETIME2(0) = SYSDATETIME(),
            @t    DATETIME2(0) = SYSDATETIME(),
            @rows INT,
            @err  VARCHAR(4000),
            @line INT;

    BEGIN TRY
        -- --------------------------------------------------------------------
        -- silver.sap_kna1: customer master
        -- --------------------------------------------------------------------
        SET @step = 'silver.sap_kna1 full'; SET @t = SYSDATETIME();

        TRUNCATE TABLE silver.sap_kna1;

        INSERT INTO silver.sap_kna1 (
            mandante, cliente_id, rfc, nombre, nombre2, pais, estado,
            poblacion, codigo_postal, calle, bloqueo_pedido, regimen_fiscal,
            telefono, telefono_extra, whatsapp, fecha_creacion, grupo_cuentas,
            proveedor_vinculado, flag_bloqueado, flag_cliente_ocasional, flag_persona_fisica, flag_sujeto_iva,
            tipo_servicio_paq1, tipo_servicio_paq2, tipo_servicio_paq3,
            tiempo_entrega_paq1, tiempo_entrega_paq2, tiempo_entrega_paq3
        )
        SELECT
            LTRIM(RTRIM(MANDT)),
            CAST(CAST(NULLIF(LTRIM(RTRIM(KUNNR)), '') AS BIGINT) AS VARCHAR(10)),
            NULLIF(LTRIM(RTRIM(STCD1)), ''),
            NULLIF(LTRIM(RTRIM(NAME1)), ''),
            NULLIF(LTRIM(RTRIM(NAME2)), ''),
            NULLIF(LTRIM(RTRIM(LAND1)), ''),
            NULLIF(LTRIM(RTRIM(REGIO)), ''),
            NULLIF(LTRIM(RTRIM(ORT01)), ''),
            NULLIF(LTRIM(RTRIM(PSTLZ)), ''),
            NULLIF(LTRIM(RTRIM(STRAS)), ''),
            NULLIF(LTRIM(RTRIM(AUFSD)), ''),
            NULLIF(LTRIM(RTRIM(SORTL)), ''),
            NULLIF(LTRIM(RTRIM(TELF1)), ''),
            NULLIF(LTRIM(RTRIM(TELF2)), ''),
            NULLIF(LTRIM(RTRIM(TELFX)), ''),
            TRY_CONVERT(DATE, NULLIF(LTRIM(RTRIM(ERDAT)), '00000000'), 112),
            NULLIF(LTRIM(RTRIM(KTOKD)), ''),
            NULLIF(LTRIM(RTRIM(LIFNR)), ''),
            CASE WHEN LTRIM(RTRIM(SPERR)) = 'X' THEN 1 ELSE 0 END,
            CASE WHEN LTRIM(RTRIM(XCPDK)) = 'X' THEN 1 ELSE 0 END,
            CASE WHEN LTRIM(RTRIM(STKZN)) = 'X' THEN 1 ELSE 0 END,
            CASE WHEN LTRIM(RTRIM(STKZU)) = 'X' THEN 1 ELSE 0 END,
            NULLIF(LTRIM(RTRIM(KATR1)), ''),
            NULLIF(LTRIM(RTRIM(KATR2)), ''),
            NULLIF(LTRIM(RTRIM(KATR3)), ''),
            NULLIF(LTRIM(RTRIM(KATR6)), ''),
            NULLIF(LTRIM(RTRIM(KATR7)), ''),
            NULLIF(LTRIM(RTRIM(KATR8)), '')
        FROM bronze.sap_kna1 WITH (NOLOCK)
        WHERE MANDT = '400'
          AND LTRIM(RTRIM(LOEVM)) <> 'X';   -- not flagged for deletion
        SET @rows = @@ROWCOUNT;
        EXEC control.log_step @proc, @step, @t, @rows;

        -- --------------------------------------------------------------------
        -- silver.sap_knvp: partner functions
        -- --------------------------------------------------------------------
        SET @step = 'silver.sap_knvp full'; SET @t = SYSDATETIME();

        TRUNCATE TABLE silver.sap_knvp;

        INSERT INTO silver.sap_knvp (
            mandante, cliente_id, organizacion_ventas, canal_distribucion,
            sector, funcion_interlocutor, descripcion_funcion, contador,
            cliente_asociado, id_interlocutor, nombre_interlocutor, id_paqueteria, flag_default
        )
        SELECT
            LTRIM(RTRIM(p.MANDT)),
            CAST(CAST(NULLIF(LTRIM(RTRIM(p.KUNNR)), '') AS BIGINT) AS VARCHAR(10)),
            LTRIM(RTRIM(p.VKORG)),
            LTRIM(RTRIM(p.VTWEG)),
            LTRIM(RTRIM(p.SPART)),
            LTRIM(RTRIM(p.PARVW)),
            CASE LTRIM(RTRIM(p.PARVW))
                WHEN 'AG' THEN 'Solicitante'
                WHEN 'RE' THEN 'Receptor de Factura'
                WHEN 'RG' THEN 'Pagador'
                WHEN 'WE' THEN 'Receptor de Mercancia'
                WHEN 'VE' THEN 'Vendedor'
                WHEN 'GR' THEN 'Gerente Regional'
                WHEN 'E1' THEN 'Ejecutivo de Credito'
                WHEN 'E2' THEN 'Ejecutivo de Telemarketing'
                WHEN 'CC' THEN 'Cobrador de Credito'
                WHEN 'ZP' THEN 'Aplicacion de Pagos'
                WHEN 'Z1' THEN 'Paqueteria 1'
                WHEN 'Z2' THEN 'Paqueteria 2'
                WHEN 'Z3' THEN 'Paqueteria 3'
                WHEN 'Z4' THEN 'Paqueteria 4'
                ELSE NULL
            END,
            LTRIM(RTRIM(p.PARZA)),
            CAST(CAST(NULLIF(LTRIM(RTRIM(p.KUNN2)), '') AS BIGINT) AS VARCHAR(10)),
            NULLIF(LTRIM(RTRIM(p.PERNR)), ''),
            NULLIF(LTRIM(RTRIM(e.ENAME)), ''),
            NULLIF(LTRIM(RTRIM(p.LIFNR)), ''),
            CASE WHEN LTRIM(RTRIM(p.DEFPA)) = 'X' THEN 1 ELSE 0 END
        FROM bronze.sap_knvp p WITH (NOLOCK)
        LEFT JOIN bronze.sap_pa0001 e WITH (NOLOCK)
            ON e.MANDT = p.MANDT AND e.PERNR = p.PERNR AND e.ENDDA = '99991231'
        WHERE p.MANDT = '400'
          AND LTRIM(RTRIM(p.VKORG)) = '2000';   -- the real sales organization
        SET @rows = @@ROWCOUNT;
        EXEC control.log_step @proc, @step, @t, @rows;

        -- --------------------------------------------------------------------
        -- silver.sap_knkk: credit control
        -- --------------------------------------------------------------------
        SET @step = 'silver.sap_knkk full'; SET @t = SYSDATETIME();

        TRUNCATE TABLE silver.sap_knkk;

        INSERT INTO silver.sap_knkk (
            mandante, cliente_id, codigo_padre, area_control_credito,
            limite_credito, monto_facturas_abiertas, monto_pedidos_no_facturados,
            monto_especiales_pagares, fecha_ultima_revision, usuario_creacion,
            fecha_creacion, prioridad, bloqueo_credito, fecha_proxima_revision,
            etiqueta_credito, grupo_responsables_credito, fecha_cambio_credito_contado,
            fecha_ultima_modificacion, usuario_ultima_modificacion,
            fecha_proxima_verificacion, tipo_garantia, fecha_ultimo_pago,
            monto_ultimo_pago, moneda_ultimo_pago, clasificacion_riesgo,
            fecha_ultima_modificacion_texto, grupo_credito, indicador_pago_db, limite_credito_recomendado_db
        )
        SELECT
            LTRIM(RTRIM(MANDT)),
            CAST(CAST(NULLIF(LTRIM(RTRIM(KUNNR)), '') AS BIGINT) AS VARCHAR(10)),
            CAST(CAST(NULLIF(LTRIM(RTRIM(KNKLI)), '') AS BIGINT) AS VARCHAR(10)),
            LTRIM(RTRIM(KKBER)),
            ISNULL(KLIMK, 0),
            ISNULL(SKFOR, 0),
            ISNULL(SAUFT, 0),
            ISNULL(SSOBL, 0),
            TRY_CONVERT(DATE, NULLIF(LTRIM(RTRIM(UEDAT)), '00000000'), 112),
            NULLIF(LTRIM(RTRIM(ERNAM)), ''),
            TRY_CONVERT(DATE, NULLIF(LTRIM(RTRIM(ERDAT)), '00000000'), 112),
            NULLIF(LTRIM(RTRIM(CTLPC)), ''),
            NULLIF(LTRIM(RTRIM(CRBLB)), ''),
            TRY_CONVERT(DATE, NULLIF(LTRIM(RTRIM(NXTRV)), '00000000'), 112),
            NULLIF(LTRIM(RTRIM(KRAUS)), ''),
            NULLIF(LTRIM(RTRIM(SBGRP)), ''),
            TRY_CONVERT(DATE, NULLIF(LTRIM(RTRIM(REVDB)), '00000000'), 112),
            TRY_CONVERT(DATE, NULLIF(LTRIM(RTRIM(AEDAT)), '00000000'), 112),
            NULLIF(LTRIM(RTRIM(AENAM)), ''),
            TRY_CONVERT(DATE, NULLIF(LTRIM(RTRIM(SBDAT)), '00000000'), 112),
            NULLIF(LTRIM(RTRIM(KDGRP)), ''),
            TRY_CONVERT(DATE, NULLIF(LTRIM(RTRIM(CASHD)), '00000000'), 112),
            ISNULL(CASHA, 0),
            NULLIF(LTRIM(RTRIM(CASHC)), ''),
            NULLIF(LTRIM(RTRIM(DBRTG)), ''),
            TRY_CONVERT(DATE, NULLIF(LTRIM(RTRIM(AETXT)), '00000000'), 112),
            NULLIF(LTRIM(RTRIM(GRUPP)), ''),
            NULLIF(LTRIM(RTRIM(DBPAY)), ''),
            NULLIF(DBEKR, 0)
        FROM bronze.sap_knkk WITH (NOLOCK)
        WHERE MANDT = '400'
          AND LTRIM(RTRIM(KKBER)) = '2000';   -- the real credit control area
        SET @rows = @@ROWCOUNT;
        EXEC control.log_step @proc, @step, @t, @rows;

        -- --------------------------------------------------------------------
        -- silver.sap_knvv: sales area data
        -- --------------------------------------------------------------------
        SET @step = 'silver.sap_knvv full'; SET @t = SYSDATETIME();

        TRUNCATE TABLE silver.sap_knvv;

        INSERT INTO silver.sap_knvv (
            mandante, cliente_id, organizacion_ventas, canal_distribucion, sector,
            oficina_ventas, grupo_vendedores, region, ruta, ruta_nombre, centro_suministrador,
            grupo_clientes, grupo_precios, lista_precios,
            incoterm, incoterm_descripcion, entregas_parciales_max, prioridad_entrega,
            tiempo_entrega, tipo_servicio, tipo_servicio_2, condicion_expedicion,
            condicion_pago, moneda,
            bloqueo_entrega, bloqueo_factura, bloqueo_pedido, bloqueo_contacto_deudor,
            fecha_creacion, creado_por
        )
        SELECT
            LTRIM(RTRIM(v.MANDT)),
            CAST(CAST(NULLIF(LTRIM(RTRIM(v.KUNNR)), '') AS BIGINT) AS VARCHAR(10)),
            LTRIM(RTRIM(v.VKORG)),
            LTRIM(RTRIM(v.VTWEG)),
            LTRIM(RTRIM(v.SPART)),
            NULLIF(LTRIM(RTRIM(v.VKBUR)), ''),
            NULLIF(LTRIM(RTRIM(v.VKGRP)), ''),
            NULLIF(LTRIM(RTRIM(v.BZIRK)), ''),
            NULLIF(LTRIM(RTRIM(v.KVGR1)), ''),
            NULLIF(LTRIM(RTRIM(t.BEZEI)), ''),
            NULLIF(LTRIM(RTRIM(v.VWERK)), ''),
            NULLIF(LTRIM(RTRIM(v.KDGRP)), ''),
            NULLIF(LTRIM(RTRIM(v.KONDA)), ''),
            NULLIF(LTRIM(RTRIM(v.PLTYP)), ''),
            NULLIF(LTRIM(RTRIM(v.INCO1)), ''),
            NULLIF(LTRIM(RTRIM(v.INCO2)), ''),
            v.ANTLF,
            NULLIF(LTRIM(RTRIM(v.LPRIO)), ''),
            NULLIF(LTRIM(RTRIM(v.KVGR2)), ''),
            NULLIF(LTRIM(RTRIM(v.KVGR3)), ''),
            NULLIF(LTRIM(RTRIM(v.KVGR4)), ''),
            CASE WHEN LEN(LTRIM(RTRIM(v.VSBED))) = 1 THEN '0' + LTRIM(RTRIM(v.VSBED)) ELSE NULLIF(LTRIM(RTRIM(v.VSBED)), '') END,
            NULLIF(LTRIM(RTRIM(v.ZTERM)), ''),
            NULLIF(LTRIM(RTRIM(v.WAERS)), ''),
            NULLIF(LTRIM(RTRIM(v.LIFSD)), ''),
            NULLIF(LTRIM(RTRIM(v.FAKSD)), ''),
            NULLIF(LTRIM(RTRIM(v.AUFSD)), ''),
            NULLIF(LTRIM(RTRIM(v.CASSD)), ''),
            TRY_CONVERT(DATE, NULLIF(LTRIM(RTRIM(v.ERDAT)), '00000000'), 112),
            NULLIF(LTRIM(RTRIM(v.ERNAM)), '')
        FROM bronze.sap_knvv v WITH (NOLOCK)
        LEFT JOIN bronze.sap_tvv1t t WITH (NOLOCK)
            ON t.MANDT = v.MANDT AND t.SPRAS = 'S' AND t.KVGR1 = v.KVGR1
        WHERE v.MANDT = '400'
          AND LTRIM(RTRIM(v.LOEVM)) <> 'X'     -- not flagged for deletion
          AND LTRIM(RTRIM(v.VKORG)) = '2000';  -- the real sales organization
        SET @rows = @@ROWCOUNT;
        EXEC control.log_step @proc, @step, @t, @rows;

        -- --------------------------------------------------------------------
        -- silver.sap_bsid: open customer items
        -- --------------------------------------------------------------------
        SET @step = 'silver.sap_bsid full'; SET @t = SYSDATETIME();

        TRUNCATE TABLE silver.sap_bsid;

        INSERT INTO silver.sap_bsid (
            mandante, sociedad, cliente_id, ejercicio, mes, documento_id,
            asignacion, referencia, documento_ventas, posicion,
            fecha_contabilizacion, fecha_documento, fecha_registro_sistema, fecha_vencimiento,
            clase_documento, codigo_impuesto, debe_haber, monto_moneda_local, monto_moneda_doc,
            moneda, condicion_pago, dias_plazo,
            clave_contabilizacion, sgtxt,
            factura_referencia_documento, factura_referencia_ejercicio, factura_referencia_posicion,
            area_reclamacion, nivel_reclamacion, clave_reclamacion_legal,
            bloqueo_reclamacion_temporal, fecha_ultima_reclamacion,
            fecha_compensacion, documento_compensacion, ejercicio_compensacion
        )
        SELECT
            LTRIM(RTRIM(MANDT)),
            LTRIM(RTRIM(BUKRS)),
            CAST(CAST(NULLIF(LTRIM(RTRIM(KUNNR)), '') AS BIGINT) AS VARCHAR(10)),
            GJAHR,
            NULLIF(LTRIM(RTRIM(MONAT)), ''),
            LTRIM(RTRIM(BELNR)),
            NULLIF(LTRIM(RTRIM(ZUONR)), ''),
            NULLIF(LTRIM(RTRIM(XBLNR)), ''),
            NULLIF(LTRIM(RTRIM(VBELN)), ''),
            BUZEI,
            TRY_CONVERT(DATE, NULLIF(LTRIM(RTRIM(BUDAT)), '00000000'), 112),
            TRY_CONVERT(DATE, NULLIF(LTRIM(RTRIM(BLDAT)), '00000000'), 112),
            TRY_CONVERT(DATE, NULLIF(LTRIM(RTRIM(CPUDT)), '00000000'), 112),
            -- Due date is the baseline date plus the term days, not ZFBDT alone.
            DATEADD(DAY, ISNULL(ZBD1T, 0), TRY_CONVERT(DATE, NULLIF(LTRIM(RTRIM(ZFBDT)), '00000000'), 112)),
            NULLIF(LTRIM(RTRIM(BLART)), ''),
            NULLIF(LTRIM(RTRIM(MWSKZ)), ''),
            NULLIF(LTRIM(RTRIM(SHKZG)), ''),
            ISNULL(DMBTR, 0),
            ISNULL(WRBTR, 0),
            NULLIF(LTRIM(RTRIM(WAERS)), ''),
            NULLIF(LTRIM(RTRIM(ZTERM)), ''),
            ISNULL(ZBD1T, 0),
            NULLIF(LTRIM(RTRIM(BSCHL)), ''),
            NULLIF(LTRIM(RTRIM(SGTXT)), ''),
            NULLIF(LTRIM(RTRIM(REBZG)), ''),
            TRY_CAST(NULLIF(LTRIM(RTRIM(REBZJ)), '') AS INT),
            TRY_CAST(NULLIF(LTRIM(RTRIM(REBZZ)), '') AS INT),
            NULLIF(LTRIM(RTRIM(MABER)), ''),
            NULLIF(LTRIM(RTRIM(MANST)), ''),
            NULLIF(LTRIM(RTRIM(MSCHL)), ''),
            NULLIF(LTRIM(RTRIM(MANSP)), ''),
            TRY_CONVERT(DATE, NULLIF(LTRIM(RTRIM(MADAT)), '00000000'), 112),
            TRY_CONVERT(DATE, NULLIF(LTRIM(RTRIM(AUGDT)), '00000000'), 112),
            NULLIF(LTRIM(RTRIM(AUGBL)), ''),
            -- BSID stores an empty AUGGJ as '0000': the second NULLIF keeps it NULL.
            TRY_CAST(NULLIF(NULLIF(LTRIM(RTRIM(AUGGJ)), ''), '0000') AS INT)
        FROM bronze.sap_bsid WITH (NOLOCK)
        WHERE MANDT = '400';
        SET @rows = @@ROWCOUNT;
        EXEC control.log_step @proc, @step, @t, @rows;

        -- --------------------------------------------------------------------
        -- silver.sap_bsad: cleared customer items, merge by clearing date
        -- --------------------------------------------------------------------
        SET @step = 'silver.sap_bsad merge'; SET @t = SYSDATETIME();

        DECLARE @mes_anterior_inicio DATE = DATEADD(MONTH, DATEDIFF(MONTH, 0, GETDATE()) - 1, 0);
        -- AUGDT is text in bronze: compared as text so the column is not wrapped in a function.
        DECLARE @mes_anterior_inicio_str NVARCHAR(8) = CONVERT(NVARCHAR(8), @mes_anterior_inicio, 112);

        MERGE silver.sap_bsad AS tgt
        USING (
            SELECT
                LTRIM(RTRIM(MANDT)) AS mandante,
                LTRIM(RTRIM(BUKRS)) AS sociedad,
                CAST(CAST(NULLIF(LTRIM(RTRIM(KUNNR)), '') AS BIGINT) AS VARCHAR(10)) AS cliente_id,
                GJAHR AS ejercicio,
                NULLIF(LTRIM(RTRIM(MONAT)), '') AS mes,
                LTRIM(RTRIM(BELNR)) AS documento_id,
                NULLIF(LTRIM(RTRIM(ZUONR)), '') AS asignacion,
                NULLIF(LTRIM(RTRIM(XBLNR)), '') AS referencia,
                NULLIF(LTRIM(RTRIM(VBELN)), '') AS documento_ventas,
                BUZEI AS posicion,
                TRY_CONVERT(DATE, NULLIF(LTRIM(RTRIM(BUDAT)), '00000000'), 112) AS fecha_contabilizacion,
                TRY_CONVERT(DATE, NULLIF(LTRIM(RTRIM(BLDAT)), '00000000'), 112) AS fecha_documento,
                TRY_CONVERT(DATE, NULLIF(LTRIM(RTRIM(CPUDT)), '00000000'), 112) AS fecha_registro_sistema,
                TRY_CONVERT(DATE, NULLIF(LTRIM(RTRIM(AUGDT)), '00000000'), 112) AS fecha_compensacion,
                NULLIF(LTRIM(RTRIM(AUGBL)), '') AS documento_compensacion,
                TRY_CAST(NULLIF(LTRIM(RTRIM(AUGGJ)), '') AS INT) AS ejercicio_compensacion,
                NULLIF(LTRIM(RTRIM(BLART)), '') AS clase_documento,
                NULLIF(LTRIM(RTRIM(MWSKZ)), '') AS codigo_impuesto,
                NULLIF(LTRIM(RTRIM(SHKZG)), '') AS debe_haber,
                NULLIF(LTRIM(RTRIM(BSCHL)), '') AS clave_contabilizacion,
                DATEADD(DAY, ISNULL(ZBD1T, 0), TRY_CONVERT(DATE, NULLIF(LTRIM(RTRIM(ZFBDT)), '00000000'), 112)) AS fecha_vencimiento,
                ISNULL(DMBTR, 0) AS monto_moneda_local,
                ISNULL(WRBTR, 0) AS monto_moneda_doc,
                NULLIF(LTRIM(RTRIM(WAERS)), '') AS moneda,
                NULLIF(LTRIM(RTRIM(ZTERM)), '') AS condicion_pago,
                ISNULL(ZBD1T, 0) AS dias_plazo,
                NULLIF(LTRIM(RTRIM(MABER)), '') AS area_reclamacion,
                NULLIF(LTRIM(RTRIM(MANST)), '') AS nivel_reclamacion,
                NULLIF(LTRIM(RTRIM(MSCHL)), '') AS clave_reclamacion_legal,
                NULLIF(LTRIM(RTRIM(MANSP)), '') AS bloqueo_reclamacion_temporal,
                TRY_CONVERT(DATE, NULLIF(LTRIM(RTRIM(MADAT)), '00000000'), 112) AS fecha_ultima_reclamacion,
                NULLIF(LTRIM(RTRIM(SGTXT)), '') AS sgtxt,
                NULLIF(LTRIM(RTRIM(REBZG)), '') AS factura_referencia_documento,
                TRY_CAST(NULLIF(LTRIM(RTRIM(REBZJ)), '') AS INT) AS factura_referencia_ejercicio,
                TRY_CAST(NULLIF(LTRIM(RTRIM(REBZZ)), '') AS INT) AS factura_referencia_posicion
            FROM bronze.sap_bsad WITH (NOLOCK)
            WHERE MANDT = '400'
              AND AUGDT >= @mes_anterior_inicio_str
        ) AS src
        -- No clearing date in the ON: a line that was un-cleared and re-cleared has
        -- a new AUGDT and must update its row, not insert a duplicate key.
        ON  tgt.mandante = src.mandante
        AND tgt.sociedad = src.sociedad
        AND tgt.cliente_id = src.cliente_id
        AND tgt.ejercicio = src.ejercicio
        AND tgt.documento_id = src.documento_id
        AND tgt.posicion = src.posicion

        WHEN MATCHED THEN UPDATE SET
            tgt.fecha_compensacion = src.fecha_compensacion,
            tgt.documento_compensacion = src.documento_compensacion,
            tgt.ejercicio_compensacion = src.ejercicio_compensacion,
            tgt.clave_contabilizacion = src.clave_contabilizacion,
            tgt.sgtxt = src.sgtxt,
            tgt.factura_referencia_documento = src.factura_referencia_documento,
            tgt.factura_referencia_ejercicio = src.factura_referencia_ejercicio,
            tgt.factura_referencia_posicion = src.factura_referencia_posicion,
            tgt.monto_moneda_local = src.monto_moneda_local,
            tgt.monto_moneda_doc = src.monto_moneda_doc,
            tgt.condicion_pago = src.condicion_pago,
            tgt.area_reclamacion = src.area_reclamacion,
            tgt.nivel_reclamacion = src.nivel_reclamacion,
            tgt.clave_reclamacion_legal = src.clave_reclamacion_legal,
            tgt.bloqueo_reclamacion_temporal = src.bloqueo_reclamacion_temporal,
            tgt.fecha_ultima_reclamacion = src.fecha_ultima_reclamacion,
            tgt.fecha_carga = GETDATE()

        WHEN NOT MATCHED THEN
        INSERT (
            mandante, sociedad, cliente_id, ejercicio, mes, documento_id,
            asignacion, referencia, documento_ventas, posicion,
            fecha_contabilizacion, fecha_documento, fecha_registro_sistema, fecha_compensacion,
            documento_compensacion, ejercicio_compensacion, clase_documento, codigo_impuesto, debe_haber,
            clave_contabilizacion,
            fecha_vencimiento, monto_moneda_local,
            monto_moneda_doc, moneda, condicion_pago, dias_plazo, sgtxt,
            factura_referencia_documento, factura_referencia_ejercicio, factura_referencia_posicion,
            area_reclamacion, nivel_reclamacion, clave_reclamacion_legal,
            bloqueo_reclamacion_temporal, fecha_ultima_reclamacion
        )
        VALUES (
            src.mandante, src.sociedad, src.cliente_id, src.ejercicio, src.mes, src.documento_id,
            src.asignacion, src.referencia, src.documento_ventas, src.posicion,
            src.fecha_contabilizacion, src.fecha_documento, src.fecha_registro_sistema, src.fecha_compensacion,
            src.documento_compensacion, src.ejercicio_compensacion, src.clase_documento, src.codigo_impuesto, src.debe_haber,
            src.clave_contabilizacion,
            src.fecha_vencimiento, src.monto_moneda_local,
            src.monto_moneda_doc, src.moneda, src.condicion_pago, src.dias_plazo, src.sgtxt,
            src.factura_referencia_documento, src.factura_referencia_ejercicio, src.factura_referencia_posicion,
            src.area_reclamacion, src.nivel_reclamacion, src.clave_reclamacion_legal,
            src.bloqueo_reclamacion_temporal, src.fecha_ultima_reclamacion
        );
        SET @rows = @@ROWCOUNT;
        EXEC control.log_step @proc, @step, @t, @rows;

        -- --------------------------------------------------------------------
        -- silver.sap_bkpf: document headers, merge by posting date
        -- A reversal rewrites documento_reversa on the ORIGINAL document, so matched
        -- rows update it. A reversal more than a month after its original leaves it
        -- stale here.
        -- --------------------------------------------------------------------
        SET @step = 'silver.sap_bkpf merge'; SET @t = SYSDATETIME();

        MERGE silver.sap_bkpf AS tgt
        USING (
            SELECT
                LTRIM(RTRIM(MANDT)) AS mandante,
                LTRIM(RTRIM(BUKRS)) AS sociedad,
                GJAHR AS ejercicio,
                LTRIM(RTRIM(BELNR)) AS documento_id,
                NULLIF(LTRIM(RTRIM(BLART)), '') AS clase_documento,
                TRY_CONVERT(DATE, NULLIF(LTRIM(RTRIM(BLDAT)), '00000000'), 112) AS fecha_documento,
                TRY_CONVERT(DATE, NULLIF(LTRIM(RTRIM(BUDAT)), '00000000'), 112) AS fecha_contabilizacion,
                TRY_CONVERT(DATE, NULLIF(LTRIM(RTRIM(CPUDT)), '00000000'), 112) AS fecha_registro_sistema,
                NULLIF(LTRIM(RTRIM(MONAT)), '') AS mes,
                NULLIF(LTRIM(RTRIM(USNAM)), '') AS usuario,
                NULLIF(LTRIM(RTRIM(TCODE)), '') AS transaccion,
                NULLIF(LTRIM(RTRIM(XBLNR)), '') AS referencia,
                NULLIF(LTRIM(RTRIM(BKTXT)), '') AS texto_cabecera,
                NULLIF(LTRIM(RTRIM(STBLG)), '') AS documento_reversa,
                TRY_CAST(NULLIF(LTRIM(RTRIM(STJAH)), '') AS INT) AS ejercicio_reversa,
                NULLIF(LTRIM(RTRIM(STGRD)), '') AS motivo_reversa,
                NULLIF(LTRIM(RTRIM(XREVERSAL)), '') AS indicador_reversa,
                NULLIF(LTRIM(RTRIM(WAERS)), '') AS moneda
            FROM bronze.sap_bkpf WITH (NOLOCK)
            WHERE MANDT = '400'
              AND BUDAT >= @mes_anterior_inicio_str
        ) AS src
        ON  tgt.mandante = src.mandante
        AND tgt.sociedad = src.sociedad
        AND tgt.ejercicio = src.ejercicio
        AND tgt.documento_id = src.documento_id

        WHEN MATCHED THEN UPDATE SET
            tgt.documento_reversa = src.documento_reversa,
            tgt.ejercicio_reversa = src.ejercicio_reversa,
            tgt.motivo_reversa    = src.motivo_reversa,
            tgt.indicador_reversa = src.indicador_reversa,
            tgt.texto_cabecera    = src.texto_cabecera,
            tgt.fecha_carga       = GETDATE()

        WHEN NOT MATCHED THEN
        INSERT (
            mandante, sociedad, ejercicio, documento_id, clase_documento,
            fecha_documento, fecha_contabilizacion, fecha_registro_sistema, mes,
            usuario, transaccion, referencia, texto_cabecera,
            documento_reversa, ejercicio_reversa, motivo_reversa, indicador_reversa, moneda
        )
        VALUES (
            src.mandante, src.sociedad, src.ejercicio, src.documento_id, src.clase_documento,
            src.fecha_documento, src.fecha_contabilizacion, src.fecha_registro_sistema, src.mes,
            src.usuario, src.transaccion, src.referencia, src.texto_cabecera,
            src.documento_reversa, src.ejercicio_reversa, src.motivo_reversa, src.indicador_reversa, src.moneda
        );
        SET @rows = @@ROWCOUNT;
        EXEC control.log_step @proc, @step, @t, @rows;

        -- --------------------------------------------------------------------
        -- silver.sap_bsas: cleared G/L lines, merge by clearing date
        -- AUGDT and not BUDAT: a line enters BSAS when it is cleared and keeps its
        -- old posting date. Key columns are CAST to the silver type so the ON does
        -- not convert the target column.
        -- --------------------------------------------------------------------
        SET @step = 'silver.sap_bsas merge'; SET @t = SYSDATETIME();

        MERGE silver.sap_bsas AS tgt
        USING (
            SELECT
                CAST(LTRIM(RTRIM(MANDT)) AS VARCHAR(3))                          AS mandante,
                CAST(LTRIM(RTRIM(BUKRS)) AS VARCHAR(4))                          AS sociedad,
                CAST(LTRIM(RTRIM(HKONT)) AS VARCHAR(10))                         AS cuenta_mayor,
                CAST(GJAHR AS INT)                                               AS ejercicio,
                CAST(LTRIM(RTRIM(BELNR)) AS VARCHAR(10))                         AS documento_id,
                CAST(BUZEI AS INT)                                               AS posicion,
                NULLIF(LTRIM(RTRIM(MONAT)), '')                                  AS mes,
                NULLIF(LTRIM(RTRIM(BLART)), '')                                  AS clase_documento,
                TRY_CONVERT(DATE, NULLIF(LTRIM(RTRIM(BUDAT)), '00000000'), 112)  AS fecha_contabilizacion,
                TRY_CONVERT(DATE, NULLIF(LTRIM(RTRIM(BLDAT)), '00000000'), 112)  AS fecha_documento,
                TRY_CONVERT(DATE, NULLIF(LTRIM(RTRIM(VALUT)), '00000000'), 112)  AS fecha_valor,
                NULLIF(LTRIM(RTRIM(SHKZG)), '')                                  AS debe_haber,
                ISNULL(DMBTR, 0)                                                 AS monto_moneda_local,
                ISNULL(WRBTR, 0)                                                 AS monto_moneda_doc,
                NULLIF(LTRIM(RTRIM(WAERS)), '')                                  AS moneda,
                NULLIF(LTRIM(RTRIM(ZUONR)), '')                                  AS asignacion,
                NULLIF(LTRIM(RTRIM(XBLNR)), '')                                  AS referencia,
                NULLIF(LTRIM(RTRIM(SGTXT)), '')                                  AS sgtxt,
                TRY_CONVERT(DATE, NULLIF(LTRIM(RTRIM(AUGDT)), '00000000'), 112)  AS fecha_compensacion,
                NULLIF(LTRIM(RTRIM(AUGBL)), '')                                  AS documento_compensacion,
                TRY_CAST(NULLIF(NULLIF(LTRIM(RTRIM(AUGGJ)), ''), '0000') AS INT) AS ejercicio_compensacion,
                NULLIF(LTRIM(RTRIM(XOPVW)), '')                                  AS indicador_partidas_abiertas,
                NULLIF(LTRIM(RTRIM(XRAGL)), '')                                  AS indicador_compensacion_revertida
            FROM bronze.sap_bsas WITH (NOLOCK)
            WHERE MANDT = '400'
              AND AUGDT >= @mes_anterior_inicio_str
        ) AS src
        ON  tgt.mandante = src.mandante
        AND tgt.sociedad = src.sociedad
        AND tgt.cuenta_mayor = src.cuenta_mayor
        AND tgt.ejercicio = src.ejercicio
        AND tgt.documento_id = src.documento_id
        AND tgt.posicion = src.posicion

        WHEN MATCHED THEN UPDATE SET
            tgt.fecha_compensacion = src.fecha_compensacion,
            tgt.documento_compensacion = src.documento_compensacion,
            tgt.ejercicio_compensacion = src.ejercicio_compensacion,
            tgt.asignacion = src.asignacion,
            tgt.sgtxt = src.sgtxt,
            tgt.indicador_compensacion_revertida = src.indicador_compensacion_revertida,
            tgt.fecha_carga = GETDATE()

        WHEN NOT MATCHED THEN
        INSERT (
            mandante, sociedad, cuenta_mayor, ejercicio, documento_id, posicion, mes,
            clase_documento, fecha_contabilizacion, fecha_documento, fecha_valor,
            debe_haber, monto_moneda_local, monto_moneda_doc, moneda, asignacion,
            referencia, sgtxt, fecha_compensacion, documento_compensacion,
            ejercicio_compensacion, indicador_partidas_abiertas,
            indicador_compensacion_revertida
        )
        VALUES (
            src.mandante, src.sociedad, src.cuenta_mayor, src.ejercicio, src.documento_id,
            src.posicion, src.mes, src.clase_documento, src.fecha_contabilizacion,
            src.fecha_documento, src.fecha_valor, src.debe_haber, src.monto_moneda_local,
            src.monto_moneda_doc, src.moneda, src.asignacion, src.referencia, src.sgtxt,
            src.fecha_compensacion, src.documento_compensacion, src.ejercicio_compensacion,
            src.indicador_partidas_abiertas, src.indicador_compensacion_revertida
        );
        SET @rows = @@ROWCOUNT;
        EXEC control.log_step @proc, @step, @t, @rows;

        -- --------------------------------------------------------------------
        -- silver.sap_bsis: open G/L lines, two steps
        -- a) Accounts that never clear: their lines never leave BSIS, merge on BUDAT.
        -- b) Open-item accounts (XOPVW = 'X'): a line leaves BSIS the day it is
        --    cleared, so they are reloaded whole, in a transaction.
        -- --------------------------------------------------------------------
        SET @step = 'silver.sap_bsis a: merge, accounts that never clear'; SET @t = SYSDATETIME();

        MERGE silver.sap_bsis AS tgt
        USING (
            SELECT
                CAST(LTRIM(RTRIM(MANDT)) AS VARCHAR(3))                          AS mandante,
                CAST(LTRIM(RTRIM(BUKRS)) AS VARCHAR(4))                          AS sociedad,
                CAST(LTRIM(RTRIM(HKONT)) AS VARCHAR(10))                         AS cuenta_mayor,
                CAST(GJAHR AS INT)                                               AS ejercicio,
                CAST(LTRIM(RTRIM(BELNR)) AS VARCHAR(10))                         AS documento_id,
                CAST(BUZEI AS INT)                                               AS posicion,
                NULLIF(LTRIM(RTRIM(MONAT)), '')                                  AS mes,
                NULLIF(LTRIM(RTRIM(BLART)), '')                                  AS clase_documento,
                TRY_CONVERT(DATE, NULLIF(LTRIM(RTRIM(BUDAT)), '00000000'), 112)  AS fecha_contabilizacion,
                TRY_CONVERT(DATE, NULLIF(LTRIM(RTRIM(BLDAT)), '00000000'), 112)  AS fecha_documento,
                TRY_CONVERT(DATE, NULLIF(LTRIM(RTRIM(VALUT)), '00000000'), 112)  AS fecha_valor,
                NULLIF(LTRIM(RTRIM(SHKZG)), '')                                  AS debe_haber,
                ISNULL(DMBTR, 0)                                                 AS monto_moneda_local,
                ISNULL(WRBTR, 0)                                                 AS monto_moneda_doc,
                NULLIF(LTRIM(RTRIM(WAERS)), '')                                  AS moneda,
                NULLIF(LTRIM(RTRIM(ZUONR)), '')                                  AS asignacion,
                NULLIF(LTRIM(RTRIM(XBLNR)), '')                                  AS referencia,
                NULLIF(LTRIM(RTRIM(SGTXT)), '')                                  AS sgtxt,
                TRY_CONVERT(DATE, NULLIF(LTRIM(RTRIM(AUGDT)), '00000000'), 112)  AS fecha_compensacion,
                NULLIF(LTRIM(RTRIM(AUGBL)), '')                                  AS documento_compensacion,
                TRY_CAST(NULLIF(NULLIF(LTRIM(RTRIM(AUGGJ)), ''), '0000') AS INT) AS ejercicio_compensacion,
                NULLIF(LTRIM(RTRIM(XOPVW)), '')                                  AS indicador_partidas_abiertas,
                NULLIF(LTRIM(RTRIM(XRAGL)), '')                                  AS indicador_compensacion_revertida
            FROM bronze.sap_bsis WITH (NOLOCK)
            WHERE MANDT = '400'
              AND BUDAT >= @mes_anterior_inicio_str
              AND ISNULL(XOPVW, '') <> 'X'
        ) AS src
        ON  tgt.mandante = src.mandante
        AND tgt.sociedad = src.sociedad
        AND tgt.cuenta_mayor = src.cuenta_mayor
        AND tgt.ejercicio = src.ejercicio
        AND tgt.documento_id = src.documento_id
        AND tgt.posicion = src.posicion

        WHEN MATCHED THEN UPDATE SET
            tgt.asignacion = src.asignacion,
            tgt.referencia = src.referencia,
            tgt.sgtxt = src.sgtxt,
            tgt.fecha_carga = GETDATE()

        WHEN NOT MATCHED THEN
        INSERT (
            mandante, sociedad, cuenta_mayor, ejercicio, documento_id, posicion, mes,
            clase_documento, fecha_contabilizacion, fecha_documento, fecha_valor,
            debe_haber, monto_moneda_local, monto_moneda_doc, moneda, asignacion,
            referencia, sgtxt, fecha_compensacion, documento_compensacion,
            ejercicio_compensacion, indicador_partidas_abiertas,
            indicador_compensacion_revertida
        )
        VALUES (
            src.mandante, src.sociedad, src.cuenta_mayor, src.ejercicio, src.documento_id,
            src.posicion, src.mes, src.clase_documento, src.fecha_contabilizacion,
            src.fecha_documento, src.fecha_valor, src.debe_haber, src.monto_moneda_local,
            src.monto_moneda_doc, src.moneda, src.asignacion, src.referencia, src.sgtxt,
            src.fecha_compensacion, src.documento_compensacion, src.ejercicio_compensacion,
            src.indicador_partidas_abiertas, src.indicador_compensacion_revertida
        );
        SET @rows = @@ROWCOUNT;
        EXEC control.log_step @proc, @step, @t, @rows;

        SET @step = 'silver.sap_bsis b: full, open-item accounts'; SET @t = SYSDATETIME();

        BEGIN TRANSACTION;

        DELETE FROM silver.sap_bsis WHERE indicador_partidas_abiertas = 'X';

        INSERT INTO silver.sap_bsis (
            mandante, sociedad, cuenta_mayor, ejercicio, documento_id, posicion, mes,
            clase_documento, fecha_contabilizacion, fecha_documento, fecha_valor,
            debe_haber, monto_moneda_local, monto_moneda_doc, moneda, asignacion,
            referencia, sgtxt, fecha_compensacion, documento_compensacion,
            ejercicio_compensacion, indicador_partidas_abiertas,
            indicador_compensacion_revertida
        )
        SELECT
            CAST(LTRIM(RTRIM(MANDT)) AS VARCHAR(3))                          AS mandante,
            CAST(LTRIM(RTRIM(BUKRS)) AS VARCHAR(4))                          AS sociedad,
            CAST(LTRIM(RTRIM(HKONT)) AS VARCHAR(10))                         AS cuenta_mayor,
            CAST(GJAHR AS INT)                                               AS ejercicio,
            CAST(LTRIM(RTRIM(BELNR)) AS VARCHAR(10))                         AS documento_id,
            CAST(BUZEI AS INT)                                               AS posicion,
            NULLIF(LTRIM(RTRIM(MONAT)), '')                                  AS mes,
            NULLIF(LTRIM(RTRIM(BLART)), '')                                  AS clase_documento,
            TRY_CONVERT(DATE, NULLIF(LTRIM(RTRIM(BUDAT)), '00000000'), 112)  AS fecha_contabilizacion,
            TRY_CONVERT(DATE, NULLIF(LTRIM(RTRIM(BLDAT)), '00000000'), 112)  AS fecha_documento,
            TRY_CONVERT(DATE, NULLIF(LTRIM(RTRIM(VALUT)), '00000000'), 112)  AS fecha_valor,
            NULLIF(LTRIM(RTRIM(SHKZG)), '')                                  AS debe_haber,
            ISNULL(DMBTR, 0)                                                 AS monto_moneda_local,
            ISNULL(WRBTR, 0)                                                 AS monto_moneda_doc,
            NULLIF(LTRIM(RTRIM(WAERS)), '')                                  AS moneda,
            NULLIF(LTRIM(RTRIM(ZUONR)), '')                                  AS asignacion,
            NULLIF(LTRIM(RTRIM(XBLNR)), '')                                  AS referencia,
            NULLIF(LTRIM(RTRIM(SGTXT)), '')                                  AS sgtxt,
            TRY_CONVERT(DATE, NULLIF(LTRIM(RTRIM(AUGDT)), '00000000'), 112)  AS fecha_compensacion,
            NULLIF(LTRIM(RTRIM(AUGBL)), '')                                  AS documento_compensacion,
            TRY_CAST(NULLIF(NULLIF(LTRIM(RTRIM(AUGGJ)), ''), '0000') AS INT) AS ejercicio_compensacion,
            NULLIF(LTRIM(RTRIM(XOPVW)), '')                                  AS indicador_partidas_abiertas,
            NULLIF(LTRIM(RTRIM(XRAGL)), '')                                  AS indicador_compensacion_revertida
        FROM bronze.sap_bsis WITH (NOLOCK)
        WHERE MANDT = '400'
          AND XOPVW = 'X';
        SET @rows = @@ROWCOUNT;

        COMMIT TRANSACTION;
        EXEC control.log_step @proc, @step, @t, @rows;

        -- --------------------------------------------------------------------
        -- A line whose clearing was reset is back in BSIS. BSIS is the current
        -- truth for those accounts, so the stale cleared copy leaves BSAS.
        -- --------------------------------------------------------------------
        SET @step = 'silver.sap_bsas delete lines open again'; SET @t = SYSDATETIME();

        DELETE a
        FROM silver.sap_bsas a
        WHERE EXISTS (
            SELECT 1 FROM silver.sap_bsis i
            WHERE i.mandante = a.mandante
              AND i.sociedad = a.sociedad
              AND i.cuenta_mayor = a.cuenta_mayor
              AND i.ejercicio = a.ejercicio
              AND i.documento_id = a.documento_id
              AND i.posicion = a.posicion
        );
        SET @rows = @@ROWCOUNT;
        EXEC control.log_step @proc, @step, @t, @rows;

        -- --------------------------------------------------------------------
        -- silver.sap_knb1: company code data
        -- --------------------------------------------------------------------
        SET @step = 'silver.sap_knb1 full'; SET @t = SYSDATETIME();

        TRUNCATE TABLE silver.sap_knb1;

        INSERT INTO silver.sap_knb1 (
            mandante, sociedad, cliente_id, fecha_creacion, usuario_creacion,
            cuenta_mayor, clave_orden_partidas, grupo_planificacion_tesoreria,
            condicion_pago, indicador_intereses, fecha_ultima_liquidacion_intereses,
            flag_borrado, bloqueo_contabilizacion, grupo_autorizacion, pais_fiscal,
            flag_compensacion_acreedor, cuenta_anterior,
            cuenta_pagador_alterno, banco_propio, vias_pago, flag_compensacion_cliente_proveedor
        )
        SELECT
            LTRIM(RTRIM(MANDT)),
            LTRIM(RTRIM(BUKRS)),
            CAST(CAST(NULLIF(LTRIM(RTRIM(KUNNR)), '') AS BIGINT) AS VARCHAR(10)),
            TRY_CONVERT(DATE, NULLIF(LTRIM(RTRIM(ERDAT)), '00000000'), 112),
            NULLIF(LTRIM(RTRIM(ERNAM)), ''),
            NULLIF(LTRIM(RTRIM(AKONT)), ''),
            NULLIF(LTRIM(RTRIM(ZUAWA)), ''),
            NULLIF(LTRIM(RTRIM(FDGRV)), ''),
            NULLIF(LTRIM(RTRIM(ZTERM)), ''),
            NULLIF(LTRIM(RTRIM(VZSKZ)), ''),
            TRY_CONVERT(DATE, NULLIF(LTRIM(RTRIM(ZINDT)), '00000000'), 112),
            NULLIF(LTRIM(RTRIM(LOEVM)), ''),
            NULLIF(LTRIM(RTRIM(SPERR)), ''),
            NULLIF(LTRIM(RTRIM(BEGRU)), ''),
            NULLIF(LTRIM(RTRIM(QLAND)), ''),
            NULLIF(LTRIM(RTRIM(XAUSZ)), ''),
            NULLIF(LTRIM(RTRIM(ALTKN)), ''),
            NULLIF(LTRIM(RTRIM(KNRZE)), ''),
            NULLIF(LTRIM(RTRIM(HBKID)), ''),
            NULLIF(LTRIM(RTRIM(ZWELS)), ''),
            CASE WHEN LTRIM(RTRIM(XZVER)) = 'X' THEN 1 ELSE 0 END
        FROM bronze.sap_knb1 WITH (NOLOCK)
        WHERE MANDT = '400'
          AND LTRIM(RTRIM(LOEVM)) <> 'X';   -- not flagged for deletion
        SET @rows = @@ROWCOUNT;
        EXEC control.log_step @proc, @step, @t, @rows;

        -- --------------------------------------------------------------------
        -- silver.sap_knb5: dunning data
        -- --------------------------------------------------------------------
        SET @step = 'silver.sap_knb5 full'; SET @t = SYSDATETIME();

        TRUNCATE TABLE silver.sap_knb5;

        INSERT INTO silver.sap_knb5 (
            mandante, cliente_id, sociedad, area_reclamacion,
            procedimiento_reclamacion, bloqueo_reclamacion, fecha_ultima_reclamacion
        )
        SELECT
            LTRIM(RTRIM(MANDT)),
            CAST(CAST(NULLIF(LTRIM(RTRIM(KUNNR)), '') AS BIGINT) AS VARCHAR(10)),
            LTRIM(RTRIM(BUKRS)),
            LTRIM(RTRIM(MABER)),
            NULLIF(LTRIM(RTRIM(MAHNA)), ''),
            NULLIF(LTRIM(RTRIM(MAHNS)), ''),
            TRY_CONVERT(DATE, NULLIF(LTRIM(RTRIM(MADAT)), '00000000'), 112)
        FROM bronze.sap_knb5 WITH (NOLOCK)
        WHERE MANDT = '400';
        SET @rows = @@ROWCOUNT;
        EXEC control.log_step @proc, @step, @t, @rows;

        -- --------------------------------------------------------------------
        -- silver.sap_pa0001: employees, current record
        -- The ENDDA filter excludes nothing today; it is there in case SAP starts
        -- end-dating old records.
        -- --------------------------------------------------------------------
        SET @step = 'silver.sap_pa0001 full'; SET @t = SYSDATETIME();

        TRUNCATE TABLE silver.sap_pa0001;

        INSERT INTO silver.sap_pa0001 (mandante, id_empleado, nombre)
        SELECT
            LTRIM(RTRIM(MANDT)),
            LTRIM(RTRIM(PERNR)),
            NULLIF(LTRIM(RTRIM(ENAME)), '')
        FROM bronze.sap_pa0001 WITH (NOLOCK)
        WHERE MANDT = '400'
          AND LTRIM(RTRIM(ENDDA)) = '99991231';
        SET @rows = @@ROWCOUNT;
        EXEC control.log_step @proc, @step, @t, @rows;

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
