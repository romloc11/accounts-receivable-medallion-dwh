


CREATE OR ALTER PROCEDURE silver.load_silver
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @start_time DATETIME, @end_time DATETIME;

    -- ==========================================
    -- 1. LIMPIEZA: KNA1 (Clientes)
    -- ==========================================
    BEGIN TRY
        SET @start_time = GETDATE();
        PRINT '>> Cargando y limpiando silver.sap_kna1...';

        TRUNCATE TABLE silver.sap_kna1;

        INSERT INTO silver.sap_kna1 (
            
        )
        SELECT 
            TRIM(MANDT), -- mandante
            TRIM(KUNNR), --clave cliente
            TRIM(STCD1), -- rfc
            TRIM(NAME1), -- nombre
            TRIM(NAME2), --nombre 2 (cuando es muy largo)
            TRIM(LAND1), -- pais
            TRIM(REGIO), -- estado abreviado
            TRIM(ORT01), -- ciudad
            TRIM(PSTLZ), -- codigo postal
            TRIM(STRAS), -- calle y numero
            TRIM(AUFSD), --bloqueo de pedido
            TRIM(SORTL), -- regimen fiscal
            TRIM(TELF1), -- telefono
            TRIM(TELF2), --telefono extra
            TRIM(TELFX), -- whatsapp
            TRY_CONVERT(DATE, NULLIF(TRIM(ERDAT), '00000000'), 112), --Fecha de Alta
            TRIM(KTOKD), -- clave grupo de ventas
            TRIM(XCPDK), --flag cliente ocacional
            TRIM(STKZN), -- flag persona fisica 
            TRIM(STKZU), -- flag sujeto a iva 
            TRIM(KTR1), -- Tipo de servicio paq1
            TRIM(KTR2), -- Tipo de servicio paq2
            TRIM(KTR3), -- Tipo de servicio paq3
            TRIM(KTR6), --tiempo de entrega paq1
            TRIM(KTR7), --tiempo de entrega paq2
            TRIM(KTR8) --tiempo de entrega paq3

        FROM bronze.sap_kna1 WITH (NOLOCK)
        WHERE MANDT = '400';

        SET @end_time = GETDATE();
        PRINT 'Duration: ' + CAST(DATEDIFF(SECOND, @start_time, @end_time) AS NVARCHAR) + ' s';
    END TRY
    BEGIN CATCH
        THROW;
    END CATCH;

    -- ==========================================
    -- 2. LIMPIEZA: KNVP (Interlocutores)
    -- ==========================================
    BEGIN TRY
        SET @start_time = GETDATE();
        PRINT '>> Cargando y limpiando silver.sap_knvp...';

        TRUNCATE TABLE silver.sap_knvp;

        INSERT INTO silver.sap_knvp (
            mandante, cliente_id, organizacion_ventas, canal_distribucion,
            sector, funcion_interlocutor, interlocutor_id
        )
        SELECT 
            TRIM(MANDT), -- mandante
            TRIM(KUNNR), -- codigo cliente
            TRIM(KUNN2), --codigos alternos
            TRIM(VKORG), -- sociedad
            TRIM(VTWEG), -- canal
            TRIM(SPART), -- sector
            TRIM(PARVW), -- tipo interlocutor
            TRIM(KUNN2), --cliente hijo
            TRIM(PARZA), -- contador
            TRIM(PERNR), -- id interlocutor
            TRIM(LIFNR), -- id_paqueteria
            TRIM(DEFPA) -- flag defecto (preferencia)
        FROM bronze.sap_knvp WITH (NOLOCK);

        SET @end_time = GETDATE();
        PRINT 'Duration: ' + CAST(DATEDIFF(SECOND, @start_time, @end_time) AS NVARCHAR) + ' s';
    END TRY
    BEGIN CATCH
        THROW;
    END CATCH;

    -- ==========================================
    -- 3. LIMPIEZA: KNKK (Límites de Crédito)
    -- ==========================================
    BEGIN TRY
        SET @start_time = GETDATE();
        PRINT '>> Cargando y limpiando silver.sap_knkk...';

        TRUNCATE TABLE silver.sap_knkk;

        INSERT INTO silver.sap_knkk (
            mandante, cliente_id, area_control_credito, limite_credito,
            saldo_mantenido, moneda, bloqueado_credito
        )
        SELECT 
            TRIM(MANDT), -- mandante
            TRIM(KUNNR), -- codigo cliente
            TRIM(KNKLI), -- codigo padre
            TRIM(KKBER), -- sociedad
            ISNULL(KLIMK, 0), --limite de credito
            ISNULL(SKFOR, 0), -- monto de facturas abiertas 
            ISNULL(SAUFT, 0), -- monto de pedidos aun no facturados
            ISNULL(SSOBL, 0), -- especiales/pagares
            TRIM(UEDAT), --fecha ultima revision limite credito
            TRIM(ERNAM), --usuario que creo el registro de credito en sap
            TRIM(ERDAT), -- fecha en la que se creo el registro de credito en sap
            TRIM(CTLPC), --prioridad
            TRIM(CRBLB), --Bloqueo de pedido temporal
            TRIM(NXTRV), -- fecha de proxima revision limite de credito
            TRIM(KRAUS), -- etiqueta creditoc, contadoloc, etc
            TRIM(SBGRT), --investigacion cliente (revisar si cuenta con propiedades)
            TRIM(REVDB), --fecha que se cambio a credito o a contado
            TRIM(AEDAT), -- fecha de ultima modicacion en datos de credito de cliente
            TRIM(AENAM), -- persona que hizo la ultima modificacion en datos de credito de cliente
            TRIM(SBDAT), -- fecha proxima verificacion (se vence el pagare)
            TRIM(KDGRP), -- pagare, contrato, negativa, etc
            TRIM(CASHD), -- fecha de ultimo pago 
            TRIM(CASHA), -- monto del ultimo pago
            TRIM(CASHC), -- tipo de moneda de ultimo pago
            TRIM(DBRTG), -- ADN
        FROM bronze.sap_knkk WITH (NOLOCK);

        SET @end_time = GETDATE();
        PRINT 'Duration: ' + CAST(DATEDIFF(SECOND, @start_time, @end_time) AS NVARCHAR) + ' s';
    END TRY
    BEGIN CATCH
        THROW;
    END CATCH;



