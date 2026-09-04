USE ANALISIS_DATOS;
GO

/*
===============================================================================
PROJECT: Enterprise Data Warehouse (dwh-ciosa)
LAYER:   Gold - fact_aplicacion v2 strategy (PROTOTYPE, parallel to
         gold.vw_pago_factura_simple / fact_pagos_compensados /
         fact_facturas_compensadas, which are NOT touched by anything here)
AUTHOR:  Roman Alejandro Lopez
DESIGN:  DESIGN.md -> "Proposals in design" -> "gold.fact_aplicacion"

WHY A SEPARATE FILE: ddl_gold.sql is a whole-layer script (DROP + CREATE of
every gold table) and must never be run in full on a server with data. The v2
objects live here while they are a prototype; if the strategy wins the Phase 7
comparison they get merged into ddl_gold.sql / sp_load_gold.sql as regular
sections.

HOW TO RUN: one section at a time, in order (0 -> 4), validating the gate of
each section before creating the next (see sp_load_fact_aplicacion.sql for the
load procedures and the gate queries). Every section is IF OBJECT_ID ... DROP +
CREATE, so re-running a section recreates that object only.

NAMING: plural fact_* (user decision 2026-09-03). gold.fact_facturas /
gold.fact_pagos were the pre-2026-08-21 names of today's *_compensadas tables;
those objects and their procedures no longer exist on the server (verified
2026-09-03), so there is no collision - but if an old script references
gold.load_fact_pagos / gold.load_fact_facturas, that is the OLD procedure,
not these.
===============================================================================
*/

-- ============================================================================
-- 0. gold.dim_tipo_documento - conformed TYPE dimension (one row per BLART)
--    Not one row per document: document numbers stay on the facts as
--    degenerate dimensions. Populated by gold.load_dim_tipo_documento from a
--    static catalog (T003 / T003T verified in SAP GUI 2026-09-03 + the
--    findings of the investigation).
-- ============================================================================
IF OBJECT_ID('gold.dim_tipo_documento', 'U') IS NOT NULL DROP TABLE gold.dim_tipo_documento;
GO
CREATE TABLE gold.dim_tipo_documento (
    clase_documento         VARCHAR(2)   NOT NULL,  -- BLART
    descripcion_sap         VARCHAR(40)  NOT NULL,  -- T003T.LTEXT (SPRAS='S')
    descripcion_anterior    VARCHAR(20)  NULL,      -- legacy business label (FACT / PAGO / DEVO / ...), NULL when none
    familia                 VARCHAR(20)  NOT NULL,  -- FACTURA / NOTA_DEBITO / NOTA_CREDITO / DEVOLUCION / PAGO / AJUSTE / ANULACION / TECNICO / SIN_CATALOGAR
    signo_esperado          CHAR(1)      NULL,      -- S (debit) / H (credit) for the family's main line; NULL when mixed by nature
    es_ancla_compensacion   BIT          NOT NULL,  -- 1 = usually the document that anchors a compensation group (AB / Z1 / Z2 / Z3 / ZZ / SA)
    lado_aplicacion         VARCHAR(10)  NULL,      -- RECIBE (debt) / APLICA (money or credit) / NINGUNO
    en_alcance_aplicacion   BIT          NOT NULL,  -- 0 = never participates in fact_aplicacion (ZY, SA, SI, ZZ, DI)
    clase_anulacion         VARCHAR(2)   NULL,      -- T003.STBLA: document type that reverses this one (DZ->DZ, CP->CP, AB->AB, F*->Z1, C1/C3/C4->Z2, C5->Z3, D1->Z4, SA/SI/ZY->ZZ)
    clases_cuenta           VARCHAR(5)   NULL,      -- T003.KOARS: account types allowed (A assets, D customers, K vendors, M materials, S G/L)
    rango_numeros           VARCHAR(2)   NULL,      -- T003.NUMKR
    nota                    VARCHAR(400) NULL,      -- one-line summary of what the investigation found for this type
    fecha_carga             DATETIME     DEFAULT GETDATE(),
    CONSTRAINT PK_dim_tipo_documento PRIMARY KEY (clase_documento)
);
PRINT 'Table gold.dim_tipo_documento created.';
GO

