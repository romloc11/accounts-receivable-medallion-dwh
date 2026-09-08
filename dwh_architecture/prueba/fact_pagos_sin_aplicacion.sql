/*
========================================================================================
dbo.fact_pagos_sin_aplicacion  -  por que este dinero no liquido ninguna factura
========================================================================================
CONTROL (2026-09-07): 37 lineas / ~$1.9M

    LIQUIDA_NO_FACTURA   21 lineas | ~$1.6M
    SIN_APLICACION       13 lineas | $  ~$289K
    LINEA_TECNICA         3 lineas | $  -11,174.05

--- POR QUE UNA TABLA APARTE Y NO FILAS EN EL PUENTE ---
Una fila de fact_aplicacion_pagos afirma "este pago toco ESTA factura". Estos pagos no
tocaron ninguna. Meterlos ahi obligaria a inventar un factura_id centinela y a aflojar
la PK, que hoy es NOT NULL en las seis columnas - se perderia justo la garantia que hace
imposible el duplicado. Y cualquiera que contara filas del puente creyendo que son
aplicaciones se equivocaria.
Tampoco va como columna de fact_pagos: el motivo se DERIVA de la logica de aplicacion
(tiene salto, el salto llega a facturas), y fact_pagos hoy es limpia - sale de silver y
nada mas. Acoplarla a las reglas seria un retroceso.
Grano: la linea de pago, igual que fact_pagos. Se carga DESPUES del puente.

--- ESTO ES COBRANZA, NO UN HUECO (confirmado por el usuario 2026-09-07) ---
El dinero SI entro. Simplemente liquido documentos que no son facturas de cliente.
Los debitos de esos grupos finales son, en monto: SA ~$1.3M (ajustes y comisiones),
AB ~$354K (documentos de compensacion), DZ ~$288K, y apenas F4 ~$10K.
Caso verificable en SAP: el pago <pago-14> de KUSHKY (~$354K) va al hijo
<pago-17>, que reparte en tres grupos finales (<grupo-7> / <grupo-8> / <grupo-9>)
y en los tres el mayor debito es clase SA. Para una pasarela eso es lo correcto: liquida
comisiones, no facturas.

Por eso la etiqueta NO dice "NO_IDENTIFICADO". Eso sugeriria que fallamos en encontrar
algo; la realidad es que no habia factura que encontrar. Son dos afirmaciones distintas
y el negocio las lee distinto.

--- LOS DOS TOTALES DEL REPORTE, QUE NO SE DEBEN CONFUNDIR ---
    Cobranza total            ~$149.2M   todo el dinero que entro
    Cobranza aplicada         ~$147.4M   lo que liquido facturas de cliente
    diferencia                $  ~$1.9M   esta tabla
La diferencia no es un error: es dinero real contra documentos que no son factura.
========================================================================================
*/

IF OBJECT_ID('dbo.fact_pagos_sin_aplicacion', 'U') IS NOT NULL
    DROP TABLE dbo.fact_pagos_sin_aplicacion;
GO

CREATE TABLE dbo.fact_pagos_sin_aplicacion (
    cliente_id              VARCHAR(10) NOT NULL,
    ejercicio               INT         NOT NULL,
    documento_id            VARCHAR(10) NOT NULL,
    posicion                INT         NOT NULL,
    documento_compensacion  VARCHAR(10) NULL,   -- para trazar que si liquido
    fecha_compensacion      DATE        NULL,
    motivo                  VARCHAR(24) NOT NULL,
    fecha_carga             DATE        NOT NULL
        CONSTRAINT DF_fpsa_carga DEFAULT CAST(GETDATE() AS DATE),
    CONSTRAINT PK_fact_pagos_sin_aplicacion PRIMARY KEY (ejercicio, documento_id, posicion)
);
GO


-- Necesita #salto y #gcf. Si vienes de correr fact_aplicacion_pagos.sql en la misma
-- sesion, #salto ya existe; #gcf se crea aqui.
IF OBJECT_ID('tempdb..#salto') IS NOT NULL DROP TABLE #salto;
SELECT DISTINCT h.documento_id AS hijo, h.documento_compensacion AS grupo_final
INTO   #salto
FROM   silver.sap_bsad h
WHERE  h.mandante = '400' AND h.clase_documento = 'DZ'
  AND  h.clave_contabilizacion = '15'
  AND  h.documento_compensacion IS NOT NULL;
