/* ============================================================================
   bronze.load_bronze
   Purpose : Daily load of the SAP tables from P01 into bronze.
   Run     : EXEC bronze.load_bronze;   first step of the daily chain
   Loads   : full reload   kna1, knvp, knkk, knvv, bsid, knb1, knb5, tvv1t, pa0001
             merge window  bsad (AUGDT), bkpf (BUDAT, DZ only), bsas (AUGDT),
                           bsis (two steps, see the section)
             The window starts on the first day of the previous month. History
             comes from the backfill procedures in this folder.
   ============================================================================ */
USE ANALISIS_DATOS;
GO

IF OBJECT_ID('bronze.load_bronze', 'P') IS NOT NULL
    DROP PROCEDURE bronze.load_bronze;
GO

CREATE PROCEDURE bronze.load_bronze
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @proc VARCHAR(128) = 'bronze.load_bronze',
            @step VARCHAR(128) = 'start',
            @t0   DATETIME2(0) = SYSDATETIME(),
            @t    DATETIME2(0) = SYSDATETIME(),
            @rows INT,
            @err  VARCHAR(4000),
            @line INT,
            @mes_anterior_inicio NVARCHAR(8);

    BEGIN TRY
        -- --------------------------------------------------------------------
        -- Customer master and reference tables: full reload
        -- --------------------------------------------------------------------
        SET @step = 'bronze.sap_kna1 full'; SET @t = SYSDATETIME();
        TRUNCATE TABLE bronze.sap_kna1;
        INSERT INTO bronze.sap_kna1
        SELECT * FROM P01.p01.KNA1 WITH (NOLOCK);
        SET @rows = @@ROWCOUNT;
        EXEC control.log_step @proc, @step, @t, @rows;

        SET @step = 'bronze.sap_knvp full'; SET @t = SYSDATETIME();
        TRUNCATE TABLE bronze.sap_knvp;
        INSERT INTO bronze.sap_knvp
        SELECT * FROM P01.p01.KNVP WITH (NOLOCK);
        SET @rows = @@ROWCOUNT;
        EXEC control.log_step @proc, @step, @t, @rows;

        SET @step = 'bronze.sap_knkk full'; SET @t = SYSDATETIME();
        TRUNCATE TABLE bronze.sap_knkk;
        INSERT INTO bronze.sap_knkk
        SELECT * FROM P01.p01.KNKK WITH (NOLOCK);
        SET @rows = @@ROWCOUNT;
        EXEC control.log_step @proc, @step, @t, @rows;

        SET @step = 'bronze.sap_knvv full'; SET @t = SYSDATETIME();
        TRUNCATE TABLE bronze.sap_knvv;
        INSERT INTO bronze.sap_knvv
        SELECT * FROM P01.p01.KNVV WITH (NOLOCK);
        SET @rows = @@ROWCOUNT;
        EXEC control.log_step @proc, @step, @t, @rows;

        -- Open items: a paid invoice leaves BSID, so only a full reload is correct.
        SET @step = 'bronze.sap_bsid full'; SET @t = SYSDATETIME();
        TRUNCATE TABLE bronze.sap_bsid;
        INSERT INTO bronze.sap_bsid
        SELECT * FROM P01.p01.BSID WITH (NOLOCK);
        SET @rows = @@ROWCOUNT;
        EXEC control.log_step @proc, @step, @t, @rows;

        -- --------------------------------------------------------------------
        -- Cleared customer items (BSAD): merge by clearing date
        -- --------------------------------------------------------------------
        SET @step = 'bronze.sap_bsad merge'; SET @t = SYSDATETIME();

        SET @mes_anterior_inicio =
            CONVERT(NVARCHAR(8),
                    DATEFROMPARTS(
                        YEAR(DATEADD(MONTH, -1, GETDATE())),
                        MONTH(DATEADD(MONTH, -1, GETDATE())),
                        1
                    ),
                    112);

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
        SET @rows = @@ROWCOUNT;
        EXEC control.log_step @proc, @step, @t, @rows;

        -- --------------------------------------------------------------------
        -- Document headers (BKPF, DZ only): merge by posting date
        -- A reversal rewrites STBLG on the ORIGINAL document, so matched rows
        -- update it. A reversal posted more than a month after its original
        -- falls outside the window and leaves STBLG stale here.
        -- --------------------------------------------------------------------
        SET @step = 'bronze.sap_bkpf merge'; SET @t = SYSDATETIME();

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
        SET @rows = @@ROWCOUNT;
        EXEC control.log_step @proc, @step, @t, @rows;

        SET @step = 'bronze.sap_knb1 full'; SET @t = SYSDATETIME();
        TRUNCATE TABLE bronze.sap_knb1;
        INSERT INTO bronze.sap_knb1
        SELECT * FROM P01.p01.KNB1 WITH (NOLOCK);
        SET @rows = @@ROWCOUNT;
        EXEC control.log_step @proc, @step, @t, @rows;

        SET @step = 'bronze.sap_knb5 full'; SET @t = SYSDATETIME();
        TRUNCATE TABLE bronze.sap_knb5;
        INSERT INTO bronze.sap_knb5
        SELECT * FROM P01.p01.KNB5 WITH (NOLOCK);
        SET @rows = @@ROWCOUNT;
        EXEC control.log_step @proc, @step, @t, @rows;

        SET @step = 'bronze.sap_tvv1t full'; SET @t = SYSDATETIME();
        TRUNCATE TABLE bronze.sap_tvv1t;
        INSERT INTO bronze.sap_tvv1t
        SELECT * FROM P01.p01.TVV1T WITH (NOLOCK);
        SET @rows = @@ROWCOUNT;
        EXEC control.log_step @proc, @step, @t, @rows;

        SET @step = 'bronze.sap_pa0001 full'; SET @t = SYSDATETIME();
        TRUNCATE TABLE bronze.sap_pa0001;
        INSERT INTO bronze.sap_pa0001
        SELECT * FROM P01.p01.PA0001 WITH (NOLOCK);
        SET @rows = @@ROWCOUNT;
        EXEC control.log_step @proc, @step, @t, @rows;

        -- --------------------------------------------------------------------
        -- Cleared G/L lines, cash accounts (BSAS): merge by clearing date
        -- AUGDT and not BUDAT: a line enters BSAS when it is cleared and keeps
        -- its original BUDAT, so a BUDAT window never sees slow clearings.
        -- Matched on 6 key columns, not on P01's 9 (which include AUGDT/AUGBL):
        -- a re-cleared line would otherwise be inserted a second time.
        -- --------------------------------------------------------------------
        SET @step = 'bronze.sap_bsas merge'; SET @t = SYSDATETIME();

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

        -- Only what can change after posting: clearing link, assignment, text, flags.
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
        SET @rows = @@ROWCOUNT;
        EXEC control.log_step @proc, @step, @t, @rows;

        -- --------------------------------------------------------------------
        -- Open G/L lines, cash accounts (BSIS): two steps
        -- a) Accounts without open-item management never clear, so their lines
        --    never leave BSIS: merge on a BUDAT window (99.8% of the rows).
        -- b) Open-item accounts (SKB1.XOPVW = 'X'): a line leaves BSIS the day
        --    it is cleared, so they are reloaded whole, in a transaction.
        -- The split comes from SKB1, not from bronze, so a new clearing account
        -- is not missed. What no window sees is recovered with bronze.recargar_bsis.
        -- --------------------------------------------------------------------
        SET @step = 'bronze.sap_bsis a: merge, accounts that never clear'; SET @t = SYSDATETIME();

        MERGE bronze.sap_bsis AS tgt
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
            FROM P01.p01.BSIS b WITH (NOLOCK)
            WHERE b.BUDAT >= @mes_anterior_inicio
              AND (b.HKONT LIKE '0000111%' OR b.HKONT LIKE '0000113%')
              AND NOT EXISTS (
                  SELECT 1 FROM P01.p01.SKB1 k WITH (NOLOCK)
                  WHERE k.MANDT = b.MANDT AND k.BUKRS = b.BUKRS
                    AND k.SAKNR = b.HKONT AND k.XOPVW = 'X')
        ) AS src
        ON  tgt.MANDT = src.MANDT
        AND tgt.BUKRS = src.BUKRS
        AND tgt.HKONT = src.HKONT
        AND tgt.GJAHR = src.GJAHR
        AND tgt.BELNR = src.BELNR
        AND tgt.BUZEI = src.BUZEI

        WHEN MATCHED THEN UPDATE SET
            tgt.ZUONR = src.ZUONR,
            tgt.XBLNR = src.XBLNR,
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
        SET @rows = @@ROWCOUNT;
        EXEC control.log_step @proc, @step, @t, @rows;

        SET @step = 'bronze.sap_bsis b: full, open-item accounts'; SET @t = SYSDATETIME();

        BEGIN TRANSACTION;

        DELETE b
        FROM bronze.sap_bsis b
        WHERE EXISTS (
            SELECT 1 FROM P01.p01.SKB1 k WITH (NOLOCK)
            WHERE k.MANDT = b.MANDT AND k.BUKRS = b.BUKRS
              AND k.SAKNR = b.HKONT AND k.XOPVW = 'X');

        INSERT INTO bronze.sap_bsis
        SELECT *
        FROM P01.p01.BSIS b WITH (NOLOCK)
        WHERE (b.HKONT LIKE '0000111%' OR b.HKONT LIKE '0000113%')
          AND b.BUDAT >= '20220101'
          AND EXISTS (
              SELECT 1 FROM P01.p01.SKB1 k WITH (NOLOCK)
              WHERE k.MANDT = b.MANDT AND k.BUKRS = b.BUKRS
                AND k.SAKNR = b.HKONT AND k.XOPVW = 'X');
        SET @rows = @@ROWCOUNT;

        COMMIT TRANSACTION;
        EXEC control.log_step @proc, @step, @t, @rows;

        EXEC control.log_step @proc, 'total', @t0;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        SELECT @err = ERROR_MESSAGE(), @line = ERROR_LINE();
        EXEC control.log_step @proc, @step, @t, NULL, @err, @line;
        THROW;
    END CATCH
END;
GO