-- ============================================================================
-- 1. gold.fact_facturas - every DEBT document (F1-F6 + D1), open or cleared
--    Grain: 1 line of silver.sap_bsid U silver.sap_bsad. Same natural key as
--    the silver tables (minus mandante). Receiving side of fact_aplicacion.
-- ============================================================================
IF OBJECT_ID('gold.fact_facturas', 'U') IS NOT NULL DROP TABLE gold.fact_facturas;
GO
CREATE TABLE gold.fact_facturas (
    sociedad                 VARCHAR(4)    NOT NULL,
    cliente_id               VARCHAR(10)   NOT NULL,
    ejercicio                INT           NOT NULL,
    documento_id             VARCHAR(10)   NOT NULL,
    posicion                 INT           NOT NULL,

    clase_documento          VARCHAR(2)    NOT NULL,  -- F1-F6, D1
    clave_contabilizacion    VARCHAR(2)    NULL,      -- BSCHL (01 = invoice, 04 = other receivable, ...)
    debe_haber               CHAR(1)       NULL,      -- SHKZG; amounts are NEVER signed in silver, apply this when netting
    estado_sap               VARCHAR(10)   NOT NULL,  -- ABIERTO (from bsid) / COMPENSADO (from bsad) / REVERTIDO (vanished from both while open - never deleted)

    fecha_documento          DATE          NULL,
    fecha_contabilizacion    DATE          NULL,      -- BUDAT: the period field that matches SAP's own reports
    fecha_registro_sistema   DATE          NULL,      -- CPUDT: when it was actually keyed in
    fecha_vencimiento        DATE          NULL,      -- ZFBDT + ZBD1T (already corrected in silver)
    condicion_pago           VARCHAR(4)    NULL,
    dias_plazo               DECIMAL(15,2) NULL,

    monto_moneda_local       DECIMAL(15,2) NOT NULL,
    monto_moneda_doc         DECIMAL(15,2) NULL,
    moneda                   VARCHAR(5)    NULL,

    documento_compensacion   VARCHAR(10)   NULL,      -- AUGBL, NULL while ABIERTO
    ejercicio_compensacion   INT           NULL,      -- AUGGJ
    fecha_compensacion       DATE          NULL,      -- AUGDT

    documento_ventas         VARCHAR(10)   NULL,      -- VBELN
    referencia               VARCHAR(16)   NULL,      -- XBLNR
    asignacion               VARCHAR(18)   NULL,      -- ZUONR

    anulada                  BIT           NOT NULL DEFAULT 0,  -- 1 = a Z1 line shares this document's compensation group at the identical amount (rule R2a)
    documento_anulacion      VARCHAR(10)   NULL,
    fecha_anulacion          DATE          NULL,

    cliente_comercial_sk     INT           NULL,      -- gold.dim_cliente_comercial.id_surrogate, resolved temporally on fecha_contabilizacion
    cliente_credito_sk       INT           NULL,      -- gold.dim_cliente_credito.id_surrogate, idem

    fecha_carga              DATETIME      DEFAULT GETDATE(),
    fecha_actualizacion      DATETIME      NULL,
    CONSTRAINT PK_fact_facturas PRIMARY KEY (sociedad, cliente_id, ejercicio, documento_id, posicion)
);
GO
-- The group key is how every application rule finds this invoice's partners.
CREATE INDEX IX_fact_facturas_grupo ON gold.fact_facturas (documento_compensacion, ejercicio_compensacion);
-- Lookup by document number (REBZG -> invoice) without the customer.
CREATE INDEX IX_fact_facturas_documento ON gold.fact_facturas (documento_id, ejercicio, posicion);
PRINT 'Table gold.fact_facturas created.';
GO

