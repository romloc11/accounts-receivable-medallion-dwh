/* =====================================================================================
   TABLAS DEL PRESUPUESTO DE COBRANZA
   dwh_architecture/04_pronostico/ddl_presupuesto.sql               (2026-09-09)
   =====================================================================================

   Dos tablas, y son de granos distintos a proposito:

     gold.fact_presupuesto_cobranza   un renglon por DIA del mes presupuestado.
                                      Es lo que Cobranza opera: cuanto se espera hoy,
                                      cuanto entro de verdad, y como va el acumulado.

     gold.fact_presupuesto_cartera    un renglon por BUCKET de antiguedad.
                                      Es la explicacion del numero: DONDE esta el dinero
                                      prometido y con que tasa se le creyo.

   Guardar las dos no es redundancia. La primera contesta "vamos bien?" y la segunda
   contesta "por que fallo?" - y sin la segunda, un mes malo es imposible de diagnosticar
   despues, porque la cartera ya se movio y la foto del corte no se puede reconstruir.

   POR QUE SE GUARDA LA TASA USADA
   -------------------------------
   El proc recalibra las tasas en cada corrida sobre los 24 meses previos, asi que las
   tasas de octubre no son las de septiembre. Si no se guarda cual se uso, un pronostico
   viejo deja de ser auditable: no se puede distinguir "la cartera se comporto distinto"
   de "cambiaron los parametros".

   EL MODELO QUE LAS LLENA: ver modelo_presupuesto.sql en esta misma carpeta.
   ===================================================================================== */

/* ---------------------------------------------------------------------- DIARIO */
IF OBJECT_ID('gold.fact_presupuesto_cobranza') IS NULL
CREATE TABLE gold.fact_presupuesto_cobranza (
    mes_presupuesto     DATE         NOT NULL,   -- dia 1 del mes presupuestado
    fecha               DATE         NOT NULL,   -- el dia concreto
    fecha_corte         DATE         NOT NULL,   -- cuando se saco el numero (4o dia habil)

    es_dia_habil        BIT          NOT NULL,
    slot_calendario     VARCHAR(3)   NULL,       -- I01..I03 / M / F08..F01; NULL si no habil
    /* OBSERVADO  = dia anterior al corte. El dinero ya estaba en el banco cuando se
                    armo el presupuesto, asi que no se pronostica: se copia.
       PRONOSTICO = del corte en adelante. */
    origen              VARCHAR(10)  NOT NULL,

    monto_presupuesto   DECIMAL(19,2) NOT NULL,

    fecha_carga         DATETIME     DEFAULT GETDATE(),
    CONSTRAINT PK_fact_presupuesto_cobranza PRIMARY KEY CLUSTERED (mes_presupuesto, fecha)
);
GO

/* AQUI NO VA monto_real, Y ES EL PUNTO DE LA TABLA.
   Nacio con esa columna y estaba mal: se llenaba al correr el proc -una vez al mes-
   y nunca se refrescaba, asi que al dia 20 seguia mostrando lo que se sabia el dia 4.
   Lo real vive en gold.vw_cobranza_diaria, que se calcula al vuelo.
   El pronostico se congela; lo real se refresca. Una tabla no puede hacer las dos. */
IF COL_LENGTH('gold.fact_presupuesto_cobranza', 'monto_real') IS NOT NULL
    ALTER TABLE gold.fact_presupuesto_cobranza DROP COLUMN monto_real;
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'IX_fpc_fecha' AND object_id = OBJECT_ID('gold.fact_presupuesto_cobranza'))
CREATE INDEX IX_fpc_fecha ON gold.fact_presupuesto_cobranza (fecha);
GO
PRINT 'Table gold.fact_presupuesto_cobranza ready (creada si faltaba, respetada si ya estaba).';
GO

/* --------------------------------------------------------------------- BUCKETS
   GRANO: mes x bucket x ejecutivo x region x canal x estatus.
   ~2,000 filas al mes. Se midio: en la cartera real solo existen 972 combinaciones
   de segmento, asi que el grano fino es gratis - y es lo que permite contestar
   "presupuesto por ejecutivo" y "por region" sin recalcular nada.

   NO se baja a grano CLIENTE, aunque cabria. La tasa es poblacional: decir
   "el cliente X va a pagar 71% de su saldo" seria inventar una precision que no
   existe, y en cuanto alguien vea ese renglon lo va a tratar como meta del cliente.
   El segmento es el nivel mas fino donde el numero sigue significando algo.

   Los atributos se guardan RESUELTOS AL CORTE, no por llave a una SCD2. Si en octubre
   reasignan un cliente, el presupuesto de septiembre no cambia de dueno - para un
   numero contra el que se mide gente, eso no es un detalle.

   estatus_comercial viaja aunque no se pidio como segmento: es la regla de alcance
   del proyecto, y tenerla en el hecho es lo que permite VERIFICAR que se aplico en
   vez de confiar en que si. */
IF OBJECT_ID('gold.fact_presupuesto_cartera') IS NULL
CREATE TABLE gold.fact_presupuesto_cartera (
    mes_presupuesto     DATE          NOT NULL,
    fecha_corte         DATE          NOT NULL,

    bucket_key          VARCHAR(2)    NOT NULL,  -- -> gold.dim_bucket
    ejecutivo_key       VARCHAR(60)   NOT NULL,  -- -> gold.dim_ejecutivo
    region_key          VARCHAR(10)   NOT NULL,  -- -> gold.dim_region
    canal_key           VARCHAR(4)    NOT NULL,  -- -> gold.dim_canal
    estatus_comercial   VARCHAR(20)   NOT NULL,

    monto_cartera       DECIMAL(19,2) NOT NULL,  -- parada al corte
    tasa_recuperacion   DECIMAL(9,6)  NOT NULL,  -- la que se USO, no la de hoy
    /* SEGMENTO = tasa propia de bucket x tipo_gestion.
       BUCKET   = la celda tenia muy poca historia y se cayo a la tasa general.
       Sin esta columna, una tasa de respaldo es indistinguible de una medida. */
    tasa_origen         VARCHAR(10)   NOT NULL,
    monto_esperado      DECIMAL(19,2) NOT NULL,  -- cartera x tasa

    /* Se llena al CERRAR el mes, no al calcularlo: es la tasa realizada, y es lo
       que alimenta el circuito con el reporte de flujo de pagos. */
    monto_real          DECIMAL(19,2) NULL,

    fecha_carga         DATETIME      DEFAULT GETDATE(),
    CONSTRAINT PK_fact_presupuesto_cartera PRIMARY KEY CLUSTERED
        (mes_presupuesto, bucket_key, ejecutivo_key, region_key, canal_key, estatus_comercial)
);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'IX_fpcart_ejecutivo' AND object_id = OBJECT_ID('gold.fact_presupuesto_cartera'))
CREATE INDEX IX_fpcart_ejecutivo ON gold.fact_presupuesto_cartera (ejecutivo_key, mes_presupuesto);
GO
PRINT 'Table gold.fact_presupuesto_cartera ready (creada si faltaba, respetada si ya estaba).';
GO