CREATE UNIQUE CLUSTERED INDEX ix_salto ON #salto(hijo, grupo_final);

IF OBJECT_ID('tempdb..#gcf') IS NOT NULL DROP TABLE #gcf;
SELECT DISTINCT documento_compensacion AS g
INTO   #gcf
FROM   silver.sap_bsad
WHERE  mandante = '400' AND debe_haber = 'S'
  AND  (clase_documento LIKE 'F%' OR clase_documento = 'D1')
  AND  documento_compensacion IS NOT NULL;
CREATE UNIQUE CLUSTERED INDEX ix_gcf ON #gcf(g);


INSERT INTO dbo.fact_pagos_sin_aplicacion (
    cliente_id, ejercicio, documento_id, posicion,
    documento_compensacion, fecha_compensacion, motivo
)
SELECT x.cliente_id, x.ejercicio, x.documento_id, x.posicion,
       x.documento_compensacion, x.fecha_compensacion,
       CASE WHEN x.clave_contabilizacion = '08' THEN 'LINEA_TECNICA'
            WHEN x.tiene_salto      = 0         THEN 'SIN_APLICACION'
            WHEN x.salto_a_facturas = 0         THEN 'LIQUIDA_NO_FACTURA'
            -- Cuarta rama a proposito: si algo cae aqui es un caso que no conociamos.
            -- Un ELSE que dice 'OTRO' y se olvida es la forma habitual de esconder
            -- casos nuevos. Control 2026-09-07: 0 filas.
            ELSE 'REVISAR' END
FROM (
    SELECT p.cliente_id, p.ejercicio, p.documento_id, p.posicion,
           p.documento_compensacion, p.fecha_compensacion, p.clave_contabilizacion,
           MAX(CASE WHEN s.grupo_final IS NOT NULL THEN 1 ELSE 0 END) AS tiene_salto,
           MAX(CASE WHEN g.g           IS NOT NULL THEN 1 ELSE 0 END) AS salto_a_facturas
    FROM   dbo.fact_pagos p
    -- LEFT JOIN: el pago debe sobrevivir aunque no tenga salto - justamente eso es
    -- lo que lo clasifica como SIN_APLICACION.
    LEFT JOIN #salto s ON s.hijo = p.documento_compensacion
    LEFT JOIN #gcf   g ON g.g    = s.grupo_final
    WHERE  NOT EXISTS (SELECT 1 FROM dbo.fact_aplicacion_pagos a
                       WHERE a.ejercicio_pago = p.ejercicio
                         AND a.pago_id        = p.documento_id
                         AND a.posicion_pago  = p.posicion)
    GROUP BY p.cliente_id, p.ejercicio, p.documento_id, p.posicion,
             p.documento_compensacion, p.fecha_compensacion, p.clave_contabilizacion
) x;
GO


-- ========================================================================================
-- Verificacion
-- ========================================================================================
SELECT motivo, COUNT(*) AS lineas, CAST(SUM(p.monto) AS DECIMAL(18,2)) AS monto
FROM   dbo.fact_pagos_sin_aplicacion sa
JOIN   dbo.fact_pagos p ON p.ejercicio = sa.ejercicio
                       AND p.documento_id = sa.documento_id
                       AND p.posicion = sa.posicion
GROUP BY motivo ORDER BY motivo;
-- LINEA_TECNICA 3 / -11,174.05 | LIQUIDA_NO_FACTURA 21 / ~$1.6M
-- SIN_APLICACION 13 / ~$289K   |   REVISAR debe salir en 0

-- Invariante: todo pago esta EN el puente O aqui, nunca en los dos ni en ninguno.
SELECT 'pagos sin clasificar (debe ser 0)' AS chequeo, COUNT(*) AS valor
FROM   dbo.fact_pagos p
WHERE  NOT EXISTS (SELECT 1 FROM dbo.fact_aplicacion_pagos a
                   WHERE a.ejercicio_pago=p.ejercicio AND a.pago_id=p.documento_id
                     AND a.posicion_pago=p.posicion)
  AND  NOT EXISTS (SELECT 1 FROM dbo.fact_pagos_sin_aplicacion s
                   WHERE s.ejercicio=p.ejercicio AND s.documento_id=p.documento_id
                     AND s.posicion=p.posicion);
GO
