/*
========================================================================================
PROJECT: Data Centralization - Medallion Architecture (Bronze Layer)
SOURCE SYSTEM: SAP ERP (Instance P01) / Database: P01
TARGET SYSTEM: SQL Server (DWH) / Database: ANALISIS_DATOS
SCHEMA: bronze
OBJECT: bronze.load_bronze (Stored Procedure)

NOTE ON STYLE: mirrors the structure, punctuation and syntax of a previously working
backup procedure on this SQL Server 2012 instance (bronze.load_bronze_bk) - no
semicolons after simple statements, DATETIME/GETDATE() instead of DATETIME2/
SYSDATETIME(). Earlier versions with extra syntax (explicit column lists in large
INSERT...SELECT, CREATE OR ALTER) repeatedly failed with "Incorrect syntax near ')'"
on this instance for reasons that could not be pinned down after extensive isolated
testing.

CONFIRMED CAUSE: calling control.sp_log_load (the audit-logging procedure defined in
ddl_bronze.sql) from within this procedure reproduces the same "Incorrect syntax near
')'" error, even though control.sp_log_load compiles and can presumably be called on
its own. It was removed from every section (and from the CATCH block) for that reason.
control.sap_load_control therefore is NOT populated by this procedure - there is
currently no persisted audit trail of runs, only the PRINT output visible while it
runs. THROW is still active in the CATCH block, so a failure still propagates to
whatever called this procedure (a SQL Agent job will correctly report failure) - it
is only the row-level audit logging that had to be dropped.

If the audit trail is needed later, investigate calling control.sp_log_load in
isolation (outside this procedure, with hardcoded literal arguments) before
re-attempting to wire it back in here - do not re-add it directly into this procedure
without that isolated confirmation first, since every previous attempt to do so broke
the whole batch.
========================================================================================

OVERVIEW:
Loads the 8 core SAP tables plus 2 reference/lookup tables from P01.p01 into
the Bronze staging area of ANALISIS_DATOS, in one sequential run:
- sap_kna1, sap_knvp, sap_knkk, sap_knvv, sap_bsid, sap_knb1, sap_knb5,
  sap_tvv1t, sap_pa0001: Full Truncate & Load (current SAP snapshot fully
  replaces what's in bronze each run).
- sap_bkpf: Incremental MERGE by primary key (MANDT, BUKRS, BELNR, GJAHR), filtered
  to BLART = 'DZ' and to the current + previous month via BUDAT. Gives the document
  header that BSAD/BSID lack: STBLG/STJAH (which document reverses which), STGRD
  (why) and TCODE/USNAM (which transaction and user created it). History loaded once
  via sp_backfill_bkpf.sql.
- sap_bsad: Incremental MERGE by primary key (MANDT, BUKRS, KUNNR, GJAHR, BELNR,
  BUZEI), filtered to the current + previous month via AUGDT. The full multi-year
  history was loaded once via a separate one-time backfill (see sp_backfill_bsad.sql);
  this keeps only the recent window in sync going forward.
- sap_bsas: Incremental MERGE by primary key (MANDT, BUKRS, HKONT, GJAHR, BELNR, BUZEI),
  filtered to cash accounts (HKONT 111xxx/113xxx) and to the current + previous month via
  AUGDT - the clearing date, because a line enters BSAS when it is cleared and keeps an
  old BUDAT (see the section note). The BANK side of a payment, which BSAD cannot show: BSAD's HKONT is the customer
  reconciliation account, never the bank. This is what the company's own monthly cash
  report is built on. History loaded once via sp_backfill_bsas.sql.
- sap_bsis: Full reload in year chunks, same cash-account scope. NOT a merge: an open
  item disappears from BSIS the day it is cleared, and a line of any age can disappear,
  so no date window would ever notice. Same reasoning as sap_bsid.
- sap_tvv1t / sap_pa0001: added to support the customer active/legal/inactive
  classification logic (see ciosa.py business rules, being ported to silver).
  sap_tvv1t resolves KVGR1 "ruta" codes to their readable BEZEI name;
  sap_pa0001 resolves PERNR to the employee's real name (ENAME) for the
  vendedor/ejecutivo de credito/gerente/cobrador partner-function roles.

NOTE ON sap_ausp / sap_bseg / sap_vbrk / sap_vbrp: intentionally not implemented.
sap_bseg additionally CANNOT be implemented - it is an SAP cluster table and does not
exist in P01 (verified 2026-09-11). bronze.sap_bsas/sap_bsis are the readable secondary
indexes that replace it for G/L line items.
See ddl_bronze.sql for the full notes on each. sap_bkpf WAS in that list and came
back 2026-09-11 with a concrete consumer - see its note in ddl_bronze.sql.
========================================================================================
*/

USE [ANALISIS_DATOS]
GO

IF OBJECT_ID('bronze.load_bronze', 'P') IS NOT NULL
    DROP PROCEDURE bronze.load_bronze
GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