-- ============================================================================
-- 2. gold.fact_notas - credit notes and returns (C1, C3, C4, C5), open or
--    cleared. Applying side of fact_aplicacion (rule R1 via REBZG).
--    Same grain and key as fact_facturas. Gate of section 1 passed 2026-09-03.
-- ============================================================================
IF OBJECT_ID('gold.fact_notas', 'U') IS NOT NULL DROP TABLE gold.fact_notas;
GO
CREATE TABLE gold.fact_notas (
    sociedad                 VARCHAR(4)    NOT NULL,
    cliente_id               VARCHAR(10)   NOT NULL,
    ejercicio                INT           NOT NULL,
    documento_id             VARCHAR(10)   NOT NULL,
    posicion                 INT           NOT NULL,

    clase_documento          VARCHAR(2)    NOT NULL,  -- C1, C3, C4 (returns), C5 (credit note)
    clave_contabilizacion    VARCHAR(2)    NULL,      -- BSCHL (11 = credit memo, ...)
    debe_haber               CHAR(1)       NULL,      -- SHKZG, expected H
    estado_sap               VARCHAR(10)   NOT NULL,  -- ABIERTO / COMPENSADO / REVERTIDO

    fecha_documento          DATE          NULL,
    fecha_contabilizacion    DATE          NULL,
    fecha_registro_sistema   DATE          NULL,
    fecha_vencimiento        DATE          NULL,

    monto_moneda_local       DECIMAL(15,2) NOT NULL,
    monto_moneda_doc         DECIMAL(15,2) NULL,
    moneda                   VARCHAR(5)    NULL,

    documento_compensacion   VARCHAR(10)   NULL,
    ejercicio_compensacion   INT           NULL,
    fecha_compensacion       DATE          NULL,

    sgtxt                    VARCHAR(50)   NULL,
    factura_referencia_documento VARCHAR(10) NULL,   -- REBZG: the invoice this note applies to (95-100% populated for C1/C3/C4, 87.5% for C5)
    factura_referencia_ejercicio INT         NULL,
    factura_referencia_posicion  INT         NULL,

    documento_ventas         VARCHAR(10)   NULL,
    referencia               VARCHAR(16)   NULL,
    asignacion               VARCHAR(18)   NULL,

    anulada                  BIT           NOT NULL DEFAULT 0,  -- Z2 (C1/C3/C4) or Z3 (C5) sharing the group at the identical amount (rule R2a)
    documento_anulacion      VARCHAR(10)   NULL,
    fecha_anulacion          DATE          NULL,

    cliente_comercial_sk     INT           NULL,
    cliente_credito_sk       INT           NULL,

    fecha_carga              DATETIME      DEFAULT GETDATE(),
    fecha_actualizacion      DATETIME      NULL,
    CONSTRAINT PK_fact_notas PRIMARY KEY (sociedad, cliente_id, ejercicio, documento_id, posicion)
);
GO
CREATE INDEX IX_fact_notas_grupo ON gold.fact_notas (documento_compensacion, ejercicio_compensacion);
CREATE INDEX IX_fact_notas_ref   ON gold.fact_notas (factura_referencia_documento, factura_referencia_ejercicio, factura_referencia_posicion);
PRINT 'Table gold.fact_notas created.';
GO

