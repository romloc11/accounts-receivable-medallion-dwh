USE ANALISIS_DATOS;
GO
/*
===============================================================================
PHASE 7 - fact_aplicacion (v2) vs gold.vw_pago_factura_simple, July 2026
READ-ONLY. Nothing here modifies either side.

Both strategies are put on the SAME footing before comparing:
  - month = fecha_contabilizacion of the payment in July 2026 (the field that matches
    SAP's own monthly payment report - both sides already use it);
  - customer scope of the view (canal 10/40/60, tipo_cliente <> SIN_RFC,
    estatus_comercial <> FUERA_DE_ALCANCE) applied to v2's cash origins too, so CP
    (99.6% channel 20) and out-of-scope accounts do not inflate v2 by construction;
  - "identified" on the view = estatus_identificacion = FACTURA_IDENTIFICADA;
    on v2 = at least one non-R0 row whose origin is the deposit.
Grain of the comparison: one row per cash deposit (v2 origin / view documento_pago).
===============================================================================
*/

-- ---------------------------------------------------------------------------
-- A. v2 cash origins of July, in the view's customer scope
-- ---------------------------------------------------------------------------
IF OBJECT_ID('tempdb..#v2') IS NOT NULL DROP TABLE #v2;
SELECT p.sociedad, p.cliente_id, p.ejercicio, p.documento_id, p.posicion, p.clase_documento, p.origen_efectivo,
       p.monto_moneda_local AS monto, p.revertido, p.es_reembolso, p.texto_virgen_valido, p.tipo_linea,
       ISNULL(x.identificado, 0) AS identificado,
       ISNULL(x.num_facturas, 0) AS num_facturas
INTO #v2
FROM gold.fact_pagos p
JOIN gold.dim_cliente k ON k.cliente_id = p.cliente_id
JOIN gold.dim_cliente_comercial dc
  ON dc.cliente_id = p.cliente_id
 AND p.fecha_contabilizacion >= dc.fecha_inicio_vigencia
 AND (dc.fecha_fin_vigencia IS NULL OR p.fecha_contabilizacion <= dc.fecha_fin_vigencia)
LEFT JOIN (
    SELECT documento_origen, ejercicio_origen, posicion_origen,
           SUM(monto_aplicado) AS identificado, COUNT(DISTINCT documento_recibe) AS num_facturas
    FROM gold.fact_aplicacion WHERE regla <> 'R0'
    GROUP BY documento_origen, ejercicio_origen, posicion_origen
) x ON x.documento_origen = p.documento_id AND x.ejercicio_origen = p.ejercicio AND x.posicion_origen = p.posicion
WHERE p.es_efectivo = 1
  AND p.fecha_contabilizacion >= '2026-07-01' AND p.fecha_contabilizacion < '2026-08-01'
  AND dc.canal_distribucion IN ('10','40','60')
  AND dc.estatus_comercial <> 'FUERA_DE_ALCANCE'
  AND k.tipo_cliente <> 'SIN_RFC';

-- ---------------------------------------------------------------------------
-- B. the view, July, one row per payment document
-- ---------------------------------------------------------------------------
IF OBJECT_ID('tempdb..#vw') IS NOT NULL DROP TABLE #vw;
SELECT documento_pago, MIN(fecha_pago) AS fecha_pago, MAX(monto_pago_virgen) AS monto_virgen,
       SUM(monto_pago_asignado) AS asignado,
       MAX(CASE WHEN estatus_identificacion = 'FACTURA_IDENTIFICADA' THEN 1 ELSE 0 END) AS identificada,
       MAX(motivo_no_identificado) AS motivo,
       COUNT(DISTINCT documento_factura) AS num_facturas
INTO #vw
FROM gold.vw_pago_factura_simple
WHERE fecha_pago >= '2026-07-01' AND fecha_pago < '2026-08-01'
GROUP BY documento_pago;

