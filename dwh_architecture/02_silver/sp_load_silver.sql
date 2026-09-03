USE ANALISIS_DATOS;
GO

/*
===============================================================================
PROJECT: Enterprise Data Warehouse (dwh-ciosa)
LAYER: Silver (Clean Data Staging)

COMPATIBILITY NOTE:
TRIM() doesn't exist before SQL Server 2017 / Azure SQL. All whitespace
cleanup in this procedure uses LTRIM(RTRIM(...)) instead, which is
equivalent and compatible with any SQL Server version.

Date fields in SAP arrive as 8-digit text (YYYYMMDD, e.g. '20260702') or
'00000000' when there's no value. They're converted with
TRY_CONVERT(DATE, NULLIF(LTRIM(RTRIM(field)), '00000000'), 112).

NOTE ON AUDITING: this procedure no longer calls control.sp_log_load.
Confirmed in bronze.load_bronze that calling that proc from INSIDE another
procedure breaks compilation on this SQL Server 2012 instance (see
ddl_bronze.sql, section 10, and sp_load_bronze.sql). silver.load_silver
originally called sp_log_load 16 times (TRY+CATCH x 8 tables) without
anyone having confirmed whether that compiled or not; it was removed
preemptively for the same reason, without waiting for it to fail in
production. control.sap_load_control is therefore also not populated from
here - the only trace of each run is the PRINT output (rows loaded +
duration) visible while it executes. THROW is still active in every CATCH,
so a real failure still propagates to whoever called the procedure.
===============================================================================
*/

IF OBJECT_ID('silver.load_silver', 'P') IS NOT NULL
    DROP PROCEDURE silver.load_silver;
GO