-- ============================================================================
-- 3. gold.fact_pagos - every DZ and CP line, open or cleared, classified by
--    posting key and document shape. Applying side of fact_aplicacion.
--    Gate of section 2 passed 2026-09-03.
--
--    A "child" (hijo) = a document that at least one VIRGEN (key 11) line points to
--    through its documento_compensacion. NOT "a document with a key-08 line": the
--    deposit program also posts documents with an 08 + 15 pair that no virgin points
--    to (e.g. DZ 1402633332, $12.75M: 08 'DISPERSION ATM' consumes SA 'PAGO ATM-CIOSA',
--    15 re-issues it as a deposit) - found 2026-09-03 while gating this table.
--
--    tipo_linea (derived, the column every rule and gate keys off):
--      VIRGEN           DZ key 11 - the raw bank deposit (REBZG='V')
--      PAGO_DIRECTO     DZ key 15 in a document that is NOT a child, and CP key 15
--      APLICACION_HIJO  DZ key 15/17/18 (H) inside a child - re-applying a deposit to invoices. NOT cash.
--      ESPEJO_HIJO      DZ key 08 (S) inside a child - the mirror of the deposit. NOT cash.
--      TRASPASO_08      DZ key 08 (S) in a non-child document - consumes some other credit (see origen_efectivo of its 15 sibling)
--      CONSUME_CREDITO  DZ key 07 (S) - clears an existing credit, like AB 07
--      REVERSO          key 02/05/12 (S) - the FB08 reversal document's own line
--      OTRO             01/04/06/16 - manual postings and payment differences
--    origen_efectivo (only for VIRGEN / PAGO_DIRECTO; NULL otherwise). For a PAGO_DIRECTO
--    whose document carries a key-08 sibling, the origin is what that 08 line consumes in
--    ITS compensation group (checked 2026-09-03 on the July+ window: every such line had an
--    identifiable origin):
--      BANCO              VIRGEN - cash from the bank
--      DIRECTO            PAGO_DIRECTO with no key-08 sibling - cash
--      REEMISION_PAGO_SA  the 08 group holds an SA credit with text 'PAGO%' (e.g. 'PAGO
--                         ATM-CIOSA', $12.75M) and NO DZ/CP/C* credit of another document
--                         (AB 07/17 allowed - it is FB1D's transfer vehicle) - cash, counted
--                         here because SA is excluded everywhere else
--      REEMISION_CREDITO  the 08 group holds a DZ/CP/C1/C3/C4/C5 credit of ANOTHER document
--                         - a deposit / return already counted, re-issued. NOT cash
--      REEMISION_AJUSTE_SA the 08 group holds only SA credits without 'PAGO%' (e.g.
--                         'COMISIONES MELI JUN 26' - marketplace commissions netted, no money
--                         received) - NOT cash
--    es_efectivo = 1 for origen_efectivo IN (BANCO, DIRECTO, REEMISION_PAGO_SA). Real cash
--      of a period = SUM(monto) WHERE es_efectivo=1 AND revertido=0 AND es_reembolso=0.
-- ============================================================================
IF OBJECT_ID('gold.fact_pagos', 'U') IS NOT NULL DROP TABLE gold.fact_pagos;
GO
CREATE TABLE gold.fact_pagos (
    sociedad                 VARCHAR(4)    NOT NULL,
    cliente_id               VARCHAR(10)   NOT NULL,
    ejercicio                INT           NOT NULL,
    documento_id             VARCHAR(10)   NOT NULL,
    posicion                 INT           NOT NULL,

    clase_documento          VARCHAR(2)    NOT NULL,  -- DZ, CP
    clave_contabilizacion    VARCHAR(2)    NULL,      -- BSCHL
    debe_haber               CHAR(1)       NULL,
    estado_sap               VARCHAR(10)   NOT NULL,  -- ABIERTO / COMPENSADO / REVERTIDO
    tipo_linea               VARCHAR(16)   NOT NULL,  -- see header
    origen_efectivo          VARCHAR(20)   NULL,      -- BANCO / DIRECTO / REEMISION_PAGO_SA / REEMISION_CREDITO / REEMISION_AJUSTE_SA, see header
    es_efectivo              BIT           NOT NULL,  -- origen_efectivo IN (BANCO, DIRECTO, REEMISION_PAGO_SA)
    es_pago_virgen           BIT           NOT NULL,  -- VIRGEN only (kept for comparison with fact_pagos_compensados)
    texto_virgen_valido      BIT           NOT NULL,  -- sgtxt = 'Asignación Aut. Deposito' OR LIKE 'BB%' (the text safeguard validated on fact_pagos_compensados)

    fecha_documento          DATE          NULL,
    fecha_contabilizacion    DATE          NULL,      -- the period field that matches SAP's own monthly payment report
    fecha_registro_sistema   DATE          NULL,
    fecha_vencimiento        DATE          NULL,

    monto_moneda_local       DECIMAL(15,2) NOT NULL,
    monto_moneda_doc         DECIMAL(15,2) NULL,
    moneda                   VARCHAR(5)    NULL,

    documento_compensacion   VARCHAR(10)   NULL,
    ejercicio_compensacion   INT           NULL,
    fecha_compensacion       DATE          NULL,

    sgtxt                    VARCHAR(50)   NULL,
    factura_referencia_documento VARCHAR(10) NULL,   -- REBZG; 'V' kept raw here (= no reference), interpreted as NULL by fact_aplicacion
    factura_referencia_ejercicio INT         NULL,
    factura_referencia_posicion  INT         NULL,

    documento_hijo           VARCHAR(10)   NULL,      -- VIRGEN only: the document that cleared it (= its documento_compensacion). A DZ with a key-08 line = the child; anything else = cleared directly
    ejercicio_hijo           INT           NULL,

    revertido                BIT           NOT NULL DEFAULT 0,  -- rule R2b: its group is exactly 2 documents of the same type, nets to zero and contains a reversal key (02/05/12)
    documento_reverso        VARCHAR(10)   NULL,
    es_reembolso             BIT           NOT NULL DEFAULT 0,  -- the vw_pago_factura_simple rule: sole cash candidate of its group and an SA 'REEM%' line matches it within $1.00
    documento_reembolso      VARCHAR(10)   NULL,

    referencia               VARCHAR(16)   NULL,
    asignacion               VARCHAR(18)   NULL,

    cliente_comercial_sk     INT           NULL,
    cliente_credito_sk       INT           NULL,

    fecha_carga              DATETIME      DEFAULT GETDATE(),
    fecha_actualizacion      DATETIME      NULL,
    CONSTRAINT PK_fact_pagos PRIMARY KEY (sociedad, cliente_id, ejercicio, documento_id, posicion)
);
GO
CREATE INDEX IX_fact_pagos_grupo ON gold.fact_pagos (documento_compensacion, ejercicio_compensacion);
CREATE INDEX IX_fact_pagos_ref   ON gold.fact_pagos (factura_referencia_documento, factura_referencia_ejercicio, factura_referencia_posicion);
CREATE INDEX IX_fact_pagos_hijo  ON gold.fact_pagos (documento_hijo, ejercicio_hijo);
PRINT 'Table gold.fact_pagos created.';
GO

-- ============================================================================
-- 4. gold.fact_aplicacion - one row = one monetary application between a line
--    that applies money/credit and a debt document that receives it.
--    Gate of section 3 passed 2026-09-03.
--
--    Three roles per row (all degenerate document keys):
--      aplica  - the VEHICLE: the line that sits in the receiving document's compensation
--                group or carries the REBZG reference (a direct payment, a child's key-15
--                line, a credit note, an AB key-17/15 line)
--      origen  - where the money/credit comes from: the virgin deposit behind a child line,
--                the credit consumed by an AB line's key-07 twin, or the vehicle itself
--      recibe  - the debt document (fact_facturas: F1-F6, D1). NULL on unidentified rows.
--    tipo_aplicacion follows the ORIGIN: PAGO (cash), NOTA_CREDITO, DEVOLUCION,
--    CREDITO_REAPLICADO (AB 17), SALDO_A_FAVOR (AB 15 from the pool account).
--    monto_aplicado is the only additive amount. Rules (regla): R1 = REBZG (certainty 1),
--    R3 = single receiving document in the group (2), R0 = unidentified remainder of an
--    origin (receiving side NULL). No proportional allocation anywhere.
-- ============================================================================
IF OBJECT_ID('gold.fact_aplicacion', 'U') IS NOT NULL DROP TABLE gold.fact_aplicacion;
GO
CREATE TABLE gold.fact_aplicacion (
    id_aplicacion                INT IDENTITY(1,1) NOT NULL,

    -- vehicle
    sociedad                     VARCHAR(4)    NOT NULL,
    documento_aplica             VARCHAR(10)   NOT NULL,
    ejercicio_aplica             INT           NOT NULL,
    posicion_aplica              INT           NOT NULL,
    clase_documento_aplica       VARCHAR(2)    NOT NULL,
    clave_contabilizacion_aplica VARCHAR(2)    NULL,
    cliente_pagador_id           VARCHAR(10)   NOT NULL,
    fecha_aplica                 DATE          NULL,      -- fecha_contabilizacion of the vehicle
    monto_documento_aplica       DECIMAL(15,2) NOT NULL,  -- full amount of the vehicle line, repeated per row - never SUM it

    -- origin
    documento_origen             VARCHAR(10)   NULL,
    ejercicio_origen             INT           NULL,
    posicion_origen              INT           NULL,
    clase_documento_origen       VARCHAR(2)    NULL,
    fecha_origen                 DATE          NULL,      -- fecha_contabilizacion of the origin (the real deposit date for a chain)
    monto_documento_origen       DECIMAL(15,2) NULL,
    saltos                       TINYINT       NOT NULL DEFAULT 0,  -- 0 = vehicle is its own origin, 1 = virgin -> child, 2 = virgin -> child -> grandchild

    -- receiving (NULL when unidentified)
    documento_recibe             VARCHAR(10)   NULL,
    ejercicio_recibe             INT           NULL,
    posicion_recibe              INT           NULL,
    clase_documento_recibe       VARCHAR(2)    NULL,
    cliente_factura_id           VARCHAR(10)   NULL,
    fecha_factura                DATE          NULL,
    fecha_vencimiento            DATE          NULL,
    monto_documento_recibe       DECIMAL(15,2) NULL,
    estado_recibe                VARCHAR(10)   NULL,      -- ABIERTO (partial payment in progress) / COMPENSADO

    -- measure
    monto_aplicado               DECIMAL(15,2) NOT NULL,

    -- classification
    tipo_aplicacion              VARCHAR(20)   NOT NULL,  -- PAGO / NOTA_CREDITO / DEVOLUCION / CREDITO_REAPLICADO / SALDO_A_FAVOR
    estatus_identificacion       VARCHAR(20)   NOT NULL,  -- IDENTIFICADA / NO_IDENTIFICADA
    motivo_no_identificado       VARCHAR(30)   NULL,      -- SIN_DOCUMENTO_EN_GRUPO / GRUPO_AMBIGUO / CADENA_AMBIGUA / ORIGEN_ABIERTO / SIN_REGLA

    -- traceability
    documento_compensacion       VARCHAR(10)   NULL,      -- group where vehicle and receiving document met (NULL when the receiving is still open)
    ejercicio_compensacion       INT           NULL,
    fecha_compensacion           DATE          NULL,
    fuente_sap                   VARCHAR(10)   NOT NULL,  -- BSAD / BSID / BSAD+BSID
    regla                        VARCHAR(4)    NOT NULL,  -- R1 / R3 / R0
    nivel_certeza                TINYINT       NOT NULL,  -- 1 = SAP's own pointer, 2 = single receiving document in the group, 0 = unidentified
    origen_resuelto              BIT           NOT NULL DEFAULT 1,  -- 0 when the chain behind a child line has 2+ candidate deposits

    moneda                       VARCHAR(5)    NULL,
    cliente_comercial_sk         INT           NULL,      -- of the payer, resolved on fecha_origen (the real deposit date)
    cliente_credito_sk           INT           NULL,
    fecha_carga                  DATETIME      DEFAULT GETDATE(),
    CONSTRAINT PK_fact_aplicacion PRIMARY KEY (id_aplicacion)
);
GO
CREATE INDEX IX_fact_aplicacion_recibe  ON gold.fact_aplicacion (documento_recibe, ejercicio_recibe, posicion_recibe);
CREATE INDEX IX_fact_aplicacion_origen  ON gold.fact_aplicacion (documento_origen, ejercicio_origen, posicion_origen);
CREATE INDEX IX_fact_aplicacion_aplica  ON gold.fact_aplicacion (documento_aplica, ejercicio_aplica, posicion_aplica);
CREATE INDEX IX_fact_aplicacion_fecha   ON gold.fact_aplicacion (fecha_aplica);
PRINT 'Table gold.fact_aplicacion created.';
GO
