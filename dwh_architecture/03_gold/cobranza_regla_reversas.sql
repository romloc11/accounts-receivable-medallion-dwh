/* =====================================================================================
   LA COBRANZA DE UN MES CON LA REGLA CORRECTA DE REVERSAS
   dwh_architecture/03_gold/cobranza_regla_reversas.sql                   (2026-09-11)
   =====================================================================================

   QUE CONTESTA
   ------------
   Cuanto cobro la empresa en un mes, contando cada linea DZ por lo que SAP dice que
   es -su clave de contabilizacion- y restando una reversa SOLO cuando anula algo que
   si contamos. Da el numero con y sin las tres reglas de alcance.

   POR QUE NO BASTA gold.fact_pagos
   --------------------------------
   fact_pagos filtra por el texto de la linea (sgtxt = 'Asignación Aut. Deposito') y
   NUNCA resta una reversa. Las dos cosas se arreglan aqui:
   (Nota 2026-09-14: gold.fact_pagos ya hace las dos cosas - la clave 11 entra sin texto
   y resta la reversa de una linea contada, linea por linea. Este archivo queda como la
   medicion original que llevo a esos cambios.)

     - el texto era un proxy de la clave 11: acierta el 99% de las veces en esa clave,
       pero solo el 19% en las lineas 15 que entran solas. Con BKPF cargado ya no hay
       que adivinar: la clave 11 la escribe el programa OS_APPLICATION, punto.
     - restar reversas necesitaba saber QUE documento anula cada una. Ese dato (STBLG)
       vive en BKPF, que hasta hoy no estaba en el DWH. Ya esta en silver.sap_bkpf.

   LA REGLA DE REVERSAS, EN UNA LINEA
   ----------------------------------
   Se resta una reversa solo si el documento que anula fue contado como entrada.

   Restarlas todas descuenta de mas: 23 reversas de 2026 anulan re-aplicaciones FB05
   que nunca contamos como dinero nuevo, asi que restarlas quitaria dinero dos veces.
   Y la alternativa -excluir el documento original en vez de restar la reversa- reescribe
   meses ya cerrados: el 18% de las reversas cae en un mes distinto al del original.

   POR QUE RESTAR Y NO EXCLUIR
   ---------------------------
   Restar deja el golpe en el mes donde SAP lo registro. Excluir obliga a reabrir el mes
   del original. En 2026 los dos metodos dan identico; restar es el que no depende de eso.

   LAS TRES REGLAS DE ALCANCE
   --------------------------
     1. estatus_comercial <> 'FUERA_DE_ALCANCE'   (dim_cliente_comercial, a la fecha)
     2. canal_distribucion IN (10, 40, 60)        (dim_cliente_comercial, a la fecha)
     3. tipo_cliente <> 'SIN_RFC'                 (dim_cliente)
   La 3 NO esta hoy en fact_pagos ni en vw_cobranza_diaria; si esta en vw_cartera_abierta
   y en vw_pago_factura_simple. Aqui se mide su efecto por separado.

   COMO CORRERLO
   -------------
   Cambiar @ini/@fin y ejecutar completo en SSMS. Solo lee; no crea ni modifica nada.
   ===================================================================================== */

USE ANALISIS_DATOS;
GO

SET NOCOUNT ON;

DECLARE @ini    DATE = '2026-07-01';   -- primer dia del mes a medir
DECLARE @fin    DATE = '2026-07-31';   -- ultimo dia, inclusive
DECLARE @desde  DATE = '2025-01-01';   -- ventana para BUSCAR el original de una reversa
                                       -- (18% de las reversas apuntan a otro mes)


/* =====================================================================================
   PASO 1 - El universo: toda linea DZ de la ventana, compensada o abierta
   -------------------------------------------------------------------------------------
   BSAD son las lineas ya compensadas; BSID las que siguen abiertas -dinero en el banco
   todavia sin aplicar-. Una linea que aparece en las dos es una compensacion deshecha:
   gana BSID, que se recarga completo cada dia y por eso siempre trae el estado de hoy.
   BSAD es incremental y puede conservar una compensacion vieja.

   El monto se firma aqui: silver NUNCA trae el importe con signo, siempre positivo.
   ===================================================================================== */