-- ==========================================
    -- LIMPIEZA Y CARGA: KNVV (Ventas por Cliente)
    -- ==========================================
    BEGIN TRY
        SET @start_time = GETDATE();
        PRINT '>> Cargando y limpiando silver.sap_knvv...';

        TRUNCATE TABLE silver.sap_knvv;

        INSERT INTO silver.sap_knvv (
            mandante,
            cliente_id,
            organizacion_ventas,
            canal_distribucion,
            sector,
            oficina_ventas,
            grupo_ventas,
            distrito_ventas,
            centro_suministrador,
            grupo_clientes,
            esquema_precios,
            grupo_condiciones,
            clasificacion_abc,
            condicion_pago,
            moneda,
            area_control_credito,
            bloqueo_entrega,
            bloqueo_factura,
            bloqueo_pedido,
            peticion_borrado,
            fecha_creacion,
            creado_por
        )
        SELECT 
            TRIM(MANDT) AS mandante, --mandante
            TRIM(KUNNR) AS cliente_id, -- id cliente
            TRIM(VKORG) AS organizacion_ventas, -- organizacion de ventas
            TRIM(VTWEG) AS canal_distribucion, -- canal
            TRIM(SPART) AS sector, -- sector
            TRIM(VKBUR) AS oficina_ventas, -- oficina de ventas
            TRIM(VKGRP) AS grupo_vendedores, -- grupo vendedores
            TRIM(BZIRK) AS region, --region
            TRIM(KGR1) AS ruta, --codigo sap de la ruta
            TRIM(VWERK) AS centro_suministrador, -- centro suministrador
            TRIM(KDGRP) AS grupo_clientes, -- grupo de clientes
            TRIM(KONDA) AS grupo_precios, -- grupo preciosa
            TRIM(PLTYP) AS lista_precios, -- lista preciosa
            TRIM(INCO1) AS  incoterm, -- incoterm codigo
            TRIM(INCO2) AS incoterm_descripcion, --incoterm_descripcion
            TRIM(ANTLF) AS entregas_parciales_max, -- entregas parciales maximas
            TRIM(LPRIO) AS prioridad_entrega, -- prioridad entrrga
            TRIM(ZTERM) AS condicion_pago, --condicion pago
            TRIM(WAERS) AS moneda, --moneda
            TRIM(KVGR2) AS tiempo_entrega, -- tiempo de entrega
            TRIM(KVGR3) AS tipo_servicio, --tipo de servicio paqueteria
            TRIM(KVGR4) AS tipo_servicio_2, -- tipo de servicio paqueteria 2
            TRIM(LIFSD) AS bloqueo_entrega, --bloqueo de entrega
            TRIM(FAKSD) AS bloqueo_factura, -- bloqueo de facturacion
            TRIM(AUFSD) AS bloqueo_pedido, -- bloqueo de pedido
            
            TRY_CONVERT(DATE, NULLIF(TRIM(ERDAT), '00000000'), 112) AS fecha_creacion,
            TRIM(ERNAM) AS creado_por
        FROM bronze.sap_knvv WITH (NOLOCK);

        SET @end_time = GETDATE();
        PRINT 'Duration: ' + CAST(DATEDIFF(SECOND, @start_time, @end_time) AS NVARCHAR) + ' s';
    END TRY
    BEGIN CATCH
        THROW;
    END CATCH;


    -- ==========================================
    -- 4. LIMPIEZA: BSID (Partidas Abiertas)
    -- ==========================================
    BEGIN TRY
        SET @start_time = GETDATE();
        PRINT '>> Cargando y limpiando silver.sap_bsid...';

        TRUNCATE TABLE silver.sap_bsid;

        INSERT INTO silver.sap_bsid (
            mandante, sociedad, cliente_id, ejercicio, documento_id, posicion,
            fecha_contabilizacion, fecha_documento, fecha_vencimiento,
            clase_documento, monto_moneda_local, monto_moneda_doc, moneda,
            asignacion, condicion_pago
        )
        SELECT 
            TRIM(MANDT),
            TRIM(BUKRS),
            TRIM(KUNNR),
            GJAHR,
            TRIM(BELNR),
            BUZEI,
            TRY_CONVERT(DATE, NULLIF(TRIM(BUDAT), '00000000'), 112),
            TRY_CONVERT(DATE, NULLIF(TRIM(BLDAT), '00000000'), 112),
            TRY_CONVERT(DATE, NULLIF(TRIM(ZFBDT), '00000000'), 112),
            TRIM(BLART),
            ISNULL(DMBTR, 0),
            ISNULL(WRBTR, 0),
            TRIM(WAERS),
            TRIM(ZUONR),
            TRIM(ZTERM)
        FROM bronze.sap_bsid WITH (NOLOCK);

        SET @end_time = GETDATE();
        PRINT 'Duration: ' + CAST(DATEDIFF(SECOND, @start_time, @end_time) AS NVARCHAR) + ' s';
    END TRY
    BEGIN CATCH
        THROW;
    END CATCH;

    -- ==========================================
    -- 5. LIMPIEZA: BSAD (Partidas Compensadas)
    -- ==========================================
    BEGIN TRY
        SET @start_time = GETDATE();
        PRINT '>> Cargando y limpiando silver.sap_bsad (Merge Incremental)...';

        -- Definimos ventana de refresco para Silver (mes actual + mes anterior)
        DECLARE @mes_anterior_inicio DATE = DATEADD(MONTH, DATEDIFF(MONTH, 0, GETDATE()) - 1, 0);

        MERGE silver.sap_bsad AS tgt
        USING (
            SELECT 
                TRIM(MANDT) AS mandante,
                TRIM(BUKRS) AS sociedad,
                TRIM(KUNNR) AS cliente_id,
                GJAHR AS ejercicio,
                TRIM(BELNR) AS documento_id,
                BUZEI AS posicion,
                TRY_CONVERT(DATE, NULLIF(TRIM(BUDAT), '00000000'), 112) AS fecha_contabilizacion,
                TRY_CONVERT(DATE, NULLIF(TRIM(BLDAT), '00000000'), 112) AS fecha_documento,
                TRY_CONVERT(DATE, NULLIF(TRIM(AUGDT), '00000000'), 112) AS fecha_compensacion,
                TRIM(AUGBL) AS documento_compensacion,
                TRIM(BLART) AS clase_documento,
                ISNULL(DMBTR, 0) AS monto_moneda_local,
                ISNULL(WRBTR, 0) AS monto_moneda_doc,
                TRIM(WAERS) AS moneda,
                TRIM(ZTERM) AS condicion_pago
            FROM bronze.sap_bsad WITH (NOLOCK)
            WHERE TRY_CONVERT(DATE, NULLIF(TRIM(AUGDT), '00000000'), 112) >= @mes_anterior_inicio
        ) AS src
        ON  tgt.mandante = src.mandante
        AND tgt.sociedad = src.sociedad
        AND tgt.cliente_id = src.cliente_id
        AND tgt.ejercicio = src.ejercicio
        AND tgt.documento_id = src.documento_id
        AND tgt.posicion = src.posicion
        AND tgt.fecha_compensacion >= @mes_anterior_inicio

        WHEN MATCHED THEN UPDATE SET
            tgt.fecha_compensacion = src.fecha_compensacion,
            tgt.documento_compensacion = src.documento_compensacion,
            tgt.monto_moneda_local = src.monto_moneda_local,
            tgt.monto_moneda_doc = src.monto_moneda_doc,
            tgt.condicion_pago = src.condicion_pago,
            tgt.fecha_carga = GETDATE()

        WHEN NOT MATCHED THEN
        INSERT (
            mandante, sociedad, cliente_id, ejercicio, documento_id, posicion,
            fecha_contabilizacion, fecha_documento, fecha_compensacion,
            documento_compensacion, clase_documento, monto_moneda_local,
            monto_moneda_doc, moneda, condicion_pago
        )
        VALUES (
            src.mandante, src.sociedad, src.cliente_id, src.ejercicio, src.documento_id, src.posicion,
            src.fecha_contabilizacion, src.fecha_documento, src.fecha_compensacion,
            src.documento_compensacion, src.clase_documento, src.monto_moneda_local,
            src.monto_moneda_doc, src.moneda, src.condicion_pago
        );

        SET @end_time = GETDATE();
        PRINT 'Duration: ' + CAST(DATEDIFF(SECOND, @start_time, @end_time) AS NVARCHAR) + ' s';
    END TRY
    BEGIN CATCH
        THROW;
    END CATCH;

END;
GO