CREATE PROCEDURE [bronze].[load_bronze]
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @start_time DATETIME,
            @end_time DATETIME,
            @batch_start_time DATETIME,
            @batch_end_time DATETIME,
            @mes_anterior_inicio NVARCHAR(8),
            @bsis_yr INT,
            @current_table NVARCHAR(128)

    BEGIN TRY

        SET @batch_start_time = GETDATE()

        PRINT '=================================================='
        PRINT '             Loading Bronze Layer (SAP)           '
        PRINT '=================================================='

        /* ==========================================================
           1. CUSTOMER MASTER (KNA1) - Full Truncate & Load
        ========================================================== */
        SET @current_table = 'bronze.sap_kna1'
        SET @start_time = GETDATE()
        PRINT '>> Loading bronze.sap_kna1 (Full Load)...'

        TRUNCATE TABLE bronze.sap_kna1

        INSERT INTO bronze.sap_kna1
        SELECT * FROM P01.p01.KNA1 WITH (NOLOCK)

        SET @end_time = GETDATE()
        PRINT 'Duration: ' + CAST(DATEDIFF(second,@start_time,@end_time) AS NVARCHAR) + ' seconds'


        /* ==========================================================
           2. CUSTOMER PARTNER FUNCTIONS (KNVP) - Full Truncate & Load
        ========================================================== */
        SET @current_table = 'bronze.sap_knvp'
        SET @start_time = GETDATE()
        PRINT '>> Loading bronze.sap_knvp (Full Load)...'

        TRUNCATE TABLE bronze.sap_knvp

        INSERT INTO bronze.sap_knvp
        SELECT * FROM P01.p01.KNVP WITH (NOLOCK)

        SET @end_time = GETDATE()
        PRINT 'Duration: ' + CAST(DATEDIFF(second,@start_time,@end_time) AS NVARCHAR) + ' seconds'


        /* ==========================================================
           3. CREDIT CONTROL (KNKK) - Full Truncate & Load
        ========================================================== */
        SET @current_table = 'bronze.sap_knkk'
        SET @start_time = GETDATE()
        PRINT '>> Loading bronze.sap_knkk (Full Load)...'

        TRUNCATE TABLE bronze.sap_knkk

        INSERT INTO bronze.sap_knkk
        SELECT * FROM P01.p01.KNKK WITH (NOLOCK)

        SET @end_time = GETDATE()
        PRINT 'Duration: ' + CAST(DATEDIFF(second,@start_time,@end_time) AS NVARCHAR) + ' seconds'


        /* ==========================================================
           4. CUSTOMER SALES DATA (KNVV) - Full Truncate & Load
        ========================================================== */
        SET @current_table = 'bronze.sap_knvv'
        SET @start_time = GETDATE()
        PRINT '>> Loading bronze.sap_knvv (Full Load)...'

        TRUNCATE TABLE bronze.sap_knvv

        INSERT INTO bronze.sap_knvv
        SELECT * FROM P01.p01.KNVV WITH (NOLOCK)

        SET @end_time = GETDATE()
        PRINT 'Duration: ' + CAST(DATEDIFF(second,@start_time,@end_time) AS NVARCHAR) + ' seconds'


        /* ==========================================================
           5. OPEN ITEMS (BSID) - Full Truncate & Load
           (Emptied daily because paid invoices disappear from here)
        ========================================================== */
        SET @current_table = 'bronze.sap_bsid'
        SET @start_time = GETDATE()
        PRINT '>> Loading bronze.sap_bsid (Snapshot Open Items)...'

        TRUNCATE TABLE bronze.sap_bsid

        INSERT INTO bronze.sap_bsid
        SELECT * FROM P01.p01.BSID WITH (NOLOCK)

        SET @end_time = GETDATE()
        PRINT 'Duration: ' + CAST(DATEDIFF(second,@start_time,@end_time) AS NVARCHAR) + ' seconds'


        /* ==========================================================
           6. CLEARED ITEMS (BSAD) - Incremental Merge
           (Only processes settlements from the current + previous month.
            The complete history was loaded separately via sp_backfill_bsad.sql)
        ========================================================== */
        SET @current_table = 'bronze.sap_bsad'
        SET @start_time = GETDATE()
        PRINT '>> Loading bronze.sap_bsad (Incremental Merge)...'

        SET @mes_anterior_inicio =
            CONVERT(NVARCHAR(8),
                    DATEFROMPARTS(
                        YEAR(DATEADD(MONTH, -1, GETDATE())),
                        MONTH(DATEADD(MONTH, -1, GETDATE())),
                        1
                    ),
                    112)

        MERGE bronze.sap_bsad AS tgt
        USING (
            SELECT
                MANDT, BUKRS, KUNNR, UMSKS, UMSKZ, AUGDT, AUGBL, ZUONR, GJAHR, BELNR, BUZEI, BUDAT, BLDAT,
                CPUDT, WAERS, XBLNR, BLART, MONAT, BSCHL, ZUMSK, SHKZG, GSBER, MWSKZ, DMBTR, WRBTR, MWSTS,
                WMWST, BDIFF, BDIF2, SGTXT, PROJN, AUFNR, ANLN1, ANLN2, SAKNR, HKONT, FKONT, FILKD, ZFBDT,
                ZTERM, ZBD1T, ZBD2T, ZBD3T, ZBD1P, ZBD2P, SKFBT, SKNTO, WSKTO, ZLSCH, ZLSPR, ZBFIX, HBKID,
                BVTYP, REBZG, REBZJ, REBZZ, SAMNR, ANFBN, ANFBJ, ANFBU, ANFAE, MANSP, MSCHL, MADAT, MANST,
                MABER, XNETB, XANET, XCPDD, XINVE, XZAHL, MWSK1, DMBT1, WRBT1, MWSK2, DMBT2, WRBT2, MWSK3,
                DMBT3, WRBT3, BSTAT, VBUND, VBELN, REBZT, INFAE, STCEG, EGBLD, EGLLD, RSTGR, XNOZA, VERTT,
                VERTN, VBEWA, WVERW, PROJK, FIPOS, NPLNR, AUFPL, APLZL, XEGDR, DMBE2, DMBE3, DMB21, DMB22,
                DMB23, DMB31, DMB32, DMB33, BDIF3, XRAGL, UZAWE, XSTOV, MWST2, MWST3, SKNT2, SKNT3, XREF1,
                XREF2, XARCH, PSWSL, PSWBT, LZBKZ, LANDL, IMKEY, VBEL2, VPOS2, POSN2, ETEN2, FISTL, GEBER,
                DABRZ, XNEGP, KOSTL, RFZEI, KKBER, EMPFB, PRCTR, XREF3, QSSKZ, ZINKZ, DTWS1, DTWS2, DTWS3,
                DTWS4, XPYPR, KIDNO, ABSBT, CCBTC, PYCUR, PYAMT, BUPLA, SECCO, CESSION_KZ, PPDIFF, PPDIF2,
                PPDIF3, KBLNR, KBLPOS, GRANT_NBR, GMVKZ, SRTYPE, LOTKZ, FKBER, INTRENO, PPRCT, BUZID, AUGGJ,
                HKTID, BUDGET_PD, PAYS_PROV, PAYS_TRAN, MNDID, KONTT, KONTL, UEBGDAT, VNAME, EGRUP, BTYPE,
                PROPMANO
            FROM P01.p01.BSAD WITH (NOLOCK)
            WHERE AUGDT >= @mes_anterior_inicio
        ) AS src
        ON  tgt.MANDT = src.MANDT
        AND tgt.BUKRS = src.BUKRS
        AND tgt.KUNNR = src.KUNNR
        AND tgt.GJAHR = src.GJAHR
        AND tgt.BELNR = src.BELNR
        AND tgt.BUZEI = src.BUZEI

        WHEN MATCHED THEN UPDATE SET
            tgt.AUGDT = src.AUGDT,
            tgt.AUGBL = src.AUGBL,
            tgt.DMBTR = src.DMBTR,
            tgt.WRBTR = src.WRBTR,
            tgt.ZFBDT = src.ZFBDT,
            tgt.ZTERM = src.ZTERM,
            tgt.XARCH = src.XARCH

        WHEN NOT MATCHED THEN
        INSERT (
            MANDT, BUKRS, KUNNR, UMSKS, UMSKZ, AUGDT, AUGBL, ZUONR, GJAHR, BELNR,
            BUZEI, BUDAT, BLDAT, CPUDT, WAERS, XBLNR, BLART, MONAT, BSCHL, ZUMSK,
            SHKZG, GSBER, MWSKZ, DMBTR, WRBTR, MWSTS, WMWST, BDIFF, BDIF2, SGTXT,
            PROJN, AUFNR, ANLN1, ANLN2, SAKNR, HKONT, FKONT, FILKD, ZFBDT, ZTERM,
            ZBD1T, ZBD2T, ZBD3T, ZBD1P, ZBD2P, SKFBT, SKNTO, WSKTO, ZLSCH, ZLSPR,
            ZBFIX, HBKID, BVTYP, REBZG, REBZJ, REBZZ, SAMNR, ANFBN, ANFBJ, ANFBU,
            ANFAE, MANSP, MSCHL, MADAT, MANST, MABER, XNETB, XANET, XCPDD, XINVE,
            XZAHL, MWSK1, DMBT1, WRBT1, MWSK2, DMBT2, WRBT2, MWSK3, DMBT3, WRBT3,
            BSTAT, VBUND, VBELN, REBZT, INFAE, STCEG, EGBLD, EGLLD, RSTGR, XNOZA,
            VERTT, VERTN, VBEWA, WVERW, PROJK, FIPOS, NPLNR, AUFPL, APLZL, XEGDR,
            DMBE2, DMBE3, DMB21, DMB22, DMB23, DMB31, DMB32, DMB33, BDIF3, XRAGL,
            UZAWE, XSTOV, MWST2, MWST3, SKNT2, SKNT3, XREF1, XREF2, XARCH, PSWSL,
            PSWBT, LZBKZ, LANDL, IMKEY, VBEL2, VPOS2, POSN2, ETEN2, FISTL, GEBER,
            DABRZ, XNEGP, KOSTL, RFZEI, KKBER, EMPFB, PRCTR, XREF3, QSSKZ, ZINKZ,
            DTWS1, DTWS2, DTWS3, DTWS4, XPYPR, KIDNO, ABSBT, CCBTC, PYCUR, PYAMT,
            BUPLA, SECCO, CESSION_KZ, PPDIFF, PPDIF2, PPDIF3, KBLNR, KBLPOS, GRANT_NBR,
            GMVKZ, SRTYPE, LOTKZ, FKBER, INTRENO, PPRCT, BUZID, AUGGJ, HKTID, BUDGET_PD,
            PAYS_PROV, PAYS_TRAN, MNDID, KONTT, KONTL, UEBGDAT, VNAME, EGRUP, BTYPE, PROPMANO
        )
        VALUES (
            src.MANDT, src.BUKRS, src.KUNNR, src.UMSKS, src.UMSKZ, src.AUGDT, src.AUGBL, src.ZUONR, src.GJAHR, src.BELNR,
            src.BUZEI, src.BUDAT, src.BLDAT, src.CPUDT, src.WAERS, src.XBLNR, src.BLART, src.MONAT, src.BSCHL, src.ZUMSK,
            src.SHKZG, src.GSBER, src.MWSKZ, src.DMBTR, src.WRBTR, src.MWSTS, src.WMWST, src.BDIFF, src.BDIF2, src.SGTXT,
            src.PROJN, src.AUFNR, src.ANLN1, src.ANLN2, src.SAKNR, src.HKONT, src.FKONT, src.FILKD, src.ZFBDT, src.ZTERM,
            src.ZBD1T, src.ZBD2T, src.ZBD3T, src.ZBD1P, src.ZBD2P, src.SKFBT, src.SKNTO, src.WSKTO, src.ZLSCH, src.ZLSPR,
            src.ZBFIX, src.HBKID, src.BVTYP, src.REBZG, src.REBZJ, src.REBZZ, src.SAMNR, src.ANFBN, src.ANFBJ, src.ANFBU,
            src.ANFAE, src.MANSP, src.MSCHL, src.MADAT, src.MANST, src.MABER, src.XNETB, src.XANET, src.XCPDD, src.XINVE,
            src.XZAHL, src.MWSK1, src.DMBT1, src.WRBT1, src.MWSK2, src.DMBT2, src.WRBT2, src.MWSK3, src.DMBT3, src.WRBT3,
            src.BSTAT, src.VBUND, src.VBELN, src.REBZT, src.INFAE, src.STCEG, src.EGBLD, src.EGLLD, src.RSTGR, src.XNOZA,
            src.VERTT, src.VERTN, src.VBEWA, src.WVERW, src.PROJK, src.FIPOS, src.NPLNR, src.AUFPL, src.APLZL, src.XEGDR,
            src.DMBE2, src.DMBE3, src.DMB21, src.DMB22, src.DMB23, src.DMB31, src.DMB32, src.DMB33, src.BDIF3, src.XRAGL,
            src.UZAWE, src.XSTOV, src.MWST2, src.MWST3, src.SKNT2, src.SKNT3, src.XREF1, src.XREF2, src.XARCH, src.PSWSL,
            src.PSWBT, src.LZBKZ, src.LANDL, src.IMKEY, src.VBEL2, src.VPOS2, src.POSN2, src.ETEN2, src.FISTL, src.GEBER,
            src.DABRZ, src.XNEGP, src.KOSTL, src.RFZEI, src.KKBER, src.EMPFB, src.PRCTR, src.XREF3, src.QSSKZ, src.ZINKZ,
            src.DTWS1, src.DTWS2, src.DTWS3, src.DTWS4, src.XPYPR, src.KIDNO, src.ABSBT, src.CCBTC, src.PYCUR, src.PYAMT,
            src.BUPLA, src.SECCO, src.CESSION_KZ, src.PPDIFF, src.PPDIF2, src.PPDIF3, src.KBLNR, src.KBLPOS, src.GRANT_NBR,
            src.GMVKZ, src.SRTYPE, src.LOTKZ, src.FKBER, src.INTRENO, src.PPRCT, src.BUZID, src.AUGGJ, src.HKTID, src.BUDGET_PD,
            src.PAYS_PROV, src.PAYS_TRAN, src.MNDID, src.KONTT, src.KONTL, src.UEBGDAT, src.VNAME, src.EGRUP, src.BTYPE, src.PROPMANO
        );

        SET @end_time = GETDATE()
        PRINT 'Duration: ' + CAST(DATEDIFF(second,@start_time,@end_time) AS NVARCHAR) + ' seconds'



        /* ==========================================================
           7. ACCOUNTING DOCUMENT HEADER (BKPF) - Incremental Merge
           Only BLART = 'DZ'. See the scope note in ddl_bronze.sql.
           Windowed by BUDAT, not by a change date: SAP leaves AEDAT at
           '00000000' on virtually every row here (measured on August 2026:
           23,518 of 23,518), so there is no reliable "changed since" field.
           A reversal rewrites STBLG on the ORIGINAL document, which is why
           the window has to reach back a month instead of only loading what
           is new - and why STBLG is in the UPDATE list below.
           LIMITATION: a document reversed more than ~1 month after it was
           posted falls outside the window and keeps a stale STBLG here.
           Measured over 2026, every reversal landed in the same month as its
           original, so the window holds today; widen it if that changes.
        ========================================================== */
        SET @current_table = 'bronze.sap_bkpf'
        SET @start_time = GETDATE()
        PRINT '>> Loading bronze.sap_bkpf (Incremental Merge)...'

        MERGE bronze.sap_bkpf AS tgt
        USING (
            SELECT
                MANDT, BUKRS, BELNR, GJAHR, BLART, BLDAT, BUDAT, MONAT, CPUDT, CPUTM, AEDAT, UPDDT,
                WWERT, USNAM, TCODE, BVORG, XBLNR, DBBLG, STBLG, STJAH, BKTXT, WAERS, KURSF, KZWRS,
                KZKRS, BSTAT, XNETB, FRATH, XRUEB, GLVOR, GRPID, DOKID, ARCID, IBLAR, AWTYP, AWKEY,
                FIKRS, HWAER, HWAE2, HWAE3, KURS2, KURS3, BASW2, BASW3, UMRD2, UMRD3, XSTOV, STODT,
                XMWST, CURT2, CURT3, KUTY2, KUTY3, XSNET, AUSBK, XUSVR, DUEFL, AWSYS, TXKRS, LOTKZ,
                XWVOF, STGRD, PPNAM, BRNCH, NUMPG, ADISC, XREF1_HD, XREF2_HD, XREVERSAL, REINDAT,
                RLDNR, LDGRP, PROPMANO, XBLNR_ALT, VATDATE, DOCCAT, XSPLIT, CASH_ALLOC, FOLLOW_ON,
                XREORG, SUBSET, KURST, KURSX, KUR2X, KUR3X, XMCA, [/SAPF15/STATUS], PSOTY, PSOAK,
                PSOKS, PSOSG, PSOFN, INTFORM, INTDATE, PSOBT, PSOZL, PSODT, PSOTM, FM_UMART, CCINS,
                CCNUM, SSBLK, BATCH, SNAME, SAMPLED, EXCLUDE_FLAG, BLIND, OFFSET_STATUS,
                OFFSET_REFER_DAT, PENRC, KNUMV
            FROM P01.p01.BKPF WITH (NOLOCK)
            WHERE BLART = 'DZ'
              AND BUDAT >= @mes_anterior_inicio
        ) AS src
        ON  tgt.MANDT = src.MANDT
        AND tgt.BUKRS = src.BUKRS
        AND tgt.BELNR = src.BELNR
        AND tgt.GJAHR = src.GJAHR

        WHEN MATCHED THEN UPDATE SET
            tgt.STBLG = src.STBLG,
            tgt.STJAH = src.STJAH,
            tgt.STGRD = src.STGRD,
            tgt.AEDAT = src.AEDAT,
            tgt.UPDDT = src.UPDDT,
            tgt.XREVERSAL = src.XREVERSAL

        WHEN NOT MATCHED THEN
        INSERT (
            MANDT, BUKRS, BELNR, GJAHR, BLART, BLDAT, BUDAT, MONAT, CPUDT, CPUTM, AEDAT, UPDDT,
            WWERT, USNAM, TCODE, BVORG, XBLNR, DBBLG, STBLG, STJAH, BKTXT, WAERS, KURSF, KZWRS,
            KZKRS, BSTAT, XNETB, FRATH, XRUEB, GLVOR, GRPID, DOKID, ARCID, IBLAR, AWTYP, AWKEY,
            FIKRS, HWAER, HWAE2, HWAE3, KURS2, KURS3, BASW2, BASW3, UMRD2, UMRD3, XSTOV, STODT,
            XMWST, CURT2, CURT3, KUTY2, KUTY3, XSNET, AUSBK, XUSVR, DUEFL, AWSYS, TXKRS, LOTKZ,
            XWVOF, STGRD, PPNAM, BRNCH, NUMPG, ADISC, XREF1_HD, XREF2_HD, XREVERSAL, REINDAT, RLDNR,
            LDGRP, PROPMANO, XBLNR_ALT, VATDATE, DOCCAT, XSPLIT, CASH_ALLOC, FOLLOW_ON, XREORG,
            SUBSET, KURST, KURSX, KUR2X, KUR3X, XMCA, [/SAPF15/STATUS], PSOTY, PSOAK, PSOKS, PSOSG,
            PSOFN, INTFORM, INTDATE, PSOBT, PSOZL, PSODT, PSOTM, FM_UMART, CCINS, CCNUM, SSBLK,
            BATCH, SNAME, SAMPLED, EXCLUDE_FLAG, BLIND, OFFSET_STATUS, OFFSET_REFER_DAT, PENRC,
            KNUMV
        )
        VALUES (
            src.MANDT, src.BUKRS, src.BELNR, src.GJAHR, src.BLART, src.BLDAT, src.BUDAT, src.MONAT,
            src.CPUDT, src.CPUTM, src.AEDAT, src.UPDDT, src.WWERT, src.USNAM, src.TCODE, src.BVORG,
            src.XBLNR, src.DBBLG, src.STBLG, src.STJAH, src.BKTXT, src.WAERS, src.KURSF, src.KZWRS,
            src.KZKRS, src.BSTAT, src.XNETB, src.FRATH, src.XRUEB, src.GLVOR, src.GRPID, src.DOKID,
            src.ARCID, src.IBLAR, src.AWTYP, src.AWKEY, src.FIKRS, src.HWAER, src.HWAE2, src.HWAE3,
            src.KURS2, src.KURS3, src.BASW2, src.BASW3, src.UMRD2, src.UMRD3, src.XSTOV, src.STODT,
            src.XMWST, src.CURT2, src.CURT3, src.KUTY2, src.KUTY3, src.XSNET, src.AUSBK, src.XUSVR,
            src.DUEFL, src.AWSYS, src.TXKRS, src.LOTKZ, src.XWVOF, src.STGRD, src.PPNAM, src.BRNCH,
            src.NUMPG, src.ADISC, src.XREF1_HD, src.XREF2_HD, src.XREVERSAL, src.REINDAT, src.RLDNR,
            src.LDGRP, src.PROPMANO, src.XBLNR_ALT, src.VATDATE, src.DOCCAT, src.XSPLIT,
            src.CASH_ALLOC, src.FOLLOW_ON, src.XREORG, src.SUBSET, src.KURST, src.KURSX, src.KUR2X,
            src.KUR3X, src.XMCA, src.[/SAPF15/STATUS], src.PSOTY, src.PSOAK, src.PSOKS, src.PSOSG,
            src.PSOFN, src.INTFORM, src.INTDATE, src.PSOBT, src.PSOZL, src.PSODT, src.PSOTM,
            src.FM_UMART, src.CCINS, src.CCNUM, src.SSBLK, src.BATCH, src.SNAME, src.SAMPLED,
            src.EXCLUDE_FLAG, src.BLIND, src.OFFSET_STATUS, src.OFFSET_REFER_DAT, src.PENRC,
            src.KNUMV
        );

        SET @end_time = GETDATE()
        PRINT 'Duration: ' + CAST(DATEDIFF(second,@start_time,@end_time) AS NVARCHAR) + ' seconds'

        /* ==========================================================
           8. CUSTOMER COMPANY CODE DATA (KNB1) - Full Truncate & Load
        ========================================================== */
        SET @current_table = 'bronze.sap_knb1'
        SET @start_time = GETDATE()
        PRINT '>> Loading bronze.sap_knb1 (Full Load)...'

        TRUNCATE TABLE bronze.sap_knb1

        INSERT INTO bronze.sap_knb1
        SELECT * FROM P01.p01.KNB1 WITH (NOLOCK)

        SET @end_time = GETDATE()
        PRINT 'Duration: ' + CAST(DATEDIFF(second,@start_time,@end_time) AS NVARCHAR) + ' seconds'


        /* ==========================================================
           8. CUSTOMER DUNNING DATA (KNB5) - Full Truncate & Load
        ========================================================== */
        SET @current_table = 'bronze.sap_knb5'
        SET @start_time = GETDATE()
        PRINT '>> Loading bronze.sap_knb5 (Full Load)...'

        TRUNCATE TABLE bronze.sap_knb5

        INSERT INTO bronze.sap_knb5
        SELECT * FROM P01.p01.KNB5 WITH (NOLOCK)

        SET @end_time = GETDATE()
        PRINT 'Duration: ' + CAST(DATEDIFF(second,@start_time,@end_time) AS NVARCHAR) + ' seconds'


        /* ==========================================================
           9. ROUTE TEXT - CUSTOMER GROUP 1 (TVV1T) - Full Truncate & Load
           (Standard SAP text table, resolves KVGR1 -> readable name BEZEI)
        ========================================================== */
        SET @current_table = 'bronze.sap_tvv1t'
        SET @start_time = GETDATE()
        PRINT '>> Loading bronze.sap_tvv1t (Full Load)...'

        TRUNCATE TABLE bronze.sap_tvv1t

        INSERT INTO bronze.sap_tvv1t
        SELECT * FROM P01.p01.TVV1T WITH (NOLOCK)

        SET @end_time = GETDATE()
        PRINT 'Duration: ' + CAST(DATEDIFF(second,@start_time,@end_time) AS NVARCHAR) + ' seconds'


        /* ==========================================================
           10. INFOTYPE 0001 - HR ORGANIZATIONAL ASSIGNMENT (PA0001) - Full Truncate & Load
           (Resolves PERNR -> the employee's real name, ENAME)
        ========================================================== */
        SET @current_table = 'bronze.sap_pa0001'
        SET @start_time = GETDATE()
        PRINT '>> Loading bronze.sap_pa0001 (Full Load)...'

        TRUNCATE TABLE bronze.sap_pa0001

        INSERT INTO bronze.sap_pa0001
        SELECT * FROM P01.p01.PA0001 WITH (NOLOCK)

        SET @end_time = GETDATE()
        PRINT 'Duration: ' + CAST(DATEDIFF(second,@start_time,@end_time) AS NVARCHAR) + ' seconds'


        /* ==========================================================
           11. G/L CLEARED LINE ITEMS - CASH ACCOUNTS (BSAS) - Incremental Merge

           The bank side of a payment. BSAD only carries the CUSTOMER line, whose
           HKONT is the reconciliation account (121001), so the bank account the
           money actually landed in was invisible until this table. This is what
           the company's own monthly cash report is built on - reproduced exactly
           for July 2026, document by document.

           SCOPE: HKONT 111xxx (cash on hand + payment-gateway transit accounts)
           and 113xxx (banks). See the long note in ddl_bronze.sql for why the
           111xxx half is not optional.

           WINDOW: AUGDT (clearing date), current + previous month - same as BSAD,
           and NOT BUDAT like BKPF. A line ENTERS BSAS the day it is cleared, and it
           keeps its original BUDAT, which can be months old: a bank line posted in
           March and cleared in September arrives with BUDAT = March. A BUDAT window
           has already moved past it and never loads it - every line that takes more
           than a month to clear would be lost after the backfill, with no error.
           The first version of this section had exactly that bug. Measured before
           it shipped: of the lines cleared in July 2026, 97 ($424,511.58) had a
           BUDAT before June - small in one month, but lost for good every month.

           The MERGE matches on 6 columns, not on the 9 of P01's own key (BSAS~0:
           MANDT, BUKRS, HKONT, AUGDT, AUGBL, ZUONR, GJAHR, BELNR, BUZEI). With the
           9, a line that is un-cleared and re-cleared carries a new AUGDT/AUGBL,
           matches nothing, and gets inserted as a SECOND row next to the stale one.
           See THE KEY in ddl_bronze.sql.
        ========================================================== */
        SET @current_table = 'bronze.sap_bsas'
        SET @start_time = GETDATE()
        PRINT '>> Loading bronze.sap_bsas (Incremental Merge)...'

        MERGE bronze.sap_bsas AS tgt
        USING (
            SELECT
                MANDT, BUKRS, HKONT, AUGDT, AUGBL, ZUONR, GJAHR, BELNR, BUZEI, BUDAT, BLDAT,
                WAERS, XBLNR, BLART, MONAT, BSCHL, SHKZG, GSBER, MWSKZ, FKONT, DMBTR, WRBTR,
                MWSTS, WMWST, SGTXT, PROJN, AUFNR, WERKS, KOSTL, ZFBDT, XOPVW, VALUT, BSTAT,
                BDIFF, BDIF2, VBUND, PSWSL, WVERW, DMBE2, DMBE3, MWST2, MWST3, BDIF3, RDIF3,
                XRAGL, PROJK, PRCTR, XSTOV, XARCH, PSWBT, XNEGP, RFZEI, CCBTC, XREF3, BUPLA,
                PPDIFF, PPDIF2, PPDIF3, BEWAR, IMKEY, DABRZ, INTRENO, GRANT_NBR, FKBER, FIPOS,
                FISTL, GEBER, PPRCT, BUZID, AUGGJ, UZAWE, SEGMENT, PSEGMENT, PGEBER,
                PGRANT_NBR, MEASURE, BUDGET_PD, PBUDGET_PD, FIPEX, PRODPER, QSSKZ, PROPMANO
            FROM P01.p01.BSAS WITH (NOLOCK)
            WHERE AUGDT >= @mes_anterior_inicio
              AND (HKONT LIKE '0000111%' OR HKONT LIKE '0000113%')
        ) AS src
        ON  tgt.MANDT = src.MANDT
        AND tgt.BUKRS = src.BUKRS
        AND tgt.HKONT = src.HKONT
        AND tgt.GJAHR = src.GJAHR
        AND tgt.BELNR = src.BELNR
        AND tgt.BUZEI = src.BUZEI

        -- Only what can change after the line is first posted: the clearing link
        -- (a line can be cleared, un-cleared and re-cleared), the assignment and
        -- text (both editable afterwards in FB02) and the reversal and archive
        -- flags. The amount and the account never move.
        WHEN MATCHED THEN UPDATE SET
            tgt.AUGDT = src.AUGDT,
            tgt.AUGBL = src.AUGBL,
            tgt.AUGGJ = src.AUGGJ,
            tgt.ZUONR = src.ZUONR,
            tgt.XSTOV = src.XSTOV,
            tgt.XARCH = src.XARCH,
            tgt.SGTXT = src.SGTXT

        WHEN NOT MATCHED THEN
        INSERT (
            MANDT, BUKRS, HKONT, AUGDT, AUGBL, ZUONR, GJAHR, BELNR, BUZEI, BUDAT, BLDAT, WAERS,
            XBLNR, BLART, MONAT, BSCHL, SHKZG, GSBER, MWSKZ, FKONT, DMBTR, WRBTR, MWSTS, WMWST,
            SGTXT, PROJN, AUFNR, WERKS, KOSTL, ZFBDT, XOPVW, VALUT, BSTAT, BDIFF, BDIF2, VBUND,
            PSWSL, WVERW, DMBE2, DMBE3, MWST2, MWST3, BDIF3, RDIF3, XRAGL, PROJK, PRCTR, XSTOV,
            XARCH, PSWBT, XNEGP, RFZEI, CCBTC, XREF3, BUPLA, PPDIFF, PPDIF2, PPDIF3, BEWAR,
            IMKEY, DABRZ, INTRENO, GRANT_NBR, FKBER, FIPOS, FISTL, GEBER, PPRCT, BUZID, AUGGJ,
            UZAWE, SEGMENT, PSEGMENT, PGEBER, PGRANT_NBR, MEASURE, BUDGET_PD, PBUDGET_PD,
            FIPEX, PRODPER, QSSKZ, PROPMANO
        )
        VALUES (
            src.MANDT, src.BUKRS, src.HKONT, src.AUGDT, src.AUGBL, src.ZUONR, src.GJAHR,
            src.BELNR, src.BUZEI, src.BUDAT, src.BLDAT, src.WAERS, src.XBLNR, src.BLART,
            src.MONAT, src.BSCHL, src.SHKZG, src.GSBER, src.MWSKZ, src.FKONT, src.DMBTR,
            src.WRBTR, src.MWSTS, src.WMWST, src.SGTXT, src.PROJN, src.AUFNR, src.WERKS,
            src.KOSTL, src.ZFBDT, src.XOPVW, src.VALUT, src.BSTAT, src.BDIFF, src.BDIF2,
            src.VBUND, src.PSWSL, src.WVERW, src.DMBE2, src.DMBE3, src.MWST2, src.MWST3,
            src.BDIF3, src.RDIF3, src.XRAGL, src.PROJK, src.PRCTR, src.XSTOV, src.XARCH,
            src.PSWBT, src.XNEGP, src.RFZEI, src.CCBTC, src.XREF3, src.BUPLA, src.PPDIFF,
            src.PPDIF2, src.PPDIF3, src.BEWAR, src.IMKEY, src.DABRZ, src.INTRENO,
            src.GRANT_NBR, src.FKBER, src.FIPOS, src.FISTL, src.GEBER, src.PPRCT, src.BUZID,
            src.AUGGJ, src.UZAWE, src.SEGMENT, src.PSEGMENT, src.PGEBER, src.PGRANT_NBR,
            src.MEASURE, src.BUDGET_PD, src.PBUDGET_PD, src.FIPEX, src.PRODPER, src.QSSKZ,
            src.PROPMANO
        );

        SET @end_time = GETDATE()
        PRINT 'Duration: ' + CAST(DATEDIFF(second,@start_time,@end_time) AS NVARCHAR) + ' seconds'


        /* ==========================================================
           12. G/L OPEN LINE ITEMS - CASH ACCOUNTS (BSIS) - Truncate & Load by year

           WHY THIS ONE IS NOT A MERGE, UNLIKE BSAS:
           BSIS holds items that are still OPEN. The day a line gets cleared it
           LEAVES BSIS and shows up in BSAS. A merge on a date window would never
           notice the disappearance and bronze would keep the line forever - and
           a line of ANY age can disappear, so no window fixes it. Same reasoning
           as bronze.sap_bsid, which is also a full reload.

           WHY IN YEAR CHUNKS:
           ~2.9M rows in scope. One INSERT that size is a single transaction
           against a 2GB log ceiling this instance has hit before. Year chunks
           keep each transaction bounded; the loop is the whole fix.

           The table is empty between the TRUNCATE and the end of the loop -
           acceptable in bronze, same as every other full-load table here.
        ========================================================== */
        SET @current_table = 'bronze.sap_bsis'
        SET @start_time = GETDATE()
        PRINT '>> Loading bronze.sap_bsis (Full Load by year)...'

        TRUNCATE TABLE bronze.sap_bsis

        SET @bsis_yr = 2022

        WHILE @bsis_yr <= YEAR(GETDATE())
        BEGIN
            INSERT INTO bronze.sap_bsis
            SELECT *
            FROM P01.p01.BSIS WITH (NOLOCK)
            WHERE BUDAT BETWEEN CAST(@bsis_yr AS NVARCHAR(4)) + '0101'
                            AND CAST(@bsis_yr AS NVARCHAR(4)) + '1231'
              AND (HKONT LIKE '0000111%' OR HKONT LIKE '0000113%')

            PRINT '   [' + CAST(@bsis_yr AS NVARCHAR) + '] ' + CAST(@@ROWCOUNT AS NVARCHAR) + ' rows'
            SET @bsis_yr = @bsis_yr + 1
        END

        SET @end_time = GETDATE()
        PRINT 'Duration: ' + CAST(DATEDIFF(second,@start_time,@end_time) AS NVARCHAR) + ' seconds'


        -- END OF FULL PROCESS
        SET @batch_end_time = GETDATE()

        PRINT '=================================================='
        PRINT '          Bronze Load Completed Successfully      '
        PRINT 'Total Duration: ' + CAST(DATEDIFF(second,@batch_start_time,@batch_end_time) AS NVARCHAR) + ' seconds'
        PRINT '=================================================='

    END TRY
    BEGIN CATCH

        PRINT '=================================================='
        PRINT '             ERROR DURING BRONZE LOAD             '
        PRINT 'Table: '    + ISNULL(@current_table, 'UNKNOWN')
        PRINT 'Message: ' + ERROR_MESSAGE()
        PRINT 'Line: '    + CAST(ERROR_LINE() AS VARCHAR(10))
        PRINT '==================================================';

        THROW;

    END CATCH
END
GO

PRINT 'Procedure bronze.load_bronze created successfully.'
GO