IF OBJECT_ID('tempdb..#dz') IS NOT NULL DROP TABLE #dz;

SELECT sociedad, cliente_id, ejercicio, documento_id, posicion,
       fecha_documento, fecha_contabilizacion, clave_contabilizacion, sgtxt, monto, estado
INTO   #dz
FROM (
    SELECT b.sociedad, b.cliente_id, b.ejercicio, b.documento_id, b.posicion,
           b.fecha_documento, b.fecha_contabilizacion, b.clave_contabilizacion, b.sgtxt,
           CASE WHEN b.debe_haber = 'H' THEN b.monto_moneda_local
                ELSE -1 * b.monto_moneda_local END AS monto,
           'COMPENSADO' AS estado
    FROM   silver.sap_bsad b
    WHERE  b.mandante = '400'
      AND  b.clase_documento = 'DZ'
      AND  b.fecha_documento >= @desde
      AND  NOT EXISTS (SELECT 1 FROM silver.sap_bsid o
                       WHERE o.mandante = '400'          AND o.sociedad     = b.sociedad
                         AND o.cliente_id = b.cliente_id AND o.ejercicio    = b.ejercicio
                         AND o.documento_id = b.documento_id
                         AND o.posicion   = b.posicion)

    UNION ALL

    SELECT b.sociedad, b.cliente_id, b.ejercicio, b.documento_id, b.posicion,
           b.fecha_documento, b.fecha_contabilizacion, b.clave_contabilizacion, b.sgtxt,
           CASE WHEN b.debe_haber = 'H' THEN b.monto_moneda_local
                ELSE -1 * b.monto_moneda_local END AS monto,
           'ABIERTO' AS estado
    FROM   silver.sap_bsid b
    WHERE  b.mandante = '400'
      AND  b.clase_documento = 'DZ'
      AND  b.fecha_documento >= @desde
) u;

CREATE CLUSTERED INDEX ix_dz ON #dz(sociedad, ejercicio, documento_id);


/* =====================================================================================
   PASO 2 - Lo que hay que saber de cada DOCUMENTO (no de cada linea)
   -------------------------------------------------------------------------------------
   tiene_08: la clave 08 toma un credito que YA existe en otro documento. Un documento
             que trae una 08 esta gastando dinero que ya entro, asi que su 15 es una
             re-aplicacion, no un cobro nuevo. Esta es la condicion estructural que
             reemplaza al filtro de texto.

   documento_reversa (STBLG en BKPF): a que documento anula este. Es la unica forma de
             saberlo; BSAD no lo trae.
   ===================================================================================== */
IF OBJECT_ID('tempdb..#doc') IS NOT NULL DROP TABLE #doc;

SELECT d.sociedad, d.ejercicio, d.documento_id,
       MAX(CASE WHEN d.clave_contabilizacion = '08' THEN 1 ELSE 0 END) AS tiene_08,
       MAX(k.documento_reversa)  AS documento_reversa,
       MAX(k.ejercicio_reversa)  AS ejercicio_reversa,
       MAX(k.transaccion)        AS transaccion
INTO   #doc
FROM   #dz d
LEFT JOIN silver.sap_bkpf k
       ON  k.mandante = '400'
       AND k.sociedad = d.sociedad
       AND k.ejercicio = d.ejercicio
       AND k.documento_id = d.documento_id
GROUP BY d.sociedad, d.ejercicio, d.documento_id;

CREATE UNIQUE CLUSTERED INDEX ix_doc ON #doc(sociedad, ejercicio, documento_id);


/* =====================================================================================
   PASO 3 - Clasificar cada linea por su clave
   -------------------------------------------------------------------------------------
     11            deposito automatico    entra    lo escribe OS_APPLICATION
     15 sin 08     pago a mano            entra    FBZ1/FB05 capturado por una persona
     15 con 08     re-aplicacion          no       mueve dinero que ya estaba adentro
     08 / 18       compensacion interna   no       consume un credito existente
     02            reversa de deposito    resta*   anula una 11
     05 con STBLG  reversa de pago        resta*   FB08, anula una 15
     05 sin STBLG  devolucion al cliente  aparte   FBZ2, dinero que SALE de verdad
     07 / 17 / 01  otras                  no       se cancelan entre si

     * solo si el documento anulado fue contado - eso se decide en el paso 4.
   ===================================================================================== */