-- ---------------------------------------------------------------------------
-- 1. Totals: what each strategy calls "July cash" in the same scope
-- ---------------------------------------------------------------------------
SELECT 'view: SUM(monto_pago_asignado)'            AS medida, COUNT(*) AS pagos, SUM(asignado) AS monto FROM #vw
UNION ALL SELECT 'view: identificada',                       COUNT(*), SUM(asignado) FROM #vw WHERE identificada = 1
UNION ALL SELECT 'v2: efectivo (sin revertidos/reembolsos)', COUNT(*), SUM(monto) FROM #v2 WHERE revertido = 0 AND es_reembolso = 0
UNION ALL SELECT 'v2: identificado (monto aplicado)',        COUNT(*), SUM(identificado) FROM #v2 WHERE revertido = 0 AND es_reembolso = 0 AND identificado > 0
UNION ALL SELECT 'v2: DZ solamente - efectivo',              COUNT(*), SUM(monto) FROM #v2 WHERE revertido = 0 AND es_reembolso = 0 AND clase_documento = 'DZ'
UNION ALL SELECT 'v2: DZ solamente - identificado',          COUNT(*), SUM(identificado) FROM #v2 WHERE revertido = 0 AND es_reembolso = 0 AND clase_documento = 'DZ' AND identificado > 0
UNION ALL SELECT 'v2: CP - efectivo (fuera del alcance de la vista)', COUNT(*), SUM(monto) FROM #v2 WHERE revertido = 0 AND es_reembolso = 0 AND clase_documento = 'CP';

-- ---------------------------------------------------------------------------
-- 2. Payment-by-payment cross (DZ only - the view never has CP)
-- ---------------------------------------------------------------------------
SELECT
    CASE WHEN w.documento_pago IS NULL THEN 'solo v2'
         WHEN v.documento_id IS NULL THEN 'solo vista'
         ELSE 'ambos' END AS lado,
    CASE WHEN v.documento_id IS NULL THEN NULL WHEN v.revertido = 1 THEN 'revertido' WHEN v.es_reembolso = 1 THEN 'reembolso' ELSE 'efectivo' END AS v2_estado,
    CASE WHEN w.documento_pago IS NULL THEN NULL WHEN w.identificada = 1 THEN 'vista identifica' ELSE 'vista no identifica' END AS vista,
    CASE WHEN v.documento_id IS NULL THEN NULL WHEN v.identificado > 0 THEN 'v2 identifica' ELSE 'v2 no identifica' END AS v2,
    COUNT(*) AS pagos,
    SUM(COALESCE(v.monto, w.monto_virgen)) AS monto_pago,
    SUM(ISNULL(w.asignado, 0)) AS vista_asignado,
    SUM(ISNULL(v.identificado, 0)) AS v2_identificado
