/* =====================================================================================
   DIMENSIONES CONFORMADAS DEL PRESUPUESTO
   dwh_architecture/03_gold/ddl_dim_presupuesto.sql                  (2026-09-09)
   =====================================================================================

   Cuatro dimensiones chicas que sostienen el reporte de presupuesto, y que el reporte
   de flujo de pagos va a reusar tal cual:

     gold.dim_bucket      8 filas, estatica. Los tramos de antiguedad.
     gold.dim_ejecutivo  ~23 filas, derivada + CLASIFICACION MANUAL.
     gold.dim_region     ~21 filas, derivada + nombre legible manual.
     gold.dim_canal        3 filas, derivada + nombre legible manual.

   NO ESTAN EN ddl_gold.sql A PROPOSITO
   ------------------------------------
   Ese script hace DROP de cada tabla antes de crearla. Tres de estas cuatro guardan
   clasificacion capturada a mano - que ejecutivo es gestionable, como se llama de
   verdad la region MXZBAJ - y eso no se puede regenerar desde silver. Un DROP lo
   borraria sin dejar rastro.

   EL PROBLEMA DE LA DIMENSION DERIVADA CON ATRIBUTO MANUAL
   --------------------------------------------------------
   dim_ejecutivo se alimenta sola de dim_cliente_credito, pero tipo_gestion termina de
   decidirlo una persona. Si la recarga sobreescribiera, cada corrida borraria eso.
   Por eso gold.load_dim_presupuesto SOLO INSERTA lo que no existe y jamas actualiza lo
   que ya esta. Un valor nuevo entra clasificado por patron y con revisado = 0: el
   numero sale bien desde el primer dia y queda la marca de que nadie lo ha confirmado.

   OJO CON LA COLLATION
   --------------------
   La base es SQL_Latin1_General_CP850_BIN2, o sea BINARIA: 'PEREZ' y 'Perez' son
   distintos y un espacio al final rompe el join. Por eso la llave del ejecutivo se
   normaliza con UPPER(LTRIM(RTRIM(...))) SIEMPRE - aqui y en el hecho. Si las dos
   puntas no usan exactamente la misma expresion, el join falla en silencio y el
   presupuesto por ejecutivo sale incompleto sin que nada avise.
   ===================================================================================== */

USE ANALISIS_DATOS;
GO

/* ---------------------------------------------------------------- dim_bucket
   Estatica: los cortes de antiguedad son del modelo, no de los datos.
   bucket_orden existe porque sin el, el BI ordena alfabeticamente y
   'Vencida 181-365' queda antes que 'Vencida 61-90'. */