IF OBJECT_ID('tempdb..#lin') IS NOT NULL DROP TABLE #lin;

SELECT d.*,
       c.tiene_08, c.documento_reversa, c.ejercicio_reversa, c.transaccion,
       CASE
         WHEN d.clave_contabilizacion = '11'                          THEN 'DEPOSITO AUTOMATICO'
         WHEN d.clave_contabilizacion = '15' AND c.tiene_08 = 0       THEN 'PAGO REGISTRADO A MANO'
         WHEN d.clave_contabilizacion = '15'                          THEN 'RE-APLICACION'
         WHEN d.clave_contabilizacion = '02'                          THEN 'REVERSA DE DEPOSITO'
         WHEN d.clave_contabilizacion = '05' AND c.documento_reversa IS NOT NULL
                                                                      THEN 'REVERSA DE PAGO'
         WHEN d.clave_contabilizacion = '05'                          THEN 'DEVOLUCION AL CLIENTE'
         WHEN d.clave_contabilizacion IN ('08','18')                  THEN 'COMPENSACION INTERNA'
         ELSE                                                              'OTRA'
       END AS tipo_movimiento
INTO   #lin
FROM   #dz d
JOIN   #doc c ON c.sociedad = d.sociedad AND c.ejercicio = d.ejercicio
             AND c.documento_id = d.documento_id;

/* Sin este indice el paso 4 recorre #lin entero una vez POR REVERSA. */
CREATE CLUSTERED INDEX ix_lin ON #lin(sociedad, documento_id, ejercicio);


/* =====================================================================================
   PASO 4 - La regla: restar una reversa solo si lo que anula fue contado
   -------------------------------------------------------------------------------------
   Se busca el documento original (STBLG) dentro de #lin y se pregunta si tiene alguna
   linea que si cuenta. Si el original no aparece en la ventana, no se puede afirmar
   nada: se marca 'ORIGINAL NO LOCALIZADO' y NO se resta. El conteo de esos casos sale
   en el ultimo resultado - si crece, hay que abrir @desde.
   ===================================================================================== */
IF OBJECT_ID('tempdb..#fin') IS NOT NULL DROP TABLE #fin;

SELECT l.*,
       CASE
         WHEN l.tipo_movimiento IN ('DEPOSITO AUTOMATICO', 'PAGO REGISTRADO A MANO')
              THEN 1
         WHEN l.tipo_movimiento IN ('REVERSA DE DEPOSITO', 'REVERSA DE PAGO')
              AND EXISTS (SELECT 1 FROM #lin o
                          WHERE o.sociedad     = l.sociedad
                            AND o.ejercicio    = l.ejercicio_reversa
                            AND o.documento_id = l.documento_reversa
                            AND o.tipo_movimiento IN ('DEPOSITO AUTOMATICO',
                                                      'PAGO REGISTRADO A MANO'))
              THEN 1
         ELSE 0
       END AS cuenta_como_cobranza,
       CASE
         WHEN l.tipo_movimiento NOT IN ('REVERSA DE DEPOSITO', 'REVERSA DE PAGO') THEN NULL
         WHEN NOT EXISTS (SELECT 1 FROM #lin o
                          WHERE o.sociedad     = l.sociedad
                            AND o.ejercicio    = l.ejercicio_reversa
                            AND o.documento_id = l.documento_reversa)
              THEN 'ORIGINAL NO LOCALIZADO'
         WHEN EXISTS (SELECT 1 FROM #lin o
                      WHERE o.sociedad     = l.sociedad
                        AND o.ejercicio    = l.ejercicio_reversa
                        AND o.documento_id = l.documento_reversa
                        AND o.tipo_movimiento IN ('DEPOSITO AUTOMATICO',
                                                  'PAGO REGISTRADO A MANO'))
              THEN 'ANULA ALGO CONTADO -> SE RESTA'
         ELSE 'ANULA UNA RE-APLICACION -> NO SE RESTA'
       END AS destino_reversa
