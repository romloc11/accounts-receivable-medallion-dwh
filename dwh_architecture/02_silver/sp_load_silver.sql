USE ANALISIS_DATOS;
GO

/*
===============================================================================
PROJECT: Enterprise Data Warehouse (dwh-ciosa)
LAYER: Silver (Clean Data Staging)

NOTA DE COMPATIBILIDAD:
TRIM() no existe antes de SQL Server 2017 / Azure SQL. Todo el limpiado de
espacios en este procedimiento usa LTRIM(RTRIM(...)) en su lugar, que es
equivalente y compatible con cualquier version de SQL Server.

Los campos de fecha en SAP llegan como texto de 8 digitos (YYYYMMDD, ej.
'20260702') o '00000000' cuando no tienen valor. Se convierten con
TRY_CONVERT(DATE, NULLIF(LTRIM(RTRIM(campo)), '00000000'), 112).

NOTA SOBRE AUDITORIA: este procedimiento ya NO llama a control.sp_log_load.
Confirmado en bronze.load_bronze que llamar a ese proc desde DENTRO de otro
procedimiento rompe la compilacion en esta instancia de SQL Server 2012 (ver
ddl_bronze.sql, seccion 10, y sp_load_bronze.sql). silver.load_silver
originalmente llamaba a sp_log_load 16 veces (TRY+CATCH x 8 tablas) sin que
nadie hubiera confirmado si eso compilaba o no; se quito preventivamente por
el mismo motivo, sin esperar a que fallara en produccion. control.sap_load_control
por lo tanto tampoco se llena desde aqui - el unico rastro de cada corrida es
el PRINT (filas cargadas + duracion) visible mientras se ejecuta. THROW sigue
activo en cada CATCH, asi que un fallo real se sigue propagando a quien haya
llamado al procedimiento.
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
    -- 1. LIMPIEZA: KNA1 (Clientes)
    -- ==========================================
    BEGIN TRY
        SET @start_time = GETDATE();
        PRINT '>> Cargando y limpiando silver.sap_kna1...';

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
            LTRIM(RTRIM(MANDT)),  -- mandante
            CAST(CAST(NULLIF(LTRIM(RTRIM(KUNNR)), '') AS BIGINT) AS VARCHAR(10)),  -- clave cliente (sin ceros a la izquierda)
            NULLIF(LTRIM(RTRIM(STCD1)), ''),  -- rfc
            NULLIF(LTRIM(RTRIM(NAME1)), ''),  -- nombre
            NULLIF(LTRIM(RTRIM(NAME2)), ''),  -- nombre 2 (cuando es muy largo)
            NULLIF(LTRIM(RTRIM(LAND1)), ''),  -- pais
            NULLIF(LTRIM(RTRIM(REGIO)), ''),  -- estado abreviado
            NULLIF(LTRIM(RTRIM(ORT01)), ''),  -- ciudad
            NULLIF(LTRIM(RTRIM(PSTLZ)), ''),  -- codigo postal
            NULLIF(LTRIM(RTRIM(STRAS)), ''),  -- calle y numero
            NULLIF(LTRIM(RTRIM(AUFSD)), ''),  -- bloqueo de pedido
            NULLIF(LTRIM(RTRIM(SORTL)), ''),  -- regimen fiscal
            NULLIF(LTRIM(RTRIM(TELF1)), ''),  -- telefono
            NULLIF(LTRIM(RTRIM(TELF2)), ''),  -- telefono extra
            NULLIF(LTRIM(RTRIM(TELFX)), ''),  -- whatsapp
            TRY_CONVERT(DATE, NULLIF(LTRIM(RTRIM(ERDAT)), '00000000'), 112), -- fecha de alta
            NULLIF(LTRIM(RTRIM(KTOKD)), ''),  -- clave grupo de cuentas
            NULLIF(LTRIM(RTRIM(LIFNR)), ''),  -- proveedor vinculado
            CASE WHEN LTRIM(RTRIM(SPERR)) = 'X' THEN 1 ELSE 0 END,  -- flag bloqueado
            CASE WHEN LTRIM(RTRIM(XCPDK)) = 'X' THEN 1 ELSE 0 END,  -- flag cliente ocasional
            CASE WHEN LTRIM(RTRIM(STKZN)) = 'X' THEN 1 ELSE 0 END,  -- flag persona fisica
            CASE WHEN LTRIM(RTRIM(STKZU)) = 'X' THEN 1 ELSE 0 END,  -- flag sujeto a iva
            NULLIF(LTRIM(RTRIM(KATR1)), ''),  -- tipo de servicio paqueteria 1
            NULLIF(LTRIM(RTRIM(KATR2)), ''),  -- tipo de servicio paqueteria 2
            NULLIF(LTRIM(RTRIM(KATR3)), ''),  -- tipo de servicio paqueteria 3
            NULLIF(LTRIM(RTRIM(KATR6)), ''),  -- tiempo de entrega paqueteria 1
            NULLIF(LTRIM(RTRIM(KATR7)), ''),  -- tiempo de entrega paqueteria 2
            NULLIF(LTRIM(RTRIM(KATR8)), '')   -- tiempo de entrega paqueteria 3
        FROM bronze.sap_kna1 WITH (NOLOCK)
        WHERE MANDT = '400'
          AND LTRIM(RTRIM(LOEVM)) <> 'X';  -- excluye clientes marcados para borrado en SAP
        SET @rows_count = @@ROWCOUNT;

        SET @end_time = GETDATE();
        PRINT 'Filas: ' + CAST(@rows_count AS NVARCHAR) + ' | Duration: ' + CAST(DATEDIFF(SECOND, @start_time, @end_time) AS NVARCHAR) + ' s';
    END TRY
    BEGIN CATCH
        PRINT 'ERROR en silver.sap_kna1: ' + ERROR_MESSAGE();
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
            sector, funcion_interlocutor, descripcion_funcion, contador,
            cliente_asociado, id_interlocutor, nombre_interlocutor, id_paqueteria, flag_default
        )
        SELECT
            LTRIM(RTRIM(p.MANDT)),  -- mandante
            CAST(CAST(NULLIF(LTRIM(RTRIM(p.KUNNR)), '') AS BIGINT) AS VARCHAR(10)),  -- codigo cliente (sin ceros a la izquierda)
            LTRIM(RTRIM(p.VKORG)),  -- organizacion de ventas
            LTRIM(RTRIM(p.VTWEG)),  -- canal de distribucion
            LTRIM(RTRIM(p.SPART)),  -- sector
            LTRIM(RTRIM(p.PARVW)),  -- funcion de interlocutor
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
            END,  -- descripcion_funcion (catalogo de negocio confirmado)
            LTRIM(RTRIM(p.PARZA)),  -- contador (completa la PK junto con funcion_interlocutor)
            CAST(CAST(NULLIF(LTRIM(RTRIM(p.KUNN2)), '') AS BIGINT) AS VARCHAR(10)),  -- cliente asociado / hijo (sin ceros a la izquierda)
            NULLIF(LTRIM(RTRIM(p.PERNR)), ''),  -- id interlocutor
            NULLIF(LTRIM(RTRIM(e.ENAME)), ''),  -- nombre real del interlocutor (resuelto via bronze.sap_pa0001, solo aplica a roles que son empleados)
            NULLIF(LTRIM(RTRIM(p.LIFNR)), ''),  -- id paqueteria
            CASE WHEN LTRIM(RTRIM(p.DEFPA)) = 'X' THEN 1 ELSE 0 END  -- flag defecto (preferencia)
        FROM bronze.sap_knvp p WITH (NOLOCK)
        LEFT JOIN bronze.sap_pa0001 e WITH (NOLOCK)
            ON e.MANDT = p.MANDT AND e.PERNR = p.PERNR AND e.ENDDA = '99991231'
        WHERE p.MANDT = '400'
          AND LTRIM(RTRIM(p.VKORG)) = '2000';  -- organizacion de ventas real (2000=316,085 filas vs 4000=800, ruido/prueba)
        SET @rows_count = @@ROWCOUNT;

        SET @end_time = GETDATE();
        PRINT 'Filas: ' + CAST(@rows_count AS NVARCHAR) + ' | Duration: ' + CAST(DATEDIFF(SECOND, @start_time, @end_time) AS NVARCHAR) + ' s';
    END TRY
    BEGIN CATCH
        PRINT 'ERROR en silver.sap_knvp: ' + ERROR_MESSAGE();
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
            LTRIM(RTRIM(MANDT)),  -- mandante
            CAST(CAST(NULLIF(LTRIM(RTRIM(KUNNR)), '') AS BIGINT) AS VARCHAR(10)),  -- codigo cliente (sin ceros a la izquierda)
            CAST(CAST(NULLIF(LTRIM(RTRIM(KNKLI)), '') AS BIGINT) AS VARCHAR(10)),  -- codigo padre (sin ceros a la izquierda)
            LTRIM(RTRIM(KKBER)),  -- area de control de credito
            ISNULL(KLIMK, 0),     -- limite de credito
            ISNULL(SKFOR, 0),     -- monto de facturas abiertas
            ISNULL(SAUFT, 0),     -- monto de pedidos aun no facturados
            ISNULL(SSOBL, 0),     -- especiales/pagares
            TRY_CONVERT(DATE, NULLIF(LTRIM(RTRIM(UEDAT)), '00000000'), 112), -- fecha ultima revision limite credito
            NULLIF(LTRIM(RTRIM(ERNAM)), ''),  -- usuario que creo el registro de credito en sap
            TRY_CONVERT(DATE, NULLIF(LTRIM(RTRIM(ERDAT)), '00000000'), 112), -- fecha en la que se creo el registro de credito en sap
            NULLIF(LTRIM(RTRIM(CTLPC)), ''),  -- prioridad
            NULLIF(LTRIM(RTRIM(CRBLB)), ''),  -- bloqueo de pedido temporal
            TRY_CONVERT(DATE, NULLIF(LTRIM(RTRIM(NXTRV)), '00000000'), 112), -- fecha de proxima revision limite de credito
            NULLIF(LTRIM(RTRIM(KRAUS)), ''),  -- etiqueta credito, contado, etc
            NULLIF(LTRIM(RTRIM(SBGRP)), ''),  -- grupo de responsables de credito
            TRY_CONVERT(DATE, NULLIF(LTRIM(RTRIM(REVDB)), '00000000'), 112), -- fecha que se cambio a credito o a contado
            TRY_CONVERT(DATE, NULLIF(LTRIM(RTRIM(AEDAT)), '00000000'), 112), -- fecha de ultima modificacion en datos de credito de cliente
            NULLIF(LTRIM(RTRIM(AENAM)), ''),  -- persona que hizo la ultima modificacion en datos de credito de cliente
            TRY_CONVERT(DATE, NULLIF(LTRIM(RTRIM(SBDAT)), '00000000'), 112), -- fecha proxima verificacion (se vence el pagare)
            NULLIF(LTRIM(RTRIM(KDGRP)), ''),  -- pagare, contrato, negativa, etc
            TRY_CONVERT(DATE, NULLIF(LTRIM(RTRIM(CASHD)), '00000000'), 112), -- fecha de ultimo pago
            ISNULL(CASHA, 0),     -- monto del ultimo pago
            NULLIF(LTRIM(RTRIM(CASHC)), ''),  -- tipo de moneda de ultimo pago
            NULLIF(LTRIM(RTRIM(DBRTG)), ''),  -- clasificacion de riesgo (ADN)
            TRY_CONVERT(DATE, NULLIF(LTRIM(RTRIM(AETXT)), '00000000'), 112), -- fecha ultima modificacion del texto del registro (seguimiento de pagares, entre otros usos)
            NULLIF(LTRIM(RTRIM(GRUPP)), ''),  -- grupo/estado especial de credito
            NULLIF(LTRIM(RTRIM(DBPAY)), ''),  -- indicador de pago D&B
            NULLIF(DBEKR, 0)      -- limite de credito recomendado D&B
        FROM bronze.sap_knkk WITH (NOLOCK)
        WHERE MANDT = '400'
          AND LTRIM(RTRIM(KKBER)) = '2000';  -- area de control de credito real (2000=23,788 filas vs 1000=14/0001=1, ruido/prueba)
        SET @rows_count = @@ROWCOUNT;

        SET @end_time = GETDATE();
        PRINT 'Filas: ' + CAST(@rows_count AS NVARCHAR) + ' | Duration: ' + CAST(DATEDIFF(SECOND, @start_time, @end_time) AS NVARCHAR) + ' s';
    END TRY
    BEGIN CATCH
        PRINT 'ERROR en silver.sap_knkk: ' + ERROR_MESSAGE();
        THROW;
    END CATCH;

    -- ==========================================
    -- 4. LIMPIEZA Y CARGA: KNVV (Ventas por Cliente)
    -- ==========================================
    BEGIN TRY
        SET @start_time = GETDATE();
        PRINT '>> Cargando y limpiando silver.sap_knvv...';

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
            LTRIM(RTRIM(v.MANDT)),   -- mandante
            CAST(CAST(NULLIF(LTRIM(RTRIM(v.KUNNR)), '') AS BIGINT) AS VARCHAR(10)),   -- id cliente (sin ceros a la izquierda)
            LTRIM(RTRIM(v.VKORG)),   -- organizacion de ventas
            LTRIM(RTRIM(v.VTWEG)),   -- canal
            LTRIM(RTRIM(v.SPART)),   -- sector
            NULLIF(LTRIM(RTRIM(v.VKBUR)), ''),   -- oficina de ventas
            NULLIF(LTRIM(RTRIM(v.VKGRP)), ''),   -- grupo vendedores
            NULLIF(LTRIM(RTRIM(v.BZIRK)), ''),   -- region
            NULLIF(LTRIM(RTRIM(v.KVGR1)), ''),   -- codigo sap de la ruta
            NULLIF(LTRIM(RTRIM(t.BEZEI)), ''),  -- nombre real de la ruta (resuelto via bronze.sap_tvv1t)
            NULLIF(LTRIM(RTRIM(v.VWERK)), ''),   -- centro suministrador
            NULLIF(LTRIM(RTRIM(v.KDGRP)), ''),   -- grupo de clientes
            NULLIF(LTRIM(RTRIM(v.KONDA)), ''),   -- grupo de precios
            NULLIF(LTRIM(RTRIM(v.PLTYP)), ''),   -- lista de precios
            NULLIF(LTRIM(RTRIM(v.INCO1)), ''),   -- incoterm codigo
            NULLIF(LTRIM(RTRIM(v.INCO2)), ''),   -- incoterm descripcion
            v.ANTLF,                 -- entregas parciales maximas
            NULLIF(LTRIM(RTRIM(v.LPRIO)), ''),   -- prioridad entrega
            NULLIF(LTRIM(RTRIM(v.KVGR2)), ''),   -- tiempo de entrega
            NULLIF(LTRIM(RTRIM(v.KVGR3)), ''),   -- tipo de servicio paqueteria
            NULLIF(LTRIM(RTRIM(v.KVGR4)), ''),   -- tipo de servicio paqueteria 2
            CASE WHEN LEN(LTRIM(RTRIM(v.VSBED))) = 1 THEN '0' + LTRIM(RTRIM(v.VSBED)) ELSE NULLIF(LTRIM(RTRIM(v.VSBED)), '') END, -- condicion de expedicion (normalizada a 2 digitos)
            NULLIF(LTRIM(RTRIM(v.ZTERM)), ''),   -- condicion pago
            NULLIF(LTRIM(RTRIM(v.WAERS)), ''),   -- moneda
            NULLIF(LTRIM(RTRIM(v.LIFSD)), ''),   -- bloqueo de entrega
            NULLIF(LTRIM(RTRIM(v.FAKSD)), ''),   -- bloqueo de facturacion
            NULLIF(LTRIM(RTRIM(v.AUFSD)), ''),   -- bloqueo de pedido
            NULLIF(LTRIM(RTRIM(v.CASSD)), ''),  -- bloqueo de contacto para deudores (area de ventas)
            TRY_CONVERT(DATE, NULLIF(LTRIM(RTRIM(v.ERDAT)), '00000000'), 112), -- fecha de alta
            NULLIF(LTRIM(RTRIM(v.ERNAM)), '')    -- creado por
        FROM bronze.sap_knvv v WITH (NOLOCK)
        LEFT JOIN bronze.sap_tvv1t t WITH (NOLOCK)
            ON t.MANDT = v.MANDT AND t.SPRAS = 'S' AND t.KVGR1 = v.KVGR1
        WHERE v.MANDT = '400'
          AND LTRIM(RTRIM(v.LOEVM)) <> 'X'  -- excluye areas de venta marcadas para borrado en SAP
          AND LTRIM(RTRIM(v.VKORG)) = '2000';  -- organizacion de ventas real (2000=29,114 filas vs 4000=185, ruido/prueba)
        SET @rows_count = @@ROWCOUNT;

        SET @end_time = GETDATE();
        PRINT 'Filas: ' + CAST(@rows_count AS NVARCHAR) + ' | Duration: ' + CAST(DATEDIFF(SECOND, @start_time, @end_time) AS NVARCHAR) + ' s';
    END TRY
    BEGIN CATCH
        PRINT 'ERROR en silver.sap_knvv: ' + ERROR_MESSAGE();
        THROW;
    END CATCH;

    -- ==========================================
    -- 5. LIMPIEZA: BSID (Partidas Abiertas)
    -- ==========================================
    BEGIN TRY
        SET @start_time = GETDATE();
        PRINT '>> Cargando y limpiando silver.sap_bsid...';

        TRUNCATE TABLE silver.sap_bsid;

        INSERT INTO silver.sap_bsid (
            mandante, sociedad, cliente_id, ejercicio, mes, documento_id,
            asignacion, referencia, documento_ventas, posicion,
            fecha_contabilizacion, fecha_documento, fecha_registro_sistema, fecha_vencimiento,
            clase_documento, codigo_impuesto, debe_haber, monto_moneda_local, monto_moneda_doc,
            moneda, condicion_pago, dias_plazo,
            area_reclamacion, nivel_reclamacion, clave_reclamacion_legal,
            bloqueo_reclamacion_temporal, fecha_ultima_reclamacion
        )
        SELECT
            LTRIM(RTRIM(MANDT)),  -- mandante
            LTRIM(RTRIM(BUKRS)),  -- sociedad
            CAST(CAST(NULLIF(LTRIM(RTRIM(KUNNR)), '') AS BIGINT) AS VARCHAR(10)),  -- id cliente (sin ceros a la izquierda)
            GJAHR,                -- año del documento
            NULLIF(LTRIM(RTRIM(MONAT)), ''),  -- mes del documento
            LTRIM(RTRIM(BELNR)),  -- id del documento no compensado
            NULLIF(LTRIM(RTRIM(ZUONR)), ''),  -- id del documento de donde nacio (aplica para notas de credito)
            NULLIF(LTRIM(RTRIM(XBLNR)), ''),  -- id referencia
            NULLIF(LTRIM(RTRIM(VBELN)), ''),  -- documento de ventas (SD)
            BUZEI,                -- conteo de BELNR
            TRY_CONVERT(DATE, NULLIF(LTRIM(RTRIM(BUDAT)), '00000000'), 112), -- fecha contabilizacion
            TRY_CONVERT(DATE, NULLIF(LTRIM(RTRIM(BLDAT)), '00000000'), 112), -- fecha documento
            TRY_CONVERT(DATE, NULLIF(LTRIM(RTRIM(CPUDT)), '00000000'), 112), -- fecha registro sistema
            DATEADD(DAY, ISNULL(ZBD1T, 0), TRY_CONVERT(DATE, NULLIF(LTRIM(RTRIM(ZFBDT)), '00000000'), 112)), -- fecha vencimiento real = ZFBDT (fecha base de descuento) + dias_plazo, NO ZFBDT solo (bug corregido 2026-08-13, confirmado contra SAP: ZFBDT=13.05.2026 + 30 dias plazo = vencimiento real 12.06.2026)
            NULLIF(LTRIM(RTRIM(BLART)), ''),  -- tipo documento (dz, f4, c1, etc)
            NULLIF(LTRIM(RTRIM(MWSKZ)), ''),  -- codigo de impuesto (IVA)
            NULLIF(LTRIM(RTRIM(SHKZG)), ''),  -- debe o haber
            ISNULL(DMBTR, 0),     -- monto en moneda local
            ISNULL(WRBTR, 0),     -- monto en moneda original
            NULLIF(LTRIM(RTRIM(WAERS)), ''),  -- moneda
            NULLIF(LTRIM(RTRIM(ZTERM)), ''),  -- condicion de pago
            ISNULL(ZBD1T, 0),     -- dias plazo
            NULLIF(LTRIM(RTRIM(MABER)), ''),  -- area de reclamacion
            NULLIF(LTRIM(RTRIM(MANST)), ''),  -- nivel de reclamacion
            NULLIF(LTRIM(RTRIM(MSCHL)), ''),  -- clave de reclamacion legal
            NULLIF(LTRIM(RTRIM(MANSP)), ''),  -- bloqueo de reclamacion temporal
            TRY_CONVERT(DATE, NULLIF(LTRIM(RTRIM(MADAT)), '00000000'), 112) -- fecha de la ultima reclamacion
        FROM bronze.sap_bsid WITH (NOLOCK)
        WHERE MANDT = '400';
        SET @rows_count = @@ROWCOUNT;

        SET @end_time = GETDATE();
        PRINT 'Filas: ' + CAST(@rows_count AS NVARCHAR) + ' | Duration: ' + CAST(DATEDIFF(SECOND, @start_time, @end_time) AS NVARCHAR) + ' s';
    END TRY
    BEGIN CATCH
        PRINT 'ERROR en silver.sap_bsid: ' + ERROR_MESSAGE();
        THROW;
    END CATCH;

    -- ==========================================
    -- 6. LIMPIEZA: BSAD (Partidas Compensadas)
    -- ==========================================
    BEGIN TRY
        SET @start_time = GETDATE();
        PRINT '>> Cargando y limpiando silver.sap_bsad (Merge Incremental)...';

        -- Definimos ventana de refresco para Silver (mes actual + mes anterior)
        DECLARE @mes_anterior_inicio DATE = DATEADD(MONTH, DATEDIFF(MONTH, 0, GETDATE()) - 1, 0);
        -- Version en texto 'YYYYMMDD' para poder comparar contra AUGDT (NVARCHAR en bronze)
        -- sin envolver la columna en una funcion: envolver AUGDT en TRY_CONVERT() en el WHERE
        -- lo vuelve no-sargable (obliga a evaluar la funcion fila por fila, sin poder usar
        -- ningun indice sobre AUGDT), igual que ya se corrigio en el MERGE de bronze.sap_bsad.
        DECLARE @mes_anterior_inicio_str NVARCHAR(8) = CONVERT(NVARCHAR(8), @mes_anterior_inicio, 112);

        MERGE silver.sap_bsad AS tgt
        USING (
            SELECT
                LTRIM(RTRIM(MANDT)) AS mandante,
                LTRIM(RTRIM(BUKRS)) AS sociedad,
                CAST(CAST(NULLIF(LTRIM(RTRIM(KUNNR)), '') AS BIGINT) AS VARCHAR(10)) AS cliente_id,  -- sin ceros a la izquierda
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
                DATEADD(DAY, ISNULL(ZBD1T, 0), TRY_CONVERT(DATE, NULLIF(LTRIM(RTRIM(ZFBDT)), '00000000'), 112)) AS fecha_vencimiento, -- vencimiento real = ZFBDT + dias_plazo (bug corregido 2026-08-13, ver nota en el paso de bsid arriba)
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
        -- NO se filtra tgt.fecha_compensacion aqui (bug corregido 2026-08-13): si la
        -- llave primaria coincide, es la misma linea sin importar que fecha_compensacion
        -- tenga guardada. Con esa condicion en el ON, una linea reversada y vuelta a
        -- compensar por SAP (fecha_compensacion vieja en destino, AUGDT nuevo en bronze
        -- porque bronze no guarda historial) se trataba como "no coincide" y el MERGE
        -- intentaba un INSERT duplicado en vez de actualizar la fila existente - violando
        -- la PK. Caso real: documento 7404597470/pos.1, compensado originalmente
        -- 2026-04-07 (doc. 8501526715), reversado y recompensado 2026-08-03 (doc.
        -- 1402639643). El filtro de ventana ya vive en el WHERE del src (AUGDT >=
        -- @mes_anterior_inicio_str) - no hace falta repetirlo en el ON.

        WHEN MATCHED THEN UPDATE SET
            tgt.fecha_compensacion = src.fecha_compensacion,
            tgt.documento_compensacion = src.documento_compensacion,
            tgt.ejercicio_compensacion = src.ejercicio_compensacion,
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
            src.fecha_vencimiento, src.monto_moneda_local,
            src.monto_moneda_doc, src.moneda, src.condicion_pago, src.dias_plazo, src.sgtxt,
            src.factura_referencia_documento, src.factura_referencia_ejercicio, src.factura_referencia_posicion,
            src.area_reclamacion, src.nivel_reclamacion, src.clave_reclamacion_legal,
            src.bloqueo_reclamacion_temporal, src.fecha_ultima_reclamacion
        );
        SET @rows_count = @@ROWCOUNT;

        SET @end_time = GETDATE();
        PRINT 'Filas: ' + CAST(@rows_count AS NVARCHAR) + ' | Duration: ' + CAST(DATEDIFF(SECOND, @start_time, @end_time) AS NVARCHAR) + ' s';
    END TRY
    BEGIN CATCH
        PRINT 'ERROR en silver.sap_bsad: ' + ERROR_MESSAGE();
        THROW;
    END CATCH;

    -- ==========================================
    -- 7. LIMPIEZA: KNB1 (Datos de Sociedad del Cliente)
    -- ==========================================
    BEGIN TRY
        SET @start_time = GETDATE();
        PRINT '>> Cargando y limpiando silver.sap_knb1...';

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
            LTRIM(RTRIM(MANDT)),  -- mandante
            LTRIM(RTRIM(BUKRS)),  -- sociedad
            CAST(CAST(NULLIF(LTRIM(RTRIM(KUNNR)), '') AS BIGINT) AS VARCHAR(10)),  -- id cliente (sin ceros a la izquierda)
            TRY_CONVERT(DATE, NULLIF(LTRIM(RTRIM(ERDAT)), '00000000'), 112), -- fecha de creacion
            NULLIF(LTRIM(RTRIM(ERNAM)), ''),  -- usuario creador
            NULLIF(LTRIM(RTRIM(AKONT)), ''),  -- cuenta de mayor
            NULLIF(LTRIM(RTRIM(ZUAWA)), ''),  -- clave de ordenacion de partidas
            NULLIF(LTRIM(RTRIM(FDGRV)), ''),  -- grupo de planificacion de tesoreria
            NULLIF(LTRIM(RTRIM(ZTERM)), ''),  -- condicion de pago
            NULLIF(LTRIM(RTRIM(VZSKZ)), ''),  -- indicador de calculo de intereses
            TRY_CONVERT(DATE, NULLIF(LTRIM(RTRIM(ZINDT)), '00000000'), 112), -- fecha ultima liquidacion intereses
            NULLIF(LTRIM(RTRIM(LOEVM)), ''),  -- flag de borrado
            NULLIF(LTRIM(RTRIM(SPERR)), ''),  -- bloqueo de contabilizacion
            NULLIF(LTRIM(RTRIM(BEGRU)), ''),  -- grupo de autorizacion
            NULLIF(LTRIM(RTRIM(QLAND)), ''),  -- pais fiscal
            NULLIF(LTRIM(RTRIM(XAUSZ)), ''),  -- flag de compensacion con acreedor
            NULLIF(LTRIM(RTRIM(ALTKN)), ''),  -- cuenta anterior
            NULLIF(LTRIM(RTRIM(KNRZE)), ''),  -- cuenta del pagador alterno
            NULLIF(LTRIM(RTRIM(HBKID)), ''),  -- banco propio
            NULLIF(LTRIM(RTRIM(ZWELS)), ''),  -- vias de pago permitidas
            CASE WHEN LTRIM(RTRIM(XZVER)) = 'X' THEN 1 ELSE 0 END  -- flag compensacion cliente-proveedor
        FROM bronze.sap_knb1 WITH (NOLOCK)
        WHERE MANDT = '400'
          AND LTRIM(RTRIM(LOEVM)) <> 'X';  -- excluye registros marcados para borrado en SAP
        SET @rows_count = @@ROWCOUNT;

        SET @end_time = GETDATE();
        PRINT 'Filas: ' + CAST(@rows_count AS NVARCHAR) + ' | Duration: ' + CAST(DATEDIFF(SECOND, @start_time, @end_time) AS NVARCHAR) + ' s';
    END TRY
    BEGIN CATCH
        PRINT 'ERROR en silver.sap_knb1: ' + ERROR_MESSAGE();
        THROW;
    END CATCH;

    -- ==========================================
    -- 8. LIMPIEZA: KNB5 (Datos de Reclamacion del Cliente)
    -- ==========================================
    BEGIN TRY
        SET @start_time = GETDATE();
        PRINT '>> Cargando y limpiando silver.sap_knb5...';

        TRUNCATE TABLE silver.sap_knb5;

        INSERT INTO silver.sap_knb5 (
            mandante, cliente_id, sociedad, area_reclamacion,
            procedimiento_reclamacion, bloqueo_reclamacion, fecha_ultima_reclamacion
        )
        SELECT
            LTRIM(RTRIM(MANDT)),  -- mandante
            CAST(CAST(NULLIF(LTRIM(RTRIM(KUNNR)), '') AS BIGINT) AS VARCHAR(10)),  -- id cliente (sin ceros a la izquierda)
            LTRIM(RTRIM(BUKRS)),  -- sociedad
            LTRIM(RTRIM(MABER)),  -- area de reclamacion
            NULLIF(LTRIM(RTRIM(MAHNA)), ''),  -- procedimiento de reclamacion
            NULLIF(LTRIM(RTRIM(MAHNS)), ''),  -- bloqueo de reclamacion
            TRY_CONVERT(DATE, NULLIF(LTRIM(RTRIM(MADAT)), '00000000'), 112) -- fecha de la ultima reclamacion
        FROM bronze.sap_knb5 WITH (NOLOCK)
        WHERE MANDT = '400';
        SET @rows_count = @@ROWCOUNT;

        SET @end_time = GETDATE();
        PRINT 'Filas: ' + CAST(@rows_count AS NVARCHAR) + ' | Duration: ' + CAST(DATEDIFF(SECOND, @start_time, @end_time) AS NVARCHAR) + ' s';
    END TRY
    BEGIN CATCH
        PRINT 'ERROR en silver.sap_knb5: ' + ERROR_MESSAGE();
        THROW;
    END CATCH;

END;
GO
