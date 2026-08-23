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
- sap_bsad: Incremental MERGE by primary key (MANDT, BUKRS, KUNNR, GJAHR, BELNR,
  BUZEI), filtered to the current + previous month via AUGDT. The full multi-year
  history was loaded once via a separate one-time backfill (see sp_backfill_bsad.sql);
  this keeps only the recent window in sync going forward.
- sap_tvv1t / sap_pa0001: added to support the customer active/legal/inactive
  classification logic (see ciosa.py business rules, being ported to silver).
  sap_tvv1t resolves KVGR1 "ruta" codes to their readable BEZEI name;
  sap_pa0001 resolves PERNR to the employee's real name (ENAME) for the
  vendedor/ejecutivo de credito/gerente/cobrador partner-function roles.

NOTE ON sap_ausp / sap_bseg / sap_bkpf / sap_vbrk / sap_vbrp: intentionally not
implemented. See ddl_bronze.sql for the full notes on each.
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
           7. CUSTOMER COMPANY CODE DATA (KNB1) - Full Truncate & Load
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