INTO   #fin
FROM   #lin l;


/* =====================================================================================
   PASO 5 - El alcance, resuelto A LA FECHA DEL PAGO
   -------------------------------------------------------------------------------------
   Las tres reglas se marcan POR SEPARADO para poder decir cuanto quita cada una.
   dim_cliente_comercial es SCD2: se toma la version vigente el dia del pago, no la de
   hoy. Un cliente sin fila en la dimension queda FUERA (no se puede afirmar que este
   dentro del alcance de algo que no existe en el maestro).
   ===================================================================================== */
IF OBJECT_ID('tempdb..#alc') IS NOT NULL DROP TABLE #alc;

SELECT f.*,
       CASE WHEN dcc.cliente_id IS NOT NULL
             AND dcc.estatus_comercial <> 'FUERA_DE_ALCANCE'       THEN 1 ELSE 0 END AS ok_estatus,
       CASE WHEN dcc.cliente_id IS NOT NULL
             AND dcc.canal_distribucion IN (10, 40, 60)            THEN 1 ELSE 0 END AS ok_canal,
       CASE WHEN dc.cliente_id IS NOT NULL
             AND dc.tipo_cliente <> 'SIN_RFC'                      THEN 1 ELSE 0 END AS ok_rfc
INTO   #alc
FROM   #fin f
LEFT JOIN gold.dim_cliente_comercial dcc
       ON  dcc.cliente_id = f.cliente_id
       AND f.fecha_documento >= dcc.fecha_inicio_vigencia
       AND (dcc.fecha_fin_vigencia IS NULL OR f.fecha_documento <= dcc.fecha_fin_vigencia)
LEFT JOIN gold.dim_cliente dc
       ON  dc.cliente_id = f.cliente_id;


/* =====================================================================================
   RESULTADO 1 - De que esta hecho el mes
   ===================================================================================== */
SELECT tipo_movimiento,
       COUNT(DISTINCT documento_id)                                          AS documentos,
       COUNT(*)                                                              AS lineas,
       SUM(monto)                                                            AS monto_sin_filtros,
       SUM(CASE WHEN ok_estatus = 1 AND ok_canal = 1 AND ok_rfc = 1
                THEN monto ELSE 0 END)                                       AS monto_con_filtros,
       SUM(CASE WHEN cuenta_como_cobranza = 1 THEN monto ELSE 0 END)         AS de_eso_entra_a_cobranza
FROM   #alc
WHERE  fecha_documento BETWEEN @ini AND @fin
GROUP BY tipo_movimiento
ORDER BY SUM(monto) DESC;


/* =====================================================================================
   RESULTADO 2 - EL NUMERO: sin filtros contra con filtros
   -------------------------------------------------------------------------------------
   Las devoluciones (FBZ2) van en su propia columna: son dinero que salio de verdad,
   pero no son una anulacion. Si se decide que la cobranza es NETA, se restan.
   ===================================================================================== */
SELECT 'Julio 2026, por fecha_documento'                                     AS base,

       SUM(CASE WHEN cuenta_como_cobranza = 1 THEN monto ELSE 0 END)         AS cobranza_sin_filtros,
       SUM(CASE WHEN cuenta_como_cobranza = 1
                 AND ok_estatus = 1 AND ok_canal = 1 AND ok_rfc = 1
                THEN monto ELSE 0 END)                                       AS cobranza_con_filtros,

       SUM(CASE WHEN tipo_movimiento = 'DEVOLUCION AL CLIENTE'
                THEN monto ELSE 0 END)                                       AS devoluciones_sin_filtros,
       SUM(CASE WHEN tipo_movimiento = 'DEVOLUCION AL CLIENTE'
                 AND ok_estatus = 1 AND ok_canal = 1 AND ok_rfc = 1
                THEN monto ELSE 0 END)                                       AS devoluciones_con_filtros