CREATE PROCEDURE silver.load_silver
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @start_time DATETIME, @end_time DATETIME, @rows_count INT;

    -- ==========================================
    -- 1. CLEANING: KNA1 (Customers)
    -- ==========================================
    BEGIN TRY
        SET @start_time = GETDATE();
        PRINT '>> Loading and cleaning silver.sap_kna1...';

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
            LTRIM(RTRIM(MANDT)),  -- client (SAP mandante)
            CAST(CAST(NULLIF(LTRIM(RTRIM(KUNNR)), '') AS BIGINT) AS VARCHAR(10)),  -- customer key (no leading zeros)
            NULLIF(LTRIM(RTRIM(STCD1)), ''),  -- rfc
            NULLIF(LTRIM(RTRIM(NAME1)), ''),  -- name
            NULLIF(LTRIM(RTRIM(NAME2)), ''),  -- name 2 (when too long)
            NULLIF(LTRIM(RTRIM(LAND1)), ''),  -- country
            NULLIF(LTRIM(RTRIM(REGIO)), ''),  -- state abbreviation
            NULLIF(LTRIM(RTRIM(ORT01)), ''),  -- city
            NULLIF(LTRIM(RTRIM(PSTLZ)), ''),  -- postal code
            NULLIF(LTRIM(RTRIM(STRAS)), ''),  -- street and number
            NULLIF(LTRIM(RTRIM(AUFSD)), ''),  -- order block
            NULLIF(LTRIM(RTRIM(SORTL)), ''),  -- tax regime
            NULLIF(LTRIM(RTRIM(TELF1)), ''),  -- phone
            NULLIF(LTRIM(RTRIM(TELF2)), ''),  -- extra phone
            NULLIF(LTRIM(RTRIM(TELFX)), ''),  -- whatsapp
            TRY_CONVERT(DATE, NULLIF(LTRIM(RTRIM(ERDAT)), '00000000'), 112), -- creation date
            NULLIF(LTRIM(RTRIM(KTOKD)), ''),  -- account group code
            NULLIF(LTRIM(RTRIM(LIFNR)), ''),  -- linked vendor
            CASE WHEN LTRIM(RTRIM(SPERR)) = 'X' THEN 1 ELSE 0 END,  -- blocked flag
            CASE WHEN LTRIM(RTRIM(XCPDK)) = 'X' THEN 1 ELSE 0 END,  -- one-time customer flag
            CASE WHEN LTRIM(RTRIM(STKZN)) = 'X' THEN 1 ELSE 0 END,  -- individual (natural person) flag
            CASE WHEN LTRIM(RTRIM(STKZU)) = 'X' THEN 1 ELSE 0 END,  -- VAT-liable flag
            NULLIF(LTRIM(RTRIM(KATR1)), ''),  -- carrier service type 1
            NULLIF(LTRIM(RTRIM(KATR2)), ''),  -- carrier service type 2
            NULLIF(LTRIM(RTRIM(KATR3)), ''),  -- carrier service type 3
            NULLIF(LTRIM(RTRIM(KATR6)), ''),  -- carrier delivery time 1
            NULLIF(LTRIM(RTRIM(KATR7)), ''),  -- carrier delivery time 2
            NULLIF(LTRIM(RTRIM(KATR8)), '')   -- carrier delivery time 3
        FROM bronze.sap_kna1 WITH (NOLOCK)
        WHERE MANDT = '400'
          AND LTRIM(RTRIM(LOEVM)) <> 'X';  -- excludes customers flagged for deletion in SAP
        SET @rows_count = @@ROWCOUNT;

        SET @end_time = GETDATE();
        PRINT 'Rows: ' + CAST(@rows_count AS NVARCHAR) + ' | Duration: ' + CAST(DATEDIFF(SECOND, @start_time, @end_time) AS NVARCHAR) + ' s';
    END TRY
    BEGIN CATCH
        PRINT 'ERROR in silver.sap_kna1: ' + ERROR_MESSAGE();
        THROW;
    END CATCH;

    -- ==========================================
    -- 2. CLEANING: KNVP (Partner Functions)
    -- ==========================================
    BEGIN TRY
        SET @start_time = GETDATE();
        PRINT '>> Loading and cleaning silver.sap_knvp...';

        TRUNCATE TABLE silver.sap_knvp;

        INSERT INTO silver.sap_knvp (
            mandante, cliente_id, organizacion_ventas, canal_distribucion,
            sector, funcion_interlocutor, descripcion_funcion, contador,
            cliente_asociado, id_interlocutor, nombre_interlocutor, id_paqueteria, flag_default
        )
        SELECT
            LTRIM(RTRIM(p.MANDT)),  -- client (SAP mandante)
            CAST(CAST(NULLIF(LTRIM(RTRIM(p.KUNNR)), '') AS BIGINT) AS VARCHAR(10)),  -- customer code (no leading zeros)
            LTRIM(RTRIM(p.VKORG)),  -- sales organization
            LTRIM(RTRIM(p.VTWEG)),  -- distribution channel
            LTRIM(RTRIM(p.SPART)),  -- sector
            LTRIM(RTRIM(p.PARVW)),  -- partner function
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
            END,  -- descripcion_funcion (confirmed business catalog; Spanish business labels kept as-is, they're report-facing data)
            LTRIM(RTRIM(p.PARZA)),  -- counter (completes the PK together with funcion_interlocutor)
            CAST(CAST(NULLIF(LTRIM(RTRIM(p.KUNN2)), '') AS BIGINT) AS VARCHAR(10)),  -- associated/child customer (no leading zeros)
            NULLIF(LTRIM(RTRIM(p.PERNR)), ''),  -- partner id
            NULLIF(LTRIM(RTRIM(e.ENAME)), ''),  -- partner's real name (resolved via bronze.sap_pa0001, only applies to roles that are employees)
            NULLIF(LTRIM(RTRIM(p.LIFNR)), ''),  -- carrier id
            CASE WHEN LTRIM(RTRIM(p.DEFPA)) = 'X' THEN 1 ELSE 0 END  -- default flag (preference)
        FROM bronze.sap_knvp p WITH (NOLOCK)
        LEFT JOIN bronze.sap_pa0001 e WITH (NOLOCK)
            ON e.MANDT = p.MANDT AND e.PERNR = p.PERNR AND e.ENDDA = '99991231'
        WHERE p.MANDT = '400'
          AND LTRIM(RTRIM(p.VKORG)) = '2000';  -- real sales organization (2000=316,085 rows vs 4000=800, noise/test)
        SET @rows_count = @@ROWCOUNT;

        SET @end_time = GETDATE();
        PRINT 'Rows: ' + CAST(@rows_count AS NVARCHAR) + ' | Duration: ' + CAST(DATEDIFF(SECOND, @start_time, @end_time) AS NVARCHAR) + ' s';
    END TRY
    BEGIN CATCH
        PRINT 'ERROR in silver.sap_knvp: ' + ERROR_MESSAGE();
        THROW;
    END CATCH;

    -- ==========================================
    -- 3. CLEANING: KNKK (Credit Limits)
    -- ==========================================
    BEGIN TRY
        SET @start_time = GETDATE();
        PRINT '>> Loading and cleaning silver.sap_knkk...';

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
            LTRIM(RTRIM(MANDT)),  -- client (SAP mandante)
            CAST(CAST(NULLIF(LTRIM(RTRIM(KUNNR)), '') AS BIGINT) AS VARCHAR(10)),  -- customer code (no leading zeros)
            CAST(CAST(NULLIF(LTRIM(RTRIM(KNKLI)), '') AS BIGINT) AS VARCHAR(10)),  -- parent code (no leading zeros)
            LTRIM(RTRIM(KKBER)),  -- credit control area
            ISNULL(KLIMK, 0),     -- credit limit
            ISNULL(SKFOR, 0),     -- open invoices amount
            ISNULL(SAUFT, 0),     -- amount of orders not yet invoiced
            ISNULL(SSOBL, 0),     -- specials/promissory notes
            TRY_CONVERT(DATE, NULLIF(LTRIM(RTRIM(UEDAT)), '00000000'), 112), -- date of last credit-limit review
            NULLIF(LTRIM(RTRIM(ERNAM)), ''),  -- user who created the credit record in SAP
            TRY_CONVERT(DATE, NULLIF(LTRIM(RTRIM(ERDAT)), '00000000'), 112), -- date the credit record was created in SAP
            NULLIF(LTRIM(RTRIM(CTLPC)), ''),  -- priority
            NULLIF(LTRIM(RTRIM(CRBLB)), ''),  -- temporary order block
            TRY_CONVERT(DATE, NULLIF(LTRIM(RTRIM(NXTRV)), '00000000'), 112), -- date of next credit-limit review
            NULLIF(LTRIM(RTRIM(KRAUS)), ''),  -- credit/cash tag, etc.
            NULLIF(LTRIM(RTRIM(SBGRP)), ''),  -- credit officers group
            TRY_CONVERT(DATE, NULLIF(LTRIM(RTRIM(REVDB)), '00000000'), 112), -- date it switched to credit or to cash
            TRY_CONVERT(DATE, NULLIF(LTRIM(RTRIM(AEDAT)), '00000000'), 112), -- date of last modification to the customer's credit data
            NULLIF(LTRIM(RTRIM(AENAM)), ''),  -- person who made the last modification to the customer's credit data
            TRY_CONVERT(DATE, NULLIF(LTRIM(RTRIM(SBDAT)), '00000000'), 112), -- next verification date (the promissory note comes due)
            NULLIF(LTRIM(RTRIM(KDGRP)), ''),  -- promissory note, contract, refusal, etc.
            TRY_CONVERT(DATE, NULLIF(LTRIM(RTRIM(CASHD)), '00000000'), 112), -- last payment date
            ISNULL(CASHA, 0),     -- last payment amount
            NULLIF(LTRIM(RTRIM(CASHC)), ''),  -- last payment currency type
            NULLIF(LTRIM(RTRIM(DBRTG)), ''),  -- risk classification (D&B)
            TRY_CONVERT(DATE, NULLIF(LTRIM(RTRIM(AETXT)), '00000000'), 112), -- date of last modification to the record's text (promissory-note tracking, among other uses)
            NULLIF(LTRIM(RTRIM(GRUPP)), ''),  -- special credit group/status
            NULLIF(LTRIM(RTRIM(DBPAY)), ''),  -- D&B payment indicator
            NULLIF(DBEKR, 0)      -- D&B recommended credit limit
        FROM bronze.sap_knkk WITH (NOLOCK)
        WHERE MANDT = '400'
          AND LTRIM(RTRIM(KKBER)) = '2000';  -- real credit control area (2000=23,788 rows vs 1000=14/0001=1, noise/test)
        SET @rows_count = @@ROWCOUNT;

        SET @end_time = GETDATE();
        PRINT 'Rows: ' + CAST(@rows_count AS NVARCHAR) + ' | Duration: ' + CAST(DATEDIFF(SECOND, @start_time, @end_time) AS NVARCHAR) + ' s';
    END TRY
    BEGIN CATCH
        PRINT 'ERROR in silver.sap_knkk: ' + ERROR_MESSAGE();
        THROW;
    END CATCH;

    -- ==========================================
    -- 4. CLEANING AND LOAD: KNVV (Customer Sales)
    -- ==========================================
    BEGIN TRY
        SET @start_time = GETDATE();
        PRINT '>> Loading and cleaning silver.sap_knvv...';

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
            LTRIM(RTRIM(v.MANDT)),   -- client (SAP mandante)
            CAST(CAST(NULLIF(LTRIM(RTRIM(v.KUNNR)), '') AS BIGINT) AS VARCHAR(10)),   -- customer id (no leading zeros)
            LTRIM(RTRIM(v.VKORG)),   -- sales organization
            LTRIM(RTRIM(v.VTWEG)),   -- channel
            LTRIM(RTRIM(v.SPART)),   -- sector
            NULLIF(LTRIM(RTRIM(v.VKBUR)), ''),   -- sales office
            NULLIF(LTRIM(RTRIM(v.VKGRP)), ''),   -- salesperson group
            NULLIF(LTRIM(RTRIM(v.BZIRK)), ''),   -- region
            NULLIF(LTRIM(RTRIM(v.KVGR1)), ''),   -- SAP route code
            NULLIF(LTRIM(RTRIM(t.BEZEI)), ''),  -- route's real name (resolved via bronze.sap_tvv1t)
            NULLIF(LTRIM(RTRIM(v.VWERK)), ''),   -- supplying plant
            NULLIF(LTRIM(RTRIM(v.KDGRP)), ''),   -- customer group
            NULLIF(LTRIM(RTRIM(v.KONDA)), ''),   -- price group
            NULLIF(LTRIM(RTRIM(v.PLTYP)), ''),   -- price list
            NULLIF(LTRIM(RTRIM(v.INCO1)), ''),   -- incoterm code
            NULLIF(LTRIM(RTRIM(v.INCO2)), ''),   -- incoterm description
            v.ANTLF,                 -- maximum partial deliveries
            NULLIF(LTRIM(RTRIM(v.LPRIO)), ''),   -- delivery priority
            NULLIF(LTRIM(RTRIM(v.KVGR2)), ''),   -- delivery time
            NULLIF(LTRIM(RTRIM(v.KVGR3)), ''),   -- carrier service type
            NULLIF(LTRIM(RTRIM(v.KVGR4)), ''),   -- carrier service type 2
            CASE WHEN LEN(LTRIM(RTRIM(v.VSBED))) = 1 THEN '0' + LTRIM(RTRIM(v.VSBED)) ELSE NULLIF(LTRIM(RTRIM(v.VSBED)), '') END, -- shipping condition (normalized to 2 digits)
            NULLIF(LTRIM(RTRIM(v.ZTERM)), ''),   -- payment terms
            NULLIF(LTRIM(RTRIM(v.WAERS)), ''),   -- currency
            NULLIF(LTRIM(RTRIM(v.LIFSD)), ''),   -- delivery block
            NULLIF(LTRIM(RTRIM(v.FAKSD)), ''),   -- billing block
            NULLIF(LTRIM(RTRIM(v.AUFSD)), ''),   -- order block
            NULLIF(LTRIM(RTRIM(v.CASSD)), ''),  -- dunning contact block (sales area)
            TRY_CONVERT(DATE, NULLIF(LTRIM(RTRIM(v.ERDAT)), '00000000'), 112), -- creation date
            NULLIF(LTRIM(RTRIM(v.ERNAM)), '')    -- created by
        FROM bronze.sap_knvv v WITH (NOLOCK)
        LEFT JOIN bronze.sap_tvv1t t WITH (NOLOCK)
            ON t.MANDT = v.MANDT AND t.SPRAS = 'S' AND t.KVGR1 = v.KVGR1
        WHERE v.MANDT = '400'
          AND LTRIM(RTRIM(v.LOEVM)) <> 'X'  -- excludes sales areas flagged for deletion in SAP
          AND LTRIM(RTRIM(v.VKORG)) = '2000';  -- real sales organization (2000=29,114 rows vs 4000=185, noise/test)
        SET @rows_count = @@ROWCOUNT;

        SET @end_time = GETDATE();
        PRINT 'Rows: ' + CAST(@rows_count AS NVARCHAR) + ' | Duration: ' + CAST(DATEDIFF(SECOND, @start_time, @end_time) AS NVARCHAR) + ' s';
    END TRY
    BEGIN CATCH
        PRINT 'ERROR in silver.sap_knvv: ' + ERROR_MESSAGE();
        THROW;
    END CATCH;

    -- ==========================================
    -- 5. CLEANING: BSID (Open Items)
    -- ==========================================
    BEGIN TRY
        SET @start_time = GETDATE();
        PRINT '>> Loading and cleaning silver.sap_bsid...';

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
            bloqueo_reclamacion_temporal, fecha_ultima_reclamacion
        )
        SELECT
            LTRIM(RTRIM(MANDT)),  -- client (SAP mandante)
            LTRIM(RTRIM(BUKRS)),  -- company code
            CAST(CAST(NULLIF(LTRIM(RTRIM(KUNNR)), '') AS BIGINT) AS VARCHAR(10)),  -- customer id (no leading zeros)
            GJAHR,                -- document fiscal year
            NULLIF(LTRIM(RTRIM(MONAT)), ''),  -- document month
            LTRIM(RTRIM(BELNR)),  -- uncleared document id
            NULLIF(LTRIM(RTRIM(ZUONR)), ''),  -- id of the document it originated from (applies to credit notes)
            NULLIF(LTRIM(RTRIM(XBLNR)), ''),  -- reference id
            NULLIF(LTRIM(RTRIM(VBELN)), ''),  -- sales document (SD)
            BUZEI,                -- BELNR line count
            TRY_CONVERT(DATE, NULLIF(LTRIM(RTRIM(BUDAT)), '00000000'), 112), -- posting date
            TRY_CONVERT(DATE, NULLIF(LTRIM(RTRIM(BLDAT)), '00000000'), 112), -- document date
            TRY_CONVERT(DATE, NULLIF(LTRIM(RTRIM(CPUDT)), '00000000'), 112), -- system entry date
            DATEADD(DAY, ISNULL(ZBD1T, 0), TRY_CONVERT(DATE, NULLIF(LTRIM(RTRIM(ZFBDT)), '00000000'), 112)), -- real due date = ZFBDT (discount base date) + dias_plazo, NOT ZFBDT alone (bug fixed 2026-08-13, confirmed against SAP: ZFBDT=13.05.2026 + 30-day term = real due date 12.06.2026)
            NULLIF(LTRIM(RTRIM(BLART)), ''),  -- document type (dz, f4, c1, etc.)
            NULLIF(LTRIM(RTRIM(MWSKZ)), ''),  -- tax code (VAT)
            NULLIF(LTRIM(RTRIM(SHKZG)), ''),  -- debit or credit
            ISNULL(DMBTR, 0),     -- amount in local currency
            ISNULL(WRBTR, 0),     -- amount in original currency
            NULLIF(LTRIM(RTRIM(WAERS)), ''),  -- currency
            NULLIF(LTRIM(RTRIM(ZTERM)), ''),  -- payment terms
            ISNULL(ZBD1T, 0),     -- term days
            NULLIF(LTRIM(RTRIM(BSCHL)), ''),  -- posting key (added 2026-09-03, fact_aplicacion v2 - see ddl_silver.sql)
            NULLIF(LTRIM(RTRIM(SGTXT)), ''),  -- line item text
            NULLIF(LTRIM(RTRIM(REBZG)), ''),  -- invoice reference ('V' = no reference, kept raw here, interpreted in gold)
            TRY_CAST(NULLIF(LTRIM(RTRIM(REBZJ)), '') AS INT),
            TRY_CAST(NULLIF(LTRIM(RTRIM(REBZZ)), '') AS INT),
            NULLIF(LTRIM(RTRIM(MABER)), ''),  -- dunning area
            NULLIF(LTRIM(RTRIM(MANST)), ''),  -- dunning level
            NULLIF(LTRIM(RTRIM(MSCHL)), ''),  -- legal dunning key
            NULLIF(LTRIM(RTRIM(MANSP)), ''),  -- temporary dunning block
            TRY_CONVERT(DATE, NULLIF(LTRIM(RTRIM(MADAT)), '00000000'), 112) -- date of the last dunning notice
        FROM bronze.sap_bsid WITH (NOLOCK)
        WHERE MANDT = '400';
        SET @rows_count = @@ROWCOUNT;

        SET @end_time = GETDATE();
        PRINT 'Rows: ' + CAST(@rows_count AS NVARCHAR) + ' | Duration: ' + CAST(DATEDIFF(SECOND, @start_time, @end_time) AS NVARCHAR) + ' s';
    END TRY
    BEGIN CATCH
        PRINT 'ERROR in silver.sap_bsid: ' + ERROR_MESSAGE();
        THROW;
    END CATCH;

    -- ==========================================
    -- 6. CLEANING: BSAD (Cleared Items)
    -- ==========================================
    BEGIN TRY
        SET @start_time = GETDATE();
        PRINT '>> Loading and cleaning silver.sap_bsad (Incremental Merge)...';

        -- Set the refresh window for Silver (current month + previous month)
        DECLARE @mes_anterior_inicio DATE = DATEADD(MONTH, DATEDIFF(MONTH, 0, GETDATE()) - 1, 0);
        -- Text version 'YYYYMMDD' to be able to compare against AUGDT (NVARCHAR in bronze)
        -- without wrapping the column in a function: wrapping AUGDT in TRY_CONVERT() in the
        -- WHERE makes it non-sargable (forces the function to be evaluated row by row, with
        -- no index usable on AUGDT), the same issue already fixed in bronze.sap_bsad's MERGE.
        DECLARE @mes_anterior_inicio_str NVARCHAR(8) = CONVERT(NVARCHAR(8), @mes_anterior_inicio, 112);

        MERGE silver.sap_bsad AS tgt
        USING (
            SELECT
                LTRIM(RTRIM(MANDT)) AS mandante,
                LTRIM(RTRIM(BUKRS)) AS sociedad,
                CAST(CAST(NULLIF(LTRIM(RTRIM(KUNNR)), '') AS BIGINT) AS VARCHAR(10)) AS cliente_id,  -- no leading zeros
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
                NULLIF(LTRIM(RTRIM(BSCHL)), '') AS clave_contabilizacion, -- posting key (added 2026-09-03, fact_aplicacion v2 - see ddl_silver.sql)
                DATEADD(DAY, ISNULL(ZBD1T, 0), TRY_CONVERT(DATE, NULLIF(LTRIM(RTRIM(ZFBDT)), '00000000'), 112)) AS fecha_vencimiento, -- real due date = ZFBDT + dias_plazo (bug fixed 2026-08-13, see the note in the bsid step above)
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
        ON  tgt.mandante = src.mandante
        AND tgt.sociedad = src.sociedad
        AND tgt.cliente_id = src.cliente_id
        AND tgt.ejercicio = src.ejercicio
        AND tgt.documento_id = src.documento_id
        AND tgt.posicion = src.posicion
        -- tgt.fecha_compensacion is NOT filtered here (bug fixed 2026-08-13): if the
        -- primary key matches, it's the same line regardless of what fecha_compensacion
        -- it has stored. With that condition in the ON, a line that SAP reversed and
        -- re-cleared (old fecha_compensacion in the target, new AUGDT in bronze because
        -- bronze doesn't keep history) was treated as "no match" and the MERGE tried a
        -- duplicate INSERT instead of updating the existing row - violating the PK. Real
        -- case: document 7404597470/pos.1, originally cleared 2026-04-07 (doc.
        -- 8501526715), reversed and re-cleared 2026-08-03 (doc. 1402639643). The window
        -- filter already lives in the src's WHERE (AUGDT >= @mes_anterior_inicio_str) -
        -- no need to repeat it in the ON.

        WHEN MATCHED THEN UPDATE SET
            tgt.fecha_compensacion = src.fecha_compensacion,
            tgt.documento_compensacion = src.documento_compensacion,
            tgt.ejercicio_compensacion = src.ejercicio_compensacion,
            tgt.clave_contabilizacion = src.clave_contabilizacion, -- immutable in SAP; updated here only so rows inside the window get populated right after the 2026-09-03 ALTER without waiting for the backfill
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
        SET @rows_count = @@ROWCOUNT;

        SET @end_time = GETDATE();
        PRINT 'Rows: ' + CAST(@rows_count AS NVARCHAR) + ' | Duration: ' + CAST(DATEDIFF(SECOND, @start_time, @end_time) AS NVARCHAR) + ' s';
    END TRY
    BEGIN CATCH
        PRINT 'ERROR in silver.sap_bsad: ' + ERROR_MESSAGE();
        THROW;
    END CATCH;

    -- ==========================================
    -- 7. CLEANING: KNB1 (Customer Company Code Data)
    -- ==========================================
    BEGIN TRY
        SET @start_time = GETDATE();
        PRINT '>> Loading and cleaning silver.sap_knb1...';

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
            LTRIM(RTRIM(MANDT)),  -- client (SAP mandante)
            LTRIM(RTRIM(BUKRS)),  -- company code
            CAST(CAST(NULLIF(LTRIM(RTRIM(KUNNR)), '') AS BIGINT) AS VARCHAR(10)),  -- customer id (no leading zeros)
            TRY_CONVERT(DATE, NULLIF(LTRIM(RTRIM(ERDAT)), '00000000'), 112), -- creation date
            NULLIF(LTRIM(RTRIM(ERNAM)), ''),  -- creating user
            NULLIF(LTRIM(RTRIM(AKONT)), ''),  -- reconciliation account
            NULLIF(LTRIM(RTRIM(ZUAWA)), ''),  -- sort key for line items
            NULLIF(LTRIM(RTRIM(FDGRV)), ''),  -- treasury planning group
            NULLIF(LTRIM(RTRIM(ZTERM)), ''),  -- payment terms
            NULLIF(LTRIM(RTRIM(VZSKZ)), ''),  -- interest calculation indicator
            TRY_CONVERT(DATE, NULLIF(LTRIM(RTRIM(ZINDT)), '00000000'), 112), -- date of last interest settlement
            NULLIF(LTRIM(RTRIM(LOEVM)), ''),  -- deletion flag
            NULLIF(LTRIM(RTRIM(SPERR)), ''),  -- posting block
            NULLIF(LTRIM(RTRIM(BEGRU)), ''),  -- authorization group
            NULLIF(LTRIM(RTRIM(QLAND)), ''),  -- tax country
            NULLIF(LTRIM(RTRIM(XAUSZ)), ''),  -- vendor clearing flag
            NULLIF(LTRIM(RTRIM(ALTKN)), ''),  -- previous account
            NULLIF(LTRIM(RTRIM(KNRZE)), ''),  -- alternate payer account
            NULLIF(LTRIM(RTRIM(HBKID)), ''),  -- house bank
            NULLIF(LTRIM(RTRIM(ZWELS)), ''),  -- allowed payment methods
            CASE WHEN LTRIM(RTRIM(XZVER)) = 'X' THEN 1 ELSE 0 END  -- customer-vendor clearing flag
        FROM bronze.sap_knb1 WITH (NOLOCK)
        WHERE MANDT = '400'
          AND LTRIM(RTRIM(LOEVM)) <> 'X';  -- excludes records flagged for deletion in SAP
        SET @rows_count = @@ROWCOUNT;

        SET @end_time = GETDATE();
        PRINT 'Rows: ' + CAST(@rows_count AS NVARCHAR) + ' | Duration: ' + CAST(DATEDIFF(SECOND, @start_time, @end_time) AS NVARCHAR) + ' s';
    END TRY
    BEGIN CATCH
        PRINT 'ERROR in silver.sap_knb1: ' + ERROR_MESSAGE();
        THROW;
    END CATCH;

    -- ==========================================
    -- 8. CLEANING: KNB5 (Customer Dunning Data)
    -- ==========================================
    BEGIN TRY
        SET @start_time = GETDATE();
        PRINT '>> Loading and cleaning silver.sap_knb5...';

        TRUNCATE TABLE silver.sap_knb5;

        INSERT INTO silver.sap_knb5 (
            mandante, cliente_id, sociedad, area_reclamacion,
            procedimiento_reclamacion, bloqueo_reclamacion, fecha_ultima_reclamacion
        )
        SELECT
            LTRIM(RTRIM(MANDT)),  -- client (SAP mandante)
            CAST(CAST(NULLIF(LTRIM(RTRIM(KUNNR)), '') AS BIGINT) AS VARCHAR(10)),  -- customer id (no leading zeros)
            LTRIM(RTRIM(BUKRS)),  -- company code
            LTRIM(RTRIM(MABER)),  -- dunning area
            NULLIF(LTRIM(RTRIM(MAHNA)), ''),  -- dunning procedure
            NULLIF(LTRIM(RTRIM(MAHNS)), ''),  -- dunning block
            TRY_CONVERT(DATE, NULLIF(LTRIM(RTRIM(MADAT)), '00000000'), 112) -- date of the last dunning notice
        FROM bronze.sap_knb5 WITH (NOLOCK)
        WHERE MANDT = '400';
        SET @rows_count = @@ROWCOUNT;

        SET @end_time = GETDATE();
        PRINT 'Rows: ' + CAST(@rows_count AS NVARCHAR) + ' | Duration: ' + CAST(DATEDIFF(SECOND, @start_time, @end_time) AS NVARCHAR) + ' s';
    END TRY
    BEGIN CATCH
        PRINT 'ERROR in silver.sap_knb5: ' + ERROR_MESSAGE();
        THROW;
    END CATCH;

    -- ==========================================
    -- 9. CLEANING: PA0001 (Employee Master)
    -- ENDDA = '99991231' filter: confirmed 2026-08-27 to be a no-op on this
    -- extract (100% of rows already have it, 0 duplicate PERNR) - kept as a
    -- forward-looking safety net, not because it's actively filtering
    -- anything today. See the full note in ddl_silver.sql before touching
    -- this if a future load ever fails on the PK.
    -- ==========================================
    BEGIN TRY
        SET @start_time = GETDATE();
        PRINT '>> Loading and cleaning silver.sap_pa0001...';

        TRUNCATE TABLE silver.sap_pa0001;

        INSERT INTO silver.sap_pa0001 (mandante, id_empleado, nombre)
        SELECT
            LTRIM(RTRIM(MANDT)),        -- client (SAP mandante)
            LTRIM(RTRIM(PERNR)),        -- employee id (raw PERNR, not zero-stripped - matches silver.sap_knvp.id_interlocutor)
            NULLIF(LTRIM(RTRIM(ENAME)), '')  -- employee name
        FROM bronze.sap_pa0001 WITH (NOLOCK)
        WHERE MANDT = '400'
          AND LTRIM(RTRIM(ENDDA)) = '99991231';
        SET @rows_count = @@ROWCOUNT;

        SET @end_time = GETDATE();
        PRINT 'Rows: ' + CAST(@rows_count AS NVARCHAR) + ' | Duration: ' + CAST(DATEDIFF(SECOND, @start_time, @end_time) AS NVARCHAR) + ' s';
    END TRY
    BEGIN CATCH
        PRINT 'ERROR in silver.sap_pa0001: ' + ERROR_MESSAGE();
        THROW;
    END CATCH;

END;
GO