FROM (SELECT * FROM #v2 WHERE clase_documento = 'DZ') v
FULL OUTER JOIN #vw w ON w.documento_pago = v.documento_id
GROUP BY
    CASE WHEN w.documento_pago IS NULL THEN 'solo v2' WHEN v.documento_id IS NULL THEN 'solo vista' ELSE 'ambos' END,
    CASE WHEN v.documento_id IS NULL THEN NULL WHEN v.revertido = 1 THEN 'revertido' WHEN v.es_reembolso = 1 THEN 'reembolso' ELSE 'efectivo' END,
    CASE WHEN w.documento_pago IS NULL THEN NULL WHEN w.identificada = 1 THEN 'vista identifica' ELSE 'vista no identifica' END,
    CASE WHEN v.documento_id IS NULL THEN NULL WHEN v.identificado > 0 THEN 'v2 identifica' ELSE 'v2 no identifica' END
ORDER BY lado, monto_pago DESC;

-- ---------------------------------------------------------------------------
-- 3. "Solo vista": what are those payment documents in v2's line classification?
--    (the view counts some child re-application lines as cash)
-- ---------------------------------------------------------------------------
SELECT ISNULL(p.tipo_linea, 'no esta en fact_pagos') AS tipo_linea_v2, ISNULL(p.origen_efectivo, '-') AS origen_efectivo,
       COUNT(*) AS pagos, SUM(w.asignado) AS vista_asignado
FROM #vw w
LEFT JOIN gold.fact_pagos p ON p.documento_id = w.documento_pago AND p.fecha_contabilizacion = w.fecha_pago
WHERE NOT EXISTS (SELECT 1 FROM #v2 v WHERE v.documento_id = w.documento_pago)
GROUP BY ISNULL(p.tipo_linea, 'no esta en fact_pagos'), ISNULL(p.origen_efectivo, '-')
ORDER BY vista_asignado DESC;

-- ---------------------------------------------------------------------------
-- 4. Invoice agreement on payments both identify: same invoice set, or not
-- ---------------------------------------------------------------------------
IF OBJECT_ID('tempdb..#inv_vw') IS NOT NULL DROP TABLE #inv_vw;
SELECT DISTINCT documento_pago, documento_factura INTO #inv_vw
FROM gold.vw_pago_factura_simple
WHERE fecha_pago >= '2026-07-01' AND fecha_pago < '2026-08-01' AND estatus_identificacion = 'FACTURA_IDENTIFICADA';

IF OBJECT_ID('tempdb..#inv_v2') IS NOT NULL DROP TABLE #inv_v2;
SELECT DISTINCT a.documento_origen AS documento_pago, a.documento_recibe AS documento_factura INTO #inv_v2
FROM gold.fact_aplicacion a
JOIN #v2 v ON v.documento_id = a.documento_origen AND v.ejercicio = a.ejercicio_origen AND v.posicion = a.posicion_origen
WHERE a.regla <> 'R0' AND v.clase_documento = 'DZ';

SELECT caso, COUNT(*) AS pagos FROM (
    SELECT b.documento_pago,
           CASE WHEN NOT EXISTS (SELECT documento_factura FROM #inv_vw x WHERE x.documento_pago = b.documento_pago
                                 EXCEPT SELECT documento_factura FROM #inv_v2 y WHERE y.documento_pago = b.documento_pago)
                 AND NOT EXISTS (SELECT documento_factura FROM #inv_v2 y WHERE y.documento_pago = b.documento_pago
                                 EXCEPT SELECT documento_factura FROM #inv_vw x WHERE x.documento_pago = b.documento_pago)
                THEN 'mismas facturas'
                WHEN NOT EXISTS (SELECT documento_factura FROM #inv_v2 y WHERE y.documento_pago = b.documento_pago
                                 EXCEPT SELECT documento_factura FROM #inv_vw x WHERE x.documento_pago = b.documento_pago)
                THEN 'v2 es subconjunto de la vista'
                WHEN NOT EXISTS (SELECT documento_factura FROM #inv_vw x WHERE x.documento_pago = b.documento_pago
                                 EXCEPT SELECT documento_factura FROM #inv_v2 y WHERE y.documento_pago = b.documento_pago)
                THEN 'vista es subconjunto de v2'
                ELSE 'facturas distintas' END AS caso
    FROM (SELECT DISTINCT documento_pago FROM #inv_vw INTERSECT SELECT DISTINCT documento_pago FROM #inv_v2) b
) z GROUP BY caso ORDER BY pagos DESC;

-- ---------------------------------------------------------------------------
-- 5. Where v2 does not identify: reasons (DZ, in scope)
-- ---------------------------------------------------------------------------
SELECT a.motivo_no_identificado, COUNT(*) AS origenes, SUM(a.monto_aplicado) AS monto_no_identificado
FROM gold.fact_aplicacion a
JOIN #v2 v ON v.documento_id = a.documento_origen AND v.ejercicio = a.ejercicio_origen AND v.posicion = a.posicion_origen
WHERE a.regla = 'R0' AND v.clase_documento = 'DZ' AND v.revertido = 0 AND v.es_reembolso = 0
GROUP BY a.motivo_no_identificado ORDER BY monto_no_identificado DESC;

-- ---------------------------------------------------------------------------
-- 6. Where the view does not identify: its reasons, and what v2 does with the same payments
-- ---------------------------------------------------------------------------
SELECT w.motivo AS motivo_vista,
       CASE WHEN v.identificado > 0 THEN 'v2 identifica' WHEN v.documento_id IS NULL THEN 'v2 no lo tiene como efectivo' ELSE 'v2 tampoco' END AS v2,
       COUNT(*) AS pagos, SUM(w.asignado) AS monto
FROM #vw w
LEFT JOIN #v2 v ON v.documento_id = w.documento_pago AND v.clase_documento = 'DZ'
WHERE w.identificada = 0
GROUP BY w.motivo, CASE WHEN v.identificado > 0 THEN 'v2 identifica' WHEN v.documento_id IS NULL THEN 'v2 no lo tiene como efectivo' ELSE 'v2 tampoco' END
ORDER BY monto DESC;
GO
