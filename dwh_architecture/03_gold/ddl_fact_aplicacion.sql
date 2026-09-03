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
--    origen_efectivo (only for VIRGEN / PAGO_DIRECTO; NULL otherwise):
--      BANCO            VIRGEN - cash from the bank
--      DIRECTO          PAGO_DIRECTO whose document has no key-08 sibling - cash
--      REEMISION_SA     PAGO_DIRECTO whose 08 sibling's group holds no DZ credit of another
--                       document (typically an SA 'PAGO ATM-CIOSA' credit) - cash, counted
--                       here because SA is excluded everywhere else
--      REEMISION_DZ     PAGO_DIRECTO whose 08 sibling's group holds a DZ 11/15 credit of
--                       ANOTHER document - a previous deposit re-issued. NOT cash (already counted)
--    es_efectivo = 1 for origen_efectivo IN (BANCO, DIRECTO, REEMISION_SA). Real cash of a
--      period = SUM(monto) WHERE es_efectivo=1 AND revertido=0 AND es_reembolso=0.
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
    origen_efectivo          VARCHAR(16)   NULL,      -- BANCO / DIRECTO / REEMISION_SA / REEMISION_DZ, see header
    es_efectivo              BIT           NOT NULL,  -- origen_efectivo IN (BANCO, DIRECTO, REEMISION_SA)
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

-- Section 4 (fact_aplicacion) is added once the gate of section 3 passes - see DESIGN.md.