IF OBJECT_ID('gold.dim_bucket') IS NULL
CREATE TABLE gold.dim_bucket (
    bucket_key      VARCHAR(2)   NOT NULL,
    bucket_nombre   VARCHAR(40)  NOT NULL,
    bucket_corto    VARCHAR(16)  NOT NULL,   -- para ejes de graficas
    bucket_grupo    VARCHAR(12)  NOT NULL,   -- Por vencer / Vencida
    bucket_orden    TINYINT      NOT NULL,   -- cronologico, del menos al mas vencido
    dias_desde      INT          NULL,
    dias_hasta      INT          NULL,
    /* 0 = tramo que historicamente recupera ~nada. Hoy solo G.
       La tasa ya lo maneja sola; la bandera es para poder DECIRLO en el reporte. */
    es_recuperable  BIT          NOT NULL,
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
PRINT 'Table gold.dim_bucket ready.';
GO

/* ------------------------------------------------------------- dim_ejecutivo
   tipo_gestion separa personas de procesos, y es lo que permite dar DOS numeros
   sin dos calculos:
     pronostico de caja = todo
     meta de cobranza   = solo es_cobrable = 1

   La dimension cubre TODA la historia de dim_cliente_credito (89 valores), no solo los
   que tienen cartera hoy (23). Son cinco familias, y solo la primera son personas:

     personas        ~47  17 con cartera hoy, el resto ex-analistas
     CAJERA *         33  cajas de sucursal
     INACTIVOS *       3  incluido INACTIVOS CLIENTES MOROSOS
     VACANTE *         2  cartera sin dueno: un sin-asignar de facto
     otros             4  juridico, call center, BtoB, verificacion contado

   Al 2026-09-04, la cartera abierta se reparte:
     GESTIONABLE   ~16 ejecutivos + bolsas operativas   $202M
     SIN_ASIGNAR   1 cliente, fuera de alcance          $14.2M  <- 100% en bucket G
     EXTRAJUDICIAL 5 valores                            $4.4M
     JURIDICO      CLIENTES JURIDICO                    $1.3M

   JURIDICO ENTRA (es_cobrable = 1): son la ultima etapa antes de incobrables y se
   espera que paguen. EXTRAJUDICIAL sale, que es lo que hace hoy el calculo manual.
   Las dos son decisiones de negocio, no del modelo: se cambian con un UPDATE a
   es_cobrable y el presupuesto se re-expresa solo, sin recalcular nada. */
IF OBJECT_ID('gold.dim_ejecutivo') IS NULL
CREATE TABLE gold.dim_ejecutivo (
    ejecutivo_key     VARCHAR(60)  NOT NULL,  -- UPPER(LTRIM(RTRIM(nombre))) - ver cabecera
    ejecutivo_nombre  VARCHAR(60)  NOT NULL,
    analista_id       VARCHAR(10)  NULL,
    tipo_gestion      VARCHAR(16)  NOT NULL,  -- GESTIONABLE/SIN_ASIGNAR/EXTRAJUDICIAL/JURIDICO/INACTIVO
    es_cobrable       BIT          NOT NULL,  -- entra en la META del equipo
    es_persona        BIT          NOT NULL,  -- 0 = bolsa de proceso, no alguien a quien medir
    /* Separa lo que ADIVINO el patron de lo que CONFIRMO una persona. La clasificacion
       automatica acierta casi siempre porque las bolsas de proceso siguen convenciones
       (CAJERA, INACTIVOS, VACANTE, EXTRAJUDICIAL...), pero "casi siempre" no es lo mismo
       que "revisado", y el numero que sale de aqui es una meta de equipo. */
    revisado          BIT          NOT NULL DEFAULT 0,
    fecha_alta        DATETIME     DEFAULT GETDATE(),
    CONSTRAINT PK_dim_ejecutivo PRIMARY KEY CLUSTERED (ejecutivo_key)
);
GO

IF COL_LENGTH('gold.dim_ejecutivo','revisado') IS NULL
    ALTER TABLE gold.dim_ejecutivo ADD revisado BIT NOT NULL DEFAULT 0;
GO
PRINT 'Table gold.dim_ejecutivo ready.';
GO

/* ---------------------------------------------------------------- dim_region
   SAP entrega codigos (MXZBAJ, MXZPAC, 01OFCC...). region_nombre nace igual al
   codigo y se captura a mano; hasta entonces el reporte muestra el codigo, que es
   feo pero honesto - mejor que un nombre inventado.

   es_comercial distingue region de venta real de codigo administrativo. Importa:
   01OFCC tiene $14.2M y UN solo cliente, sin facturar desde hace anios. En una grafica
   de "presupuesto por region" aparece como si fuera una plaza grande. No lo es. */
IF OBJECT_ID('gold.dim_region') IS NULL
CREATE TABLE gold.dim_region (
    region_key      VARCHAR(10)  NOT NULL,
    region_nombre   VARCHAR(60)  NOT NULL,
    es_comercial    BIT          NOT NULL,
    fecha_alta      DATETIME     DEFAULT GETDATE(),
    CONSTRAINT PK_dim_region PRIMARY KEY CLUSTERED (region_key)
);
GO
PRINT 'Table gold.dim_region ready.';
GO

/* ----------------------------------------------------------------- dim_canal */
IF OBJECT_ID('gold.dim_canal') IS NULL
CREATE TABLE gold.dim_canal (
    canal_key       VARCHAR(4)   NOT NULL,
    canal_nombre    VARCHAR(40)  NOT NULL,
    fecha_alta      DATETIME     DEFAULT GETDATE(),
    CONSTRAINT PK_dim_canal PRIMARY KEY CLUSTERED (canal_key)
);
GO
PRINT 'Table gold.dim_canal ready.';
GO

/* =====================================================================================
   gold.load_dim_presupuesto
   Refresca las tres derivadas. SOLO INSERTA. Nunca actualiza ni borra: la
   clasificacion manual es el activo aqui, no los nombres.
   Correr despues de load_gold; es de segundos.
   ===================================================================================== */
IF OBJECT_ID('gold.load_dim_presupuesto') IS NOT NULL
    DROP PROCEDURE gold.load_dim_presupuesto;
GO

CREATE PROCEDURE gold.load_dim_presupuesto
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @e INT, @r INT, @c INT, @pend INT;

    BEGIN TRY
        BEGIN TRANSACTION;

        /* -------- ejecutivos. La misma normalizacion que usa el hecho. --------

           Las bolsas de proceso siguen convenciones de nombre y por eso se reconocen
           por patron, no por lista: una lista fija se queda vieja en silencio. De hecho
           el patron '%EXTRAJUDICIAL%' encontro dos valores que no estaban en las reglas
           que dio Cobranza (COBRADOR EXTRAJUDICIAL INTERNO y EXTRAJUDICIAL INTERNA CXC).

           EL DEFAULT ES "PERSONA GESTIONABLE", Y ESO ES DELIBERADO.
           Un nombre que no cae en ningun patron es el nombre de alguien, y una persona
           gestiona cartera. El default contrario -no cobrable hasta que se revise- suena
           prudente y no lo es: dejaria la meta del equipo en casi cero hasta que alguien
           clasifique 47 renglones a mano. La prudencia va en `revisado`, no en el numero. */
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
               /* Cobrable = entra en la meta del equipo.
                  Fuera: sin asignar, vacante, extrajudicial e inactivos.
                  Dentro: juridico -ultima etapa antes de incobrables, se espera que
                  paguen- y las bolsas operativas (cajas, call center, verificacion),
                  porque ese dinero si entra y si se gestiona. */
               CASE
                 WHEN s.k = '(SIN ASIGNAR)' OR s.k LIKE 'VACANTE%'        THEN 0
                 WHEN s.k LIKE '%EXTRAJUDICIAL%'
                   OR s.k = 'COBRADOR RUTA DOS CIENTOS'                   THEN 0
                 WHEN s.k LIKE 'INACTIVOS%'                               THEN 0
                 ELSE 1
               END,
               /* Persona = alguien a quien tiene sentido medir. Una caja de sucursal
                  mueve dinero pero no es un ejecutivo, y ponerla en un ranking de
                  desempeno seria comparar cosas distintas. */
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
               0   -- revisado: nada nace confirmado
        FROM (SELECT UPPER(ISNULL(NULLIF(LTRIM(RTRIM(analista_credito_nombre)),''),'(SIN ASIGNAR)')) AS k,
                     analista_credito_id AS id
              FROM   gold.dim_cliente_credito) s
        WHERE NOT EXISTS (SELECT 1 FROM gold.dim_ejecutivo d WHERE d.ejecutivo_key = s.k)
        GROUP BY s.k;
        SET @e = @@ROWCOUNT;

        /* -------- regiones -------- */
        INSERT INTO gold.dim_region (region_key, region_nombre, es_comercial)
        SELECT s.k, s.k, 1
        FROM  (SELECT DISTINCT UPPER(LTRIM(RTRIM(region))) AS k
               FROM gold.dim_cliente_comercial WHERE region IS NOT NULL AND LTRIM(RTRIM(region)) <> '') s
        WHERE NOT EXISTS (SELECT 1 FROM gold.dim_region d WHERE d.region_key = s.k);
        SET @r = @@ROWCOUNT;

        /* -------- canales -------- */
        INSERT INTO gold.dim_canal (canal_key, canal_nombre)
        SELECT s.k, s.k
        FROM  (SELECT DISTINCT LTRIM(RTRIM(canal_distribucion)) AS k
               FROM gold.dim_cliente_comercial
               WHERE canal_distribucion IN (10, 40, 60)) s
        WHERE NOT EXISTS (SELECT 1 FROM gold.dim_canal d WHERE d.canal_key = s.k);
        SET @c = @@ROWCOUNT;

        COMMIT TRANSACTION;

        SET @pend = (SELECT COUNT(*) FROM gold.dim_ejecutivo WHERE revisado = 0);

        PRINT '>> gold.load_dim_presupuesto | ejecutivos nuevos: ' + CAST(@e AS VARCHAR(6))
            + ' | regiones nuevas: ' + CAST(@r AS VARCHAR(6))
            + ' | canales nuevos: '  + CAST(@c AS VARCHAR(6));
        IF @pend > 0
            PRINT '   Sin revisar: ' + CAST(@pend AS VARCHAR(6)) + ' ejecutivo(s) con clasificacion'
                + ' automatica. El presupuesto ya los cuenta; confirmar y poner revisado = 1.';
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        PRINT 'ERROR en gold.load_dim_presupuesto: ' + ERROR_MESSAGE();
        THROW;
    END CATCH;
END;
GO
PRINT 'Procedure gold.load_dim_presupuesto created.';
GO
