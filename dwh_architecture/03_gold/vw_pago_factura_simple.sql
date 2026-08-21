-- ==========================================================
-- gold.vw_pago_factura_simple : relacion pago virgen <-> factura
-- Fuente: gold.fact_pagos_compensados / gold.fact_facturas_compensadas (formalizadas en ddl_gold.sql
-- / sp_load_gold.sql 2026-08-19 - reemplazan a las vistas prototipo
-- gold.vw_pago_virgen / gold.vw_factura, ya retiradas).
--
-- Solo relaciona grupos donde hay EXACTAMENTE 1 pago virgen candidato -
-- si 2+ pagos virgenes comparten el mismo grupo de compensacion, no se
-- puede saber con certeza cual pago cubrio cual factura, asi que se deja
-- fuera (mismo principio de "no adivinar" ya usado en el resto del
-- proyecto) en vez de forzar un match arbitrario.
--
-- DIRECCION_ALTERNA se excluye por completo (confirmado 2026-08-19: 9 de 10
-- cuentas de ese tipo dentro del alcance de canal son tecnicas de
-- conciliacion: Kushky/Conekta-Oxxo/Openpay/Mercado Libre/Mercado Pago
-- "INGRESOS TRANSITORIA", SALDO A FAVOR CUENTAS, DEPOSITOS NO IDENTIFICADOS,
-- etc. - ninguna representa un cliente real).
--
-- GENERICO (RFC XAXX010101000/XEXX010101000) SI se incluye - decision de
-- negocio 2026-08-20: se le mostro al dueño del proceso de negocio la lista
-- completa de clientes genericos (Mercado Libre, mostrador, empleados,
-- pruebas, clientes extranjeros, etc.) y confirmo que deben considerarse,
-- "son parte del flujo". Esto revierte la exclusion de GENERICO que
-- existio del 2026-08-19 al 2026-08-20.
--
-- FILTRO POR RFC UNICO POR GRUPO (reemplaza a la exclusion de GENERICO como
-- salvaguarda de calidad de datos): en vez de bloquear por tipo de cliente,
-- se bloquea por grupo de compensacion - solo se incluyen pagos cuyo grupo
-- de compensacion completo (en silver.sap_bsad, todas las lineas, no solo
-- pago+factura) pertenece a un UNICO RFC real. Esto SI permite cruces
-- legitimos de cliente_id dentro del mismo RFC (la misma persona/empresa
-- con varias cuentas, ej. 2000388/2001416 = RFC GUGG850717SS6), pero
-- excluye lotes donde se mezclan RFCs de verdad distintos (cuentas tecnicas
-- de marketplace mezclandose entre si, etc.). Medido 2026-08-20 sobre el
-- historico completo de clientes GENERICO en canal 10/40/60: apenas 430
-- pagos / $315,923 (0.12% del monto) caen en grupos con 2+ RFC distintos -
-- esos son los unicos que este filtro excluye; el otro 99.88% ($258M) pasa
-- sin problema.
--
-- clasificacion_cobranza agregada 2026-08-19 (primera etapa del reporte de
-- comportamiento de pago / cumplimiento de presupuesto - la mitad de
-- "cuanto entro y a que cartera corresponde", NO la mitad de "presupuesto
-- esperado" que todavia no se construye): clasifica cada pago segun si la
-- factura que liquido ya estaba vencida antes del mes del pago, vencia ese
-- mismo mes, o vencia en un mes futuro (pago anticipado) - comparando
-- fecha_vencimiento contra el propio mes de fecha_pago (no un mes fijo, la
-- vista sigue sin fecha "quemada", el filtro de periodo se aplica al
-- consultar).
--
-- CLIENTE_LEGAL RETIRADO 2026-08-20: originalmente tenia prioridad sobre la
-- clasificacion de vencimiento (un cliente en legal se etiquetaba como tal
-- sin importar cuando vencia su factura). Se quito porque no es confiable
-- hacia atras en el tiempo: dim_cliente_comercial es SCD2, pero su version
-- INICIAL de cada cliente fue retrasada artificialmente a 2020-01-01
-- (fix_vigencia_inicial_scd2.sql) solo para permitir el join temporal con
-- facts historicos - no representa una transicion real observada. Un
-- cliente que se volvio LEGAL apenas hace unos meses, y nunca tuvo otra
-- transicion de estatus capturada por el SCD2, aparecia con estatus LEGAL
-- desde 2020-01-01 en dim_cliente_comercial - el join temporal etiquetaba
-- como CLIENTE_LEGAL pagos de 2022-2025 en los que ese cliente en realidad
-- pagaba con normalidad. Ahora estos pagos se clasifican igual que
-- cualquier otro cliente (VENCIDA/DEL_MES/ANTICIPADO por fecha real).
-- estatus_comercial/canal_distribucion siguen expuestos como columnas de
-- la vista (el join temporal a dim_cliente_comercial sigue existiendo,
-- solo dejo de usarse para la clasificacion) - misma limitante de
-- confiabilidad historica aplica si se usan para filtrar/agrupar hacia
-- atras en el tiempo.
-- ==========================================================
IF OBJECT_ID('gold.vw_pago_factura_simple', 'V') IS NOT NULL DROP VIEW gold.vw_pago_factura_simple;
GO
CREATE VIEW gold.vw_pago_factura_simple AS
WITH pagos_por_grupo AS (
    SELECT
        documento_compensacion,
        ejercicio_compensacion,
        COUNT(*) AS num_pagos_candidatos
    FROM gold.fact_pagos_compensados
    GROUP BY documento_compensacion, ejercicio_compensacion
),
grupo_rfc_unico AS (
    SELECT b.documento_compensacion, b.ejercicio_compensacion
    FROM silver.sap_bsad b
    INNER JOIN gold.dim_cliente k ON k.cliente_id = b.cliente_id
    GROUP BY b.documento_compensacion, b.ejercicio_compensacion
    HAVING COUNT(DISTINCT k.rfc) = 1
)
SELECT
    p.cliente_id,
    k.nombre,
    dc.canal_distribucion,
    dc.estatus_comercial,
    p.documento_id        AS documento_pago,
    p.fecha_documento     AS fecha_pago,
    p.monto_moneda_local  AS monto_pago_virgen,
    f.documento_id        AS documento_factura,
    f.fecha_documento     AS fecha_factura,
    f.fecha_vencimiento,
    f.monto_moneda_local  AS monto_factura,
    DATEDIFF(DAY, f.fecha_vencimiento, p.fecha_documento) AS dias_pago, -- negativo = pago antes de vencer, positivo = pago tarde
    CASE
        WHEN f.fecha_vencimiento < DATEFROMPARTS(YEAR(p.fecha_documento), MONTH(p.fecha_documento), 1) THEN 'CARTERA_VENCIDA'
        WHEN f.fecha_vencimiento <= EOMONTH(p.fecha_documento) THEN 'CARTERA_DEL_MES'
        ELSE 'PAGO_ANTICIPADO'
    END AS clasificacion_cobranza
FROM gold.fact_pagos_compensados p
INNER JOIN pagos_por_grupo g
    ON g.documento_compensacion = p.documento_compensacion
   AND g.ejercicio_compensacion = p.ejercicio_compensacion
   AND g.num_pagos_candidatos = 1
INNER JOIN grupo_rfc_unico gr
    ON gr.documento_compensacion = p.documento_compensacion
   AND gr.ejercicio_compensacion = p.ejercicio_compensacion
INNER JOIN gold.fact_facturas_compensadas f
    ON f.documento_compensacion = p.documento_compensacion
   AND f.ejercicio_compensacion = p.ejercicio_compensacion
INNER JOIN gold.dim_cliente_comercial dc
    ON dc.cliente_id = p.cliente_id
   AND p.fecha_documento BETWEEN dc.fecha_inicio_vigencia AND ISNULL(dc.fecha_fin_vigencia, '99991231')
INNER JOIN gold.dim_cliente k
    ON k.cliente_id = p.cliente_id
INNER JOIN gold.dim_cliente kf
    ON kf.cliente_id = f.cliente_id
WHERE dc.canal_distribucion IN ('10', '40', '60')
  AND dc.estatus_comercial <> 'FUERA_DE_ALCANCE'
  AND k.tipo_cliente <> 'DIRECCION_ALTERNA'
  AND kf.tipo_cliente <> 'DIRECCION_ALTERNA';
GO