FROM   #alc
WHERE  fecha_documento BETWEEN @ini AND @fin;


/* =====================================================================================
   RESULTADO 3 - Cuanto quita cada filtro, por separado
   -------------------------------------------------------------------------------------
   Los tres no suman el total quitado: un mismo cliente puede fallar dos reglas a la vez.
   Por eso va tambien el efecto conjunto.
   ===================================================================================== */
SELECT SUM(CASE WHEN cuenta_como_cobranza = 1 THEN monto ELSE 0 END)                  AS total_sin_filtros,
       SUM(CASE WHEN cuenta_como_cobranza = 1 AND ok_estatus = 0 THEN monto ELSE 0 END) AS quita_fuera_de_alcance,
       SUM(CASE WHEN cuenta_como_cobranza = 1 AND ok_canal   = 0 THEN monto ELSE 0 END) AS quita_canal,
       SUM(CASE WHEN cuenta_como_cobranza = 1 AND ok_rfc     = 0 THEN monto ELSE 0 END) AS quita_sin_rfc,
       SUM(CASE WHEN cuenta_como_cobranza = 1
                 AND (ok_estatus = 0 OR ok_canal = 0 OR ok_rfc = 0)
                THEN monto ELSE 0 END)                                                  AS quita_los_tres_juntos
FROM   #alc
WHERE  fecha_documento BETWEEN @ini AND @fin;


/* =====================================================================================
   RESULTADO 4 - El mismo mes por fecha_contabilizacion
   -------------------------------------------------------------------------------------
   Es la fecha con la que SAP arma sus reportes de periodo. Se incluye para poder
   comparar contra el reporte de SAP; el presupuesto vive sobre fecha_documento.
   ===================================================================================== */
SELECT 'Julio 2026, por fecha_contabilizacion'                               AS base,
       SUM(CASE WHEN cuenta_como_cobranza = 1 THEN monto ELSE 0 END)         AS cobranza_sin_filtros,
       SUM(CASE WHEN cuenta_como_cobranza = 1
                 AND ok_estatus = 1 AND ok_canal = 1 AND ok_rfc = 1
                THEN monto ELSE 0 END)                                       AS cobranza_con_filtros
FROM   #alc
WHERE  fecha_contabilizacion BETWEEN @ini AND @fin;


/* =====================================================================================
   RESULTADO 5 - Contra lo que hoy reporta gold.fact_pagos
   -------------------------------------------------------------------------------------
   fact_pagos ya trae el alcance adentro (estatus + canal, NO el de RFC), asi que la
   comparacion honesta es contra la columna con filtros.
   ===================================================================================== */
SELECT (SELECT SUM(monto) FROM gold.fact_pagos
        WHERE fecha_documento BETWEEN @ini AND @fin)                         AS fact_pagos_hoy,
       (SELECT SUM(CASE WHEN cuenta_como_cobranza = 1
                         AND ok_estatus = 1 AND ok_canal = 1 AND ok_rfc = 1
                        THEN monto ELSE 0 END)
        FROM #alc WHERE fecha_documento BETWEEN @ini AND @fin)               AS regla_nueva_con_filtros,
       (SELECT SUM(CASE WHEN cuenta_como_cobranza = 1
                         AND ok_estatus = 1 AND ok_canal = 1
                        THEN monto ELSE 0 END)
        FROM #alc WHERE fecha_documento BETWEEN @ini AND @fin)               AS regla_nueva_mismo_alcance_que_fact_pagos;


/* =====================================================================================
   RESULTADO 6 - Control: las reversas del mes, una por una
   -------------------------------------------------------------------------------------
   Si aparece 'ORIGINAL NO LOCALIZADO' con monto relevante, ampliar @desde y repetir.
   ===================================================================================== */
SELECT destino_reversa,
       COUNT(*)     AS lineas,
       SUM(monto)   AS monto
FROM   #alc
WHERE  fecha_documento BETWEEN @ini AND @fin
AND    destino_reversa IS NOT NULL
GROUP BY destino_reversa
ORDER BY monto;
