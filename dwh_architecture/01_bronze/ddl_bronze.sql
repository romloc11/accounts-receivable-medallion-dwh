USE ANALISIS_DATOS;
GO

/*
===============================================================================
PROJECT: Enterprise Data Warehouse (dwh-ciosa)
LAYER: Bronze (Raw Data Staging)
AUTHOR: Roman Alejandro Lopez
DESCRIPTION: DDL creation for the general customer master table using 
             the exact nvarchar and decimal structural metadata from SAP.
===============================================================================
*/


  
-- ============================================================================
-- 1. TABLE: bronze.sap_kna1 (Customer - COMPLETE)
-- ============================================================================
IF OBJECT_ID('bronze.sap_kna1', 'U') IS NOT NULL 
    DROP TABLE bronze.sap_kna1;
GO

CREATE TABLE bronze.sap_kna1 (
    MANDT               NVARCHAR(3) NOT NULL,
    KUNNR               NVARCHAR(10) NOT NULL,
    LAND1               NVARCHAR(3),
    NAME1               NVARCHAR(35),
    NAME2               NVARCHAR(35),
    ORT01               NVARCHAR(35),
    PSTLZ               NVARCHAR(10),
    REGIO               NVARCHAR(3),
    SORTL               NVARCHAR(10),
    STRAS               NVARCHAR(35),
    TELF1               NVARCHAR(16),
    TELFX               NVARCHAR(31),
    XCPDK               NVARCHAR(1),
    ADRNR               NVARCHAR(10),
    MCOD1               NVARCHAR(25),
    MCOD2               NVARCHAR(25),
    MCOD3               NVARCHAR(25),
    ANRED               NVARCHAR(15),
    AUFSD               NVARCHAR(2),
    BAHNE               NVARCHAR(25),
    BAHNS               NVARCHAR(25),
    BBBNR               NVARCHAR(7),
    BBSNR               NVARCHAR(5),
    BEGRU               NVARCHAR(4),
    BRSCH               NVARCHAR(4),
    BUBKZ               NVARCHAR(1),
    DATLT               NVARCHAR(14),
    ERDAT               NVARCHAR(8),
    ERNAM               NVARCHAR(12),
    EXABL               NVARCHAR(1),
    FAKSD               NVARCHAR(2),
    FISKN               NVARCHAR(10),
    KNAZK               NVARCHAR(2),
    KNRZA               NVARCHAR(10),
    KONZS               NVARCHAR(10),
    KTOKD               NVARCHAR(4),
    KUKLA               NVARCHAR(2),
    LIFNR               NVARCHAR(10),
    LIFSD               NVARCHAR(2),
    LOCCO               NVARCHAR(10),
    LOEVM               NVARCHAR(1),
    NAME3               NVARCHAR(35),
    NAME4               NVARCHAR(35),
    NIELS               NVARCHAR(2),
    ORT02               NVARCHAR(35),
    PFACH               NVARCHAR(10),
    PSTL2               NVARCHAR(10),
    COUNC               NVARCHAR(3),
    CITYC               NVARCHAR(4),
    RPMKR               NVARCHAR(5),
    SPERR               NVARCHAR(1),
    SPRAS               NVARCHAR(1),
    STCD1               NVARCHAR(16),
    STCD2               NVARCHAR(11),
    STKZA               NVARCHAR(1),
    STKZU               NVARCHAR(1),
    TELBX               NVARCHAR(15),
    TELF2               NVARCHAR(16),
    TELTX               NVARCHAR(30),
    TELX1               NVARCHAR(30),
    LZONE               NVARCHAR(10),
    XZEMP               NVARCHAR(1),
    VBUND               NVARCHAR(6),
    STCEG               NVARCHAR(20),
    DEAR1               NVARCHAR(1),
    DEAR2               NVARCHAR(1),
    DEAR3               NVARCHAR(1),
    DEAR4               NVARCHAR(1),
    DEAR5               NVARCHAR(1),
    GFORM               NVARCHAR(2),
    BRAN1               NVARCHAR(10),
    BRAN2               NVARCHAR(10),
    BRAN3               NVARCHAR(10),
    BRAN4               NVARCHAR(10),
    BRAN5               NVARCHAR(10),
    EKONT               NVARCHAR(10),
    UMSAT               DECIMAL(8,2),
    UMJAH               NVARCHAR(4),
    UWAER               NVARCHAR(5),
    JMZAH               NVARCHAR(6),
    JMJAH               NVARCHAR(4),
    KATR1               NVARCHAR(2),
    KATR2               NVARCHAR(2),
    KATR3               NVARCHAR(2),
    KATR4               NVARCHAR(2),
    KATR5               NVARCHAR(2),
    KATR6               NVARCHAR(3),
    KATR7               NVARCHAR(3),
    KATR8               NVARCHAR(3),
    KATR9               NVARCHAR(3),
    KATR10              NVARCHAR(3),
    STKZN               NVARCHAR(1),
    UMSA1               DECIMAL(15,2),
    TXJCD               NVARCHAR(15),
    PERIV               NVARCHAR(2),
    ABRVW               NVARCHAR(3),
    INSPBYDEBI          NVARCHAR(1),
    INSPATDEBI          NVARCHAR(1),
    KTOCD               NVARCHAR(4),
    PFORT               NVARCHAR(35),
    WERKS               NVARCHAR(4),
    DTAMS               NVARCHAR(1),
    DTAWS               NVARCHAR(2),
    DUEFL               NVARCHAR(1),
    HZUOR               NVARCHAR(2),
    SPERZ               NVARCHAR(1),
    ETIKG               NVARCHAR(10),
    CIVVE               NVARCHAR(1),
    MILVE               NVARCHAR(1),
    KDKG1               NVARCHAR(2),
    KDKG2               NVARCHAR(2),
    KDKG3               NVARCHAR(2),
    KDKG4               NVARCHAR(2),
    KDKG5               NVARCHAR(2),
    XKNZA               NVARCHAR(1),
    FITYP               NVARCHAR(2),
    STCDT               NVARCHAR(2),
    STCD3               NVARCHAR(18),
    STCD4               NVARCHAR(18),
    STCD5               NVARCHAR(60),
    XICMS               NVARCHAR(1),
    XXIPI               NVARCHAR(1),
    XSUBT               NVARCHAR(3),
    CFOPC               NVARCHAR(2),
    TXLW1               NVARCHAR(3),
    TXLW2               NVARCHAR(3),
    CCC01               NVARCHAR(1),
    CCC02               NVARCHAR(1),
    CCC03               NVARCHAR(1),
    CCC04               NVARCHAR(1),
    CASSD               NVARCHAR(2),
    KNURL               NVARCHAR(132),
    J_1KFREPRE          NVARCHAR(10),
    J_1KFTBUS           NVARCHAR(30),
    J_1KFTIND           NVARCHAR(30),
    CONFS               NVARCHAR(1),
    UPDAT               NVARCHAR(8),
    UPTIM               NVARCHAR(6),
    NODEL               NVARCHAR(1),
    DEAR6               NVARCHAR(1),
    SUFRAMA             NVARCHAR(9),
    RG                  NVARCHAR(11),
    EXP                 NVARCHAR(3),
    UF                  NVARCHAR(2),
    RGDATE              NVARCHAR(8),
    RIC                 NVARCHAR(11),
    RNE                 NVARCHAR(10),
    RNEDATE             NVARCHAR(8),
    CNAE                NVARCHAR(7),
    LEGALNAT            NVARCHAR(4),
    CRTN                NVARCHAR(1),
    ICMSTAXPAY          NVARCHAR(2),
    INDTYP              NVARCHAR(2),
    TDT                 NVARCHAR(2),
    COMSIZE             NVARCHAR(2),
    DECREGPC            NVARCHAR(2),
    [/VSO/R_PALHGT]     DECIMAL(13,3),
    [/VSO/R_PAL_UL]     NVARCHAR(3),
    [/VSO/R_PK_MAT]     NVARCHAR(1),
    [/VSO/R_MATPAL]     NVARCHAR(18),
    [/VSO/R_I_NO_LYR]   NVARCHAR(2),
    [/VSO/R_ONE_MAT]    NVARCHAR(1),
    [/VSO/R_ONE_SORT]   NVARCHAR(1),
    [/VSO/R_ULD_SIDE]   NVARCHAR(1),
    [/VSO/R_LOAD_PREF]  NVARCHAR(1),
    [/VSO/R_DPOINT]     NVARCHAR(10),
    ALC                 NVARCHAR(8),
    PMT_OFFICE          NVARCHAR(5),
    PSOFG               NVARCHAR(10),
    PSOIS               NVARCHAR(20),
    PSON1               NVARCHAR(35),
    PSON2               NVARCHAR(35),
    PSON3               NVARCHAR(35),
    PSOVN               NVARCHAR(35),
    PSOTL               NVARCHAR(20),
    PSOHS               NVARCHAR(6),
    PSOST               NVARCHAR(28),
    PSOO1               NVARCHAR(50),
    PSOO2               NVARCHAR(50),
    PSOO3               NVARCHAR(50),
    PSOO4               NVARCHAR(50),
    PSOO5               NVARCHAR(50),
    CONSTRAINT PK_sap_kna1 PRIMARY KEY CLUSTERED (MANDT, KUNNR)
);
PRINT 'Table bronze.sap_kna1 created successfully using exact SAP lengths.';
GO
  
-- ============================================================================
-- 2. TABLE: bronze.sap_knvp (Customer Partner Functions - COMPLETE)
-- ============================================================================
IF OBJECT_ID('bronze.sap_knvp', 'U') IS NOT NULL 
    DROP TABLE bronze.sap_knvp;
GO

CREATE TABLE bronze.sap_knvp (
    MANDT      NVARCHAR(3) NOT NULL,
    KUNNR      NVARCHAR(10) NOT NULL,
    VKORG      NVARCHAR(4) NOT NULL,
    VTWEG      NVARCHAR(2) NOT NULL,
    SPART      NVARCHAR(2) NOT NULL,
    PARVW      NVARCHAR(2) NOT NULL,
    PARZA      NVARCHAR(3) NOT NULL,
    KUNN2      NVARCHAR(10), -- Mapped exactly as KUNN2 from your extraction
    LIFNR      NVARCHAR(10),
    PERNR      NVARCHAR(8),
    PARNR      NVARCHAR(10),
    KNREF      NVARCHAR(30),
    DEFPA      NVARCHAR(1),
    CONSTRAINT PK_sap_knvp PRIMARY KEY CLUSTERED (MANDT, KUNNR, VKORG, VTWEG, SPART, PARVW, PARZA)
);
PRINT 'Table bronze.sap_knvp created successfully using exact SAP lengths.';
GO

-- ============================================================================
-- 3. TABLE: bronze.sap_knkk (Customer Credit Control Data - COMPLETE)
-- ============================================================================
IF OBJECT_ID('bronze.sap_knkk', 'U') IS NOT NULL 
    DROP TABLE bronze.sap_knkk;
GO

CREATE TABLE bronze.sap_knkk (
    MANDT      NVARCHAR(3) NOT NULL,
    KUNNR      NVARCHAR(10) NOT NULL,
    KKBER      NVARCHAR(4) NOT NULL,
    KLIMK      DECIMAL(15,2), -- Credit limit
    KNKLI      NVARCHAR(10),
    SAUFT      DECIMAL(15,2),
    SKFOR      DECIMAL(15,2), -- Customer's total obligations
    SSOBL      DECIMAL(15,2), -- Special total debit balance
    UEDAT      NVARCHAR(8),
    XCHNG      NVARCHAR(1),
    ERNAM      NVARCHAR(12),
    ERDAT      NVARCHAR(8),
    CTLPC      NVARCHAR(3),
    DTREV      NVARCHAR(8),
    CRBLB      NVARCHAR(1),   -- Credit block
    SBGRP      NVARCHAR(3),   -- Credit officers group
    NXTRV      NVARCHAR(8),
    KRAUS      NVARCHAR(11),
    PAYDB      NVARCHAR(2),
    DBRAT      NVARCHAR(3),
    REVDB      NVARCHAR(8),
    AEDAT      NVARCHAR(8),
    AETXT      NVARCHAR(8),
    GRUPP      NVARCHAR(4),
    AENAM      NVARCHAR(12),
    SBDAT      NVARCHAR(8),
    KDGRP      NVARCHAR(8),
    CASHD      NVARCHAR(8),
    CASHA      DECIMAL(13,2),
    CASHC      NVARCHAR(5),
    DBPAY      NVARCHAR(3),
    DBRTG      NVARCHAR(5),
    DBEKR      DECIMAL(15,2),
    DBWAE      NVARCHAR(5),
    DBMON      NVARCHAR(8),
    ABSBT      DECIMAL(15,2),
    CONSTRAINT PK_sap_knkk PRIMARY KEY CLUSTERED (MANDT, KUNNR, KKBER)
);
PRINT 'Table bronze.sap_knkk created successfully using exact SAP lengths.';
GO



-- ============================================================================
-- 4. TABLE: bronze.sap_knvv (Customer Sales Data - EXACT SOURCE STRUCTURE)
-- ============================================================================
IF OBJECT_ID('bronze.sap_knvv', 'U') IS NOT NULL 
    DROP TABLE bronze.sap_knvv;
GO

CREATE TABLE bronze.sap_knvv (
    MANDT              NVARCHAR(3) NOT NULL,
    KUNNR              NVARCHAR(10) NOT NULL,
    VKORG              NVARCHAR(4) NOT NULL,
    VTWEG              NVARCHAR(2) NOT NULL,
    SPART              NVARCHAR(2) NOT NULL,
    ERNAM              NVARCHAR(12),
    ERDAT              NVARCHAR(8),
    BEGRU              NVARCHAR(4),
    LOEVM              NVARCHAR(1),
    VERSG              NVARCHAR(1),
    AUFSD              NVARCHAR(2),
    KALKS              NVARCHAR(1),
    KDGRP              NVARCHAR(2),
    BZIRK              NVARCHAR(6),
    KONDA              NVARCHAR(2),
    PLTYP              NVARCHAR(2),
    AWAHR              NVARCHAR(3),
    INCO1              NVARCHAR(3),
    INCO2              NVARCHAR(28),
    LIFSD              NVARCHAR(2),
    AUTLF              NVARCHAR(1),
    ANTLF              DECIMAL(1,0),
    KZTLF              NVARCHAR(1),
    KZAZU              NVARCHAR(1),
    CHSPL              NVARCHAR(1),
    LPRIO              NVARCHAR(2),
    EIKTO              NVARCHAR(12),
    VSBED              NVARCHAR(2),
    FAKSD              NVARCHAR(2),
    MRNKZ              NVARCHAR(1),
    PERFK              NVARCHAR(2),
    PERRL              NVARCHAR(2),
    KVAKZ              NVARCHAR(1),
    KVAWT              DECIMAL(13,2),
    WAERS              NVARCHAR(5),
    KLABC              NVARCHAR(2),
    KTGRD              NVARCHAR(2),
    ZTERM              NVARCHAR(4),
    VWERK              NVARCHAR(4),
    VKGRP              NVARCHAR(3),
    VKBUR              NVARCHAR(4),
    VSORT              NVARCHAR(10),
    KVGR1              NVARCHAR(3),
    KVGR2              NVARCHAR(3),
    KVGR3              NVARCHAR(3),
    KVGR4              NVARCHAR(3),
    KVGR5              NVARCHAR(3),
    BOKRE              NVARCHAR(1),
    BOIDT              NVARCHAR(8),
    KURST              NVARCHAR(4),
    PRFRE              NVARCHAR(1),
    PRAT1              NVARCHAR(1),
    PRAT2              NVARCHAR(1),
    PRAT3              NVARCHAR(1),
    PRAT4              NVARCHAR(1),
    PRAT5              NVARCHAR(1),
    PRAT6              NVARCHAR(1),
    PRAT7              NVARCHAR(1),
    PRAT8              NVARCHAR(1),
    PRAT9              NVARCHAR(1),
    PRATA              NVARCHAR(1),
    KABSS              NVARCHAR(4),
    KKBER              NVARCHAR(4),
    CASSD              NVARCHAR(2),
    RDOFF              NVARCHAR(1),
    AGREL              NVARCHAR(1),
    MEGRU              NVARCHAR(4),
    UEBTO              DECIMAL(3,1),
    UNTTO              DECIMAL(3,1),
    UEBTK              NVARCHAR(1),
    PVKSM              NVARCHAR(2),
    PODKZ              NVARCHAR(1),
    PODTG              DECIMAL(11,0),
    BLIND              NVARCHAR(1),
    CARRIER_NOTIF      NVARCHAR(1),
    [/BEV1/EMLGPFAND]  NVARCHAR(1),
    [/BEV1/EMLGFORTS]  NVARCHAR(1),
    CONSTRAINT PK_sap_knvv PRIMARY KEY CLUSTERED (MANDT, KUNNR, VKORG, VTWEG, SPART)
);
PRINT 'Table bronze.sap_knvv created successfully using exact SAP source structure.';
GO

-- ============================================================================
-- 5. TABLE: bronze.sap_bsid (Open Items - Accounts Receivable - COMPLETE)
-- ============================================================================
IF OBJECT_ID('bronze.sap_bsid', 'U') IS NOT NULL DROP TABLE bronze.sap_bsid;
GO

CREATE TABLE bronze.sap_bsid (
    MANDT           NVARCHAR(3) NOT NULL,
    BUKRS           NVARCHAR(4) NOT NULL,
    KUNNR           NVARCHAR(10) NOT NULL,
    UMSKS           NVARCHAR(1),
    UMSKZ           NVARCHAR(1),
    AUGDT           NVARCHAR(8),
    AUGBL           NVARCHAR(10),
    ZUONR           NVARCHAR(18),
    GJAHR           NVARCHAR(4) NOT NULL,
    BELNR           NVARCHAR(10) NOT NULL,
    BUZEI           NVARCHAR(3) NOT NULL,
    BUDAT           NVARCHAR(8),
    BLDAT           NVARCHAR(8),
    CPUDT           NVARCHAR(8),
    WAERS           NVARCHAR(5),
    XBLNR           NVARCHAR(16),
    BLART           NVARCHAR(2),
    MONAT           NVARCHAR(2),
    BSCHL           NVARCHAR(2),
    ZUMSK           NVARCHAR(1),
    SHKZG           NVARCHAR(1),
    GSBER           NVARCHAR(4),
    MWSKZ           NVARCHAR(2),
    DMBTR           DECIMAL(13,2), -- Amount in local currency
    WRBTR           DECIMAL(13,2), -- Amount in document currency
    MWSTS           DECIMAL(13,2),
    WMWST           DECIMAL(13,2),
    BDIFF           DECIMAL(13,2),
    BDIF2           DECIMAL(13,2),
    SGTXT           NVARCHAR(50),
    PROJN           NVARCHAR(16),
    AUFNR           NVARCHAR(12),
    ANLN1           NVARCHAR(12),
    ANLN2           NVARCHAR(4),
    SAKNR           NVARCHAR(10),
    HKONT           NVARCHAR(10),
    FKONT           NVARCHAR(3),
    FILKD           NVARCHAR(10),
    ZFBDT           NVARCHAR(8),   -- Base date for the due-date term
    ZTERM           NVARCHAR(4),   -- Payment terms
    ZBD1T           DECIMAL(3,0),
    ZBD2T           DECIMAL(3,0),
    ZBD3T           DECIMAL(3,0),
    ZBD1P           DECIMAL(5,3),
    ZBD2P           DECIMAL(5,3),
    SKFBT           DECIMAL(13,2),
    SKNTO           DECIMAL(13,2),
    WSKTO           DECIMAL(13,2),
    ZLSCH           NVARCHAR(1),
    ZLSPR           NVARCHAR(1),
    ZBFIX           NVARCHAR(1),
    HBKID           NVARCHAR(5),
    BVTYP           NVARCHAR(4),
    REBZG           NVARCHAR(10),
    REBZJ           NVARCHAR(4),
    REBZZ           NVARCHAR(3),
    SAMNR           NVARCHAR(8),
    ANFBN           NVARCHAR(10),
    ANFBJ           NVARCHAR(4),
    ANFBU           NVARCHAR(4),
    ANFAE           NVARCHAR(8),
    MANSP           NVARCHAR(1),
    MSCHL           NVARCHAR(1),
    MADAT           NVARCHAR(8),
    MANST           NVARCHAR(1),
    MABER           NVARCHAR(2),
    XNETB           NVARCHAR(1),
    XANET           NVARCHAR(1),
    XCPDD           NVARCHAR(1),
    XINVE           NVARCHAR(1),
    XZAHL           NVARCHAR(1),
    MWSK1           NVARCHAR(2),
    DMBT1           DECIMAL(13,2),
    WRBT1           DECIMAL(13,2),
    MWSK2           NVARCHAR(2),
    DMBT2           DECIMAL(13,2),
    WRBT2           DECIMAL(13,2),
    MWSK3           NVARCHAR(2),
    DMBT3           DECIMAL(13,2),
    WRBT3           DECIMAL(13,2),
    BSTAT           NVARCHAR(1),
    VBUND           NVARCHAR(6),
    VBELN           NVARCHAR(10),
    REBZT           NVARCHAR(1),
    INFAE           NVARCHAR(8),
    STCEG           NVARCHAR(20),
    EGBLD           NVARCHAR(3),
    EGLLD           NVARCHAR(3),
    RSTGR           NVARCHAR(3),
    XNOZA           NVARCHAR(1),
    VERTT           NVARCHAR(1),
    VERTN           NVARCHAR(13),
    VBEWA           NVARCHAR(4),
    WVERW           NVARCHAR(1),
    PROJK           NVARCHAR(8),
    FIPOS           NVARCHAR(14),
    NPLNR           NVARCHAR(12),
    AUFPL           NVARCHAR(10),
    APLZL           NVARCHAR(8),
    XEGDR           NVARCHAR(1),
    DMBE2           DECIMAL(13,2),
    DMBE3           DECIMAL(13,2),
    DMB21           DECIMAL(13,2),
    DMB22           DECIMAL(13,2),
    DMB23           DECIMAL(13,2),
    DMB31           DECIMAL(13,2),
    DMB32           DECIMAL(13,2),
    DMB33           DECIMAL(13,2),
    BDIF3           DECIMAL(13,2),
    XRAGL           NVARCHAR(1),
    UZAWE           NVARCHAR(2),
    XSTOV           NVARCHAR(1),
    MWST2           DECIMAL(13,2),
    MWST3           DECIMAL(13,2),
    SKNT2           DECIMAL(13,2),
    SKNT3           DECIMAL(13,2),
    XREF1           NVARCHAR(12),
    XREF2           NVARCHAR(12),
    XARCH           NVARCHAR(1),
    PSWSL           NVARCHAR(5),
    PSWBT           DECIMAL(13,2),
    LZBKZ           NVARCHAR(3),
    LANDL           NVARCHAR(3),
    IMKEY           NVARCHAR(8),
    VBEL2           NVARCHAR(10),
    VPOS2           NVARCHAR(6),
    POSN2           NVARCHAR(6),
    ETEN2           NVARCHAR(4),
    FISTL           NVARCHAR(16),
    GEBER           NVARCHAR(10),
    DABRZ           NVARCHAR(8),
    XNEGP           NVARCHAR(1),
    KOSTL           NVARCHAR(10),
    RFZEI           NVARCHAR(3),
    KKBER           NVARCHAR(4),
    EMPFB           NVARCHAR(10),
    PRCTR           NVARCHAR(10),
    XREF3           NVARCHAR(20),
    QSSKZ           NVARCHAR(2),
    ZINKZ           NVARCHAR(2),
    DTWS1           NVARCHAR(2),
    DTWS2           NVARCHAR(2),
    DTWS3           NVARCHAR(2),
    DTWS4           NVARCHAR(2),
    XPYPR           NVARCHAR(1),
    KIDNO           NVARCHAR(30),
    ABSBT           DECIMAL(13,2),
    CCBTC           NVARCHAR(10),
    PYCUR           NVARCHAR(5),
    PYAMT           DECIMAL(13,2),
    BUPLA           NVARCHAR(4),
    SECCO           NVARCHAR(4),
    CESSION_KZ      NVARCHAR(2),
    PPDIFF          DECIMAL(13,2),
    PPDIF2          DECIMAL(13,2),
    PPDIF3          DECIMAL(13,2),
    KBLNR           NVARCHAR(10),
    KBLPOS          NVARCHAR(3),
    GRANT_NBR       NVARCHAR(20),
    GMVKZ           NVARCHAR(1),
    SRTYPE          NVARCHAR(2),
    LOTKZ           NVARCHAR(10),
    FKBER           NVARCHAR(16),
    INTRENO         NVARCHAR(13),
    PPRCT           NVARCHAR(10),
    BUZID           NVARCHAR(1),
    AUGGJ           NVARCHAR(4),
    HKTID           NVARCHAR(5),
    BUDGET_PD       NVARCHAR(10),
    PAYS_PROV       NVARCHAR(4),
    PAYS_TRAN       NVARCHAR(35),
    MNDID           NVARCHAR(35),
    KONTT           NVARCHAR(2),
    KONTL           NVARCHAR(50),
    UEBGDAT         NVARCHAR(8),
    VNAME           NVARCHAR(6),
    EGRUP           NVARCHAR(3),
    BTYPE           NVARCHAR(2),
    PROPMANO        NVARCHAR(13),
    CONSTRAINT PK_sap_bsid PRIMARY KEY CLUSTERED (MANDT, BUKRS, KUNNR, GJAHR, BELNR, BUZEI)
);
PRINT 'Table bronze.sap_bsid created successfully.';
GO

-- ============================================================================
-- 6. TABLE: bronze.sap_bsad (Cleared Items - Accounts Receivable - COMPLETE)
-- ============================================================================
IF OBJECT_ID('bronze.sap_bsad', 'U') IS NOT NULL DROP TABLE bronze.sap_bsad;
GO

-- We duplicate the exact structure since SAP BSAD and BSID share the same technical layout
CREATE TABLE bronze.sap_bsad (
    MANDT           NVARCHAR(3) NOT NULL,
    BUKRS           NVARCHAR(4) NOT NULL,
    KUNNR           NVARCHAR(10) NOT NULL,
    UMSKS           NVARCHAR(1),
    UMSKZ           NVARCHAR(1),
    AUGDT           NVARCHAR(8),
    AUGBL           NVARCHAR(10),
    ZUONR           NVARCHAR(18),
    GJAHR           NVARCHAR(4) NOT NULL,
    BELNR           NVARCHAR(10) NOT NULL,
    BUZEI           NVARCHAR(3) NOT NULL,
    BUDAT           NVARCHAR(8),
    BLDAT           NVARCHAR(8),
    CPUDT           NVARCHAR(8),
    WAERS           NVARCHAR(5),
    XBLNR           NVARCHAR(16),
    BLART           NVARCHAR(2),
    MONAT           NVARCHAR(2),
    BSCHL           NVARCHAR(2),
    ZUMSK           NVARCHAR(1),
    SHKZG           NVARCHAR(1),
    GSBER           NVARCHAR(4),
    MWSKZ           NVARCHAR(2),
    DMBTR           DECIMAL(13,2),
    WRBTR           DECIMAL(13,2),
    MWSTS           DECIMAL(13,2),
    WMWST           DECIMAL(13,2),
    BDIFF           DECIMAL(13,2),
    BDIF2           DECIMAL(13,2),
    SGTXT           NVARCHAR(50),
    PROJN           NVARCHAR(16),
    AUFNR           NVARCHAR(12),
    ANLN1           NVARCHAR(12),
    ANLN2           NVARCHAR(4),
    SAKNR           NVARCHAR(10),
    HKONT           NVARCHAR(10),
    FKONT           NVARCHAR(3),
    FILKD           NVARCHAR(10),
    ZFBDT           NVARCHAR(8),
    ZTERM           NVARCHAR(4),
    ZBD1T           DECIMAL(3,0),
    ZBD2T           DECIMAL(3,0),
    ZBD3T           DECIMAL(3,0),
    ZBD1P           DECIMAL(5,3),
    ZBD2P           DECIMAL(5,3),
    SKFBT           DECIMAL(13,2),
    SKNTO           DECIMAL(13,2),
    WSKTO           DECIMAL(13,2),
    ZLSCH           NVARCHAR(1),
    ZLSPR           NVARCHAR(1),
    ZBFIX           NVARCHAR(1),
    HBKID           NVARCHAR(5),
    BVTYP           NVARCHAR(4),
    REBZG           NVARCHAR(10),
    REBZJ           NVARCHAR(4),
    REBZZ           NVARCHAR(3),
    SAMNR           NVARCHAR(8),
    ANFBN           NVARCHAR(10),
    ANFBJ           NVARCHAR(4),
    ANFBU           NVARCHAR(4),
    ANFAE           NVARCHAR(8),
    MANSP           NVARCHAR(1),
    MSCHL           NVARCHAR(1),
    MADAT           NVARCHAR(8),
    MANST           NVARCHAR(1),
    MABER           NVARCHAR(2),
    XNETB           NVARCHAR(1),
    XANET           NVARCHAR(1),
    XCPDD           NVARCHAR(1),
    XINVE           NVARCHAR(1),
    XZAHL           NVARCHAR(1),
    MWSK1           NVARCHAR(2),
    DMBT1           DECIMAL(13,2),
    WRBT1           DECIMAL(13,2),
    MWSK2           NVARCHAR(2),
    DMBT2           DECIMAL(13,2),
    WRBT2           DECIMAL(13,2),
    MWSK3           NVARCHAR(2),
    DMBT3           DECIMAL(13,2),
    WRBT3           DECIMAL(13,2),
    BSTAT           NVARCHAR(1),
    VBUND           NVARCHAR(6),
    VBELN           NVARCHAR(10),
    REBZT           NVARCHAR(1),
    INFAE           NVARCHAR(8),
    STCEG           NVARCHAR(20),
    EGBLD           NVARCHAR(3),
    EGLLD           NVARCHAR(3),
    RSTGR           NVARCHAR(3),
    XNOZA           NVARCHAR(1),
    VERTT           NVARCHAR(1),
    VERTN           NVARCHAR(13),
    VBEWA           NVARCHAR(4),
    WVERW           NVARCHAR(1),
    PROJK           NVARCHAR(8),
    FIPOS           NVARCHAR(14),
    NPLNR           NVARCHAR(12),
    AUFPL           NVARCHAR(10),
    APLZL           NVARCHAR(8),
    XEGDR           NVARCHAR(1),
    DMBE2           DECIMAL(13,2),
    DMBE3           DECIMAL(13,2),
    DMB21           DECIMAL(13,2),
    DMB22           DECIMAL(13,2),
    DMB23           DECIMAL(13,2),
    DMB31           DECIMAL(13,2),
    DMB32           DECIMAL(13,2),
    DMB33           DECIMAL(13,2),
    BDIF3           DECIMAL(13,2),
    XRAGL           NVARCHAR(1),
    UZAWE           NVARCHAR(2),
    XSTOV           NVARCHAR(1),
    MWST2           DECIMAL(13,2),
    MWST3           DECIMAL(13,2),
    SKNT2           DECIMAL(13,2),
    SKNT3           DECIMAL(13,2),
    XREF1           NVARCHAR(12),
    XREF2           NVARCHAR(12),
    XARCH           NVARCHAR(1),
    PSWSL           NVARCHAR(5),
    PSWBT           DECIMAL(13,2),
    LZBKZ           NVARCHAR(3),
    LANDL           NVARCHAR(3),
    IMKEY           NVARCHAR(8),
    VBEL2           NVARCHAR(10),
    VPOS2           NVARCHAR(6),
    POSN2           NVARCHAR(6),
    ETEN2           NVARCHAR(4),
    FISTL           NVARCHAR(16),
    GEBER           NVARCHAR(10),
    DABRZ           NVARCHAR(8),
    XNEGP           NVARCHAR(1),
    KOSTL           NVARCHAR(10),
    RFZEI           NVARCHAR(3),
    KKBER           NVARCHAR(4),
    EMPFB           NVARCHAR(10),
    PRCTR           NVARCHAR(10),
    XREF3           NVARCHAR(20),
    QSSKZ           NVARCHAR(2),
    ZINKZ           NVARCHAR(2),
    DTWS1           NVARCHAR(2),
    DTWS2           NVARCHAR(2),
    DTWS3           NVARCHAR(2),
    DTWS4           NVARCHAR(2),
    XPYPR           NVARCHAR(1),
    KIDNO           NVARCHAR(30),
    ABSBT           DECIMAL(13,2),
    CCBTC           NVARCHAR(10),
    PYCUR           NVARCHAR(5),
    PYAMT           DECIMAL(13,2),
    BUPLA           NVARCHAR(4),
    SECCO           NVARCHAR(4),
    CESSION_KZ      NVARCHAR(2),
    PPDIFF          DECIMAL(13,2),
    PPDIF2          DECIMAL(13,2),
    PPDIF3          DECIMAL(13,2),
    KBLNR           NVARCHAR(10),
    KBLPOS          NVARCHAR(3),
    GRANT_NBR       NVARCHAR(20),
    GMVKZ           NVARCHAR(1),
    SRTYPE          NVARCHAR(2),
    LOTKZ           NVARCHAR(10),
    FKBER           NVARCHAR(16),
    INTRENO         NVARCHAR(13),
    PPRCT           NVARCHAR(10),
    BUZID           NVARCHAR(1),
    AUGGJ           NVARCHAR(4),
    HKTID           NVARCHAR(5),
    BUDGET_PD       NVARCHAR(10),
    PAYS_PROV       NVARCHAR(4),
    PAYS_TRAN       NVARCHAR(35),
    MNDID           NVARCHAR(35),
    KONTT           NVARCHAR(2),
    KONTL           NVARCHAR(50),
    UEBGDAT         NVARCHAR(8),
    VNAME           NVARCHAR(6),
    EGRUP           NVARCHAR(3),
    BTYPE           NVARCHAR(2),
    PROPMANO        NVARCHAR(13),
    CONSTRAINT PK_sap_bsad PRIMARY KEY CLUSTERED (MANDT, BUKRS, KUNNR, GJAHR, BELNR, BUZEI)
);
PRINT 'Table bronze.sap_bsad created successfully.';
GO

-- ============================================================================
-- 7. TABLE: bronze.sap_knb1 (Customer Master - Company Code Data - COMPLETE)
-- ============================================================================
IF OBJECT_ID('bronze.sap_knb1', 'U') IS NOT NULL
    DROP TABLE bronze.sap_knb1;
GO

CREATE TABLE bronze.sap_knb1 (
    MANDT       NVARCHAR(3)  NOT NULL,
    KUNNR       NVARCHAR(10) NOT NULL,
    BUKRS       NVARCHAR(4)  NOT NULL,
    PERNR       NVARCHAR(8),
    ERDAT       NVARCHAR(8),
    ERNAM       NVARCHAR(12),
    SPERR       NVARCHAR(1),
    LOEVM       NVARCHAR(1),
    ZUAWA       NVARCHAR(3),
    BUSAB       NVARCHAR(2),
    AKONT       NVARCHAR(10),
    BEGRU       NVARCHAR(4),
    KNRZE       NVARCHAR(10),
    KNRZB       NVARCHAR(10),
    ZAMIM       NVARCHAR(1),
    ZAMIV       NVARCHAR(1),
    ZAMIR       NVARCHAR(1),
    ZAMIB       NVARCHAR(1),
    ZAMIO       NVARCHAR(1),
    ZWELS       NVARCHAR(10),
    XVERR       NVARCHAR(1),
    ZAHLS       NVARCHAR(1),
    ZTERM       NVARCHAR(4),
    WAKON       NVARCHAR(4),
    VZSKZ       NVARCHAR(2),
    ZINDT       NVARCHAR(8),
    ZINRT       NVARCHAR(2),
    EIKTO       NVARCHAR(12),
    ZSABE       NVARCHAR(15),
    KVERM       NVARCHAR(30),
    FDGRV       NVARCHAR(10),
    VRBKZ       NVARCHAR(2),
    VLIBB       DECIMAL(13,2),
    VRSZL       DECIMAL(3,0),
    VRSPR       DECIMAL(3,0),
    VRSNR       NVARCHAR(10),
    VERDT       NVARCHAR(8),
    PERKZ       NVARCHAR(1),
    XDEZV       NVARCHAR(1),
    XAUSZ       NVARCHAR(1),
    WEBTR       DECIMAL(13,2),
    REMIT       NVARCHAR(10),
    DATLZ       NVARCHAR(8),
    XZVER       NVARCHAR(1),
    TOGRU       NVARCHAR(4),
    KULTG       DECIMAL(3,0),
    HBKID       NVARCHAR(5),
    XPORE       NVARCHAR(1),
    BLNKZ       NVARCHAR(2),
    ALTKN       NVARCHAR(10),
    ZGRUP       NVARCHAR(2),
    URLID       NVARCHAR(4),
    MGRUP       NVARCHAR(2),
    LOCKB       NVARCHAR(7),
    UZAWE       NVARCHAR(2),
    EKVBD       NVARCHAR(10),
    SREGL       NVARCHAR(3),
    XEDIP       NVARCHAR(1),
    FRGRP       NVARCHAR(4),
    VRSDG       NVARCHAR(3),
    TLFXS       NVARCHAR(31),
    INTAD       NVARCHAR(130),
    XKNZB       NVARCHAR(1),
    GUZTE       NVARCHAR(4),
    GRICD       NVARCHAR(2),
    GRIDT       NVARCHAR(2),
    WBRSL       NVARCHAR(2),
    CONFS       NVARCHAR(1),
    UPDAT       NVARCHAR(8),
    UPTIM       NVARCHAR(6),
    NODEL       NVARCHAR(1),
    TLFNS       NVARCHAR(30),
    CESSION_KZ  NVARCHAR(2),
    AVSND       NVARCHAR(1),
    AD_HASH     NVARCHAR(10),
    QLAND       NVARCHAR(3),
    GMVKZD      NVARCHAR(1),
    CONSTRAINT PK_sap_knb1 PRIMARY KEY CLUSTERED (MANDT, BUKRS, KUNNR)
);
PRINT 'Table bronze.sap_knb1 created successfully using exact SAP lengths.';
GO

-- ============================================================================
-- 8. TABLE: bronze.sap_knb5 (Customer Master - Dunning Data - COMPLETE)
-- ============================================================================
IF OBJECT_ID('bronze.sap_knb5', 'U') IS NOT NULL
    DROP TABLE bronze.sap_knb5;
GO

CREATE TABLE bronze.sap_knb5 (
    MANDT       NVARCHAR(3)  NOT NULL,
    KUNNR       NVARCHAR(10) NOT NULL,
    BUKRS       NVARCHAR(4)  NOT NULL,
    MABER       NVARCHAR(2)  NOT NULL,
    MAHNA       NVARCHAR(4),
    MANSP       NVARCHAR(1),
    MADAT       NVARCHAR(8),
    MAHNS       NVARCHAR(1),
    KNRMA       NVARCHAR(10),
    GMVDT       NVARCHAR(8),
    BUSAB       NVARCHAR(2),
    CONSTRAINT PK_sap_knb5 PRIMARY KEY CLUSTERED (MANDT, KUNNR, BUKRS, MABER)
);
PRINT 'Table bronze.sap_knb5 created successfully using exact SAP lengths.';
GO

-- ============================================================================
-- NOTE: bronze.sap_ausp (Characteristic Values / Classification System)
-- IS NOT IMPLEMENTED AS "payment assignment".
-- In real SAP, AUSP belongs to the CA-CL (Classification) module and stores
-- characteristic values assigned to objects (OBJEK, ATINN, ATWRT, etc.),
-- with no relationship to payment or clearing documents.
-- The "which invoice was paid with which document" link that AUSP was being
-- sought for is ALREADY covered by the AUGBL (clearing document) and AUGDT
-- (clearing date) fields present in bronze.sap_bsad (cleared items).
-- If partial-payment/application traceability is needed in the future,
-- consider adding BSEG (see the exclusion note below) or REGUH/REGUP (payment proposal).
-- ============================================================================

-- ============================================================================
-- NOTE: bronze.sap_bseg IS NOT IMPLEMENTED.
-- BSEG is a cluster table in SAP ECC (RFBLG cluster); its data is stored
-- compressed in binary format and is NOT accessible via direct SQL against
-- the p01 replica (verified: only RFBLG exists as a binary blob, plus
-- screen work tables like VBSEGK/VBSEGD/VBSEGS/EBSEG, none with the real
-- historical detail). Extracting it would require an ABAP-level extractor
-- (RFC_READ_TABLE, a BW extractor like 0FI_GL_4, or SLT in ABAP mode).
-- Bronze's current scope is AR (accounts receivable), already covered at
-- the line-item level by bronze.sap_bsid (open items) and
-- bronze.sap_bsad (cleared items), both transparent tables. If GL/vendor
-- detail outside AR is needed in the future, consider getting ABAP access
-- to BSEG at that point.
-- ============================================================================

-- ============================================================================
-- NOTE: bronze.sap_bkpf / bronze.sap_vbrk / bronze.sap_vbrp ARE NOT IMPLEMENTED.
-- They were designed, verified column by column against P01, and left ready
-- to go (including a yearly historical backfill procedure), but were
-- dropped from scope because no silver/gold table consumes them: the
-- project's current scope is AR/Credit & Collections + customer master,
-- already covered by kna1/knvp/knkk/knvv/knb1/knb5/bsid/bsad. bkpf is the
-- accounting journal for the ENTIRE company (not just AR) and vbrk/vbrp is
-- sales billing detail (SD module) - both outside the declared scope.
-- If a concrete use case that needs them comes up in the future, pick it
-- back up from the conversation history/version control: the structure
-- verification against SAP is already done, it just needs to be
-- reintegrated.
-- ============================================================================

-- ============================================================================
-- 9. SCHEMA/TABLE: control.sap_load_control (Bronze Load Auditing)
-- PURPOSE: Record every load run per table (full/incremental), its result
--          (SUCCESS/FAILED), rows processed, duration, and, for incremental
--          tables, the "highwater mark" (last date value loaded) so the
--          next run only pulls what's new.
-- ============================================================================
IF OBJECT_ID('control.sap_load_control', 'U') IS NOT NULL
    DROP TABLE control.sap_load_control;
GO

CREATE TABLE control.sap_load_control (
    load_id             INT IDENTITY(1,1) NOT NULL,
    table_name          NVARCHAR(128) NOT NULL,
    load_type           NVARCHAR(20)  NOT NULL,  -- FULL / INCREMENTAL
    load_status         NVARCHAR(10)  NOT NULL,  -- SUCCESS / FAILED
    rows_processed      INT NULL,
    start_time          DATETIME2 NOT NULL,
    end_time            DATETIME2 NULL,
    duration_seconds     INT NULL,
    last_loaded_value    NVARCHAR(50) NULL,       -- highwater mark (e.g. max BUDAT/FKDAT loaded)
    error_message       NVARCHAR(4000) NULL,
    load_date           DATETIME2 NOT NULL DEFAULT SYSDATETIME(),
    CONSTRAINT PK_sap_load_control PRIMARY KEY CLUSTERED (load_id)
);
GO

CREATE INDEX idx_load_control_table ON control.sap_load_control(table_name, load_date DESC);
GO

PRINT 'Table control.sap_load_control created successfully.';
GO

-- ============================================================================
-- 10. PROCEDURE: control.sp_log_load
-- PURPOSE: Insert one audit record for each table loaded in Bronze.
--
-- WARNING (confirmed empirically): calling this procedure from INSIDE
-- another procedure (e.g. bronze.load_bronze) breaks compilation on this
-- SQL Server 2012 instance, with a misleading "Incorrect syntax near ')'"
-- error whose reported line number doesn't point to the real problem.
-- That's why bronze.load_bronze does NOT call this proc (see the header of
-- sp_load_bronze.sql). The proc itself compiles and can presumably be run
-- in isolation (its own batch, literal arguments). If audit logging needs
-- to be picked back up, try that first, in complete isolation, BEFORE
-- re-integrating it inside a load procedure.
-- ============================================================================
IF OBJECT_ID('control.sp_log_load', 'P') IS NOT NULL
    DROP PROCEDURE control.sp_log_load;
GO

CREATE PROCEDURE control.sp_log_load
    @table_name         NVARCHAR(128),
    @load_type          NVARCHAR(20),
    @load_status        NVARCHAR(10),
    @rows_processed     INT = NULL,
    @start_time         DATETIME2,
    @end_time           DATETIME2,
    @last_loaded_value  NVARCHAR(50) = NULL,
    @error_message      NVARCHAR(4000) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    INSERT INTO control.sap_load_control (
        table_name, load_type, load_status, rows_processed,
        start_time, end_time, duration_seconds, last_loaded_value, error_message
    )
    VALUES (
        @table_name, @load_type, @load_status, @rows_processed,
        @start_time, @end_time, DATEDIFF(SECOND, @start_time, @end_time),
        @last_loaded_value, @error_message
    );
END;
GO

PRINT 'Procedure control.sp_log_load created successfully.';
GO

-- ============================================================================
-- 11. FUNCTION: control.fn_get_last_loaded_value
-- PURPOSE: Returns the last "highwater mark" logged with SUCCESS for an
--          incremental table (e.g. the max date already loaded), used to
--          filter only new records on the next run.
--          Returns '19000101' if the table has never been loaded (initial full load).
-- ============================================================================
IF OBJECT_ID('control.fn_get_last_loaded_value', 'FN') IS NOT NULL
    DROP FUNCTION control.fn_get_last_loaded_value;
GO

CREATE FUNCTION control.fn_get_last_loaded_value(@table_name NVARCHAR(128))
RETURNS NVARCHAR(50)
AS
BEGIN
    DECLARE @result NVARCHAR(50);

    SELECT TOP 1 @result = last_loaded_value
    FROM control.sap_load_control
    WHERE table_name = @table_name
      AND load_status = 'SUCCESS'
      AND last_loaded_value IS NOT NULL
    ORDER BY load_date DESC;

    RETURN ISNULL(@result, '19000101');
END;
GO

PRINT 'Function control.fn_get_last_loaded_value created successfully.';
GO

-- ============================================================================
-- 12. TABLE: bronze.sap_tvv1t (Route Text / Customer Group 1 - COMPLETE)
-- PURPOSE: Standard SAP text table (translates KVGR1 into its readable
--          name, BEZEI). Added to resolve the real name of the "route"
--          used by the credit/collections department in its
--          active/legal/inactive customer classification
--          (silver.sap_knvv.ruta = KVGR1 is just the short 3-character
--          code, not the name like "CC131-E04" used in the business
--          rules).
-- Structure verified against real p01 (not guessed):
--   MANDT NVARCHAR(3), SPRAS NVARCHAR(1), KVGR1 NVARCHAR(3), BEZEI NVARCHAR(20)
-- ============================================================================
IF OBJECT_ID('bronze.sap_tvv1t', 'U') IS NOT NULL
    DROP TABLE bronze.sap_tvv1t;
GO

CREATE TABLE bronze.sap_tvv1t (
    MANDT      NVARCHAR(3) NOT NULL,
    SPRAS      NVARCHAR(1) NOT NULL,
    KVGR1      NVARCHAR(3) NOT NULL,
    BEZEI      NVARCHAR(20),
    CONSTRAINT PK_sap_tvv1t PRIMARY KEY CLUSTERED (MANDT, SPRAS, KVGR1)
);
PRINT 'Table bronze.sap_tvv1t created successfully using exact SAP lengths.';
GO

-- ============================================================================
-- 13. TABLE: bronze.sap_pa0001 (Infotype 0001 - HR Organizational Assignment - COMPLETE)
-- PURPOSE: Standard SAP HR infotype. Added solely to resolve PERNR -> the
--          employee's real name (ENAME column) used in silver.sap_knvp's
--          partner functions (VE=salesperson, E1=credit executive,
--          GR=sales manager, CC=collector), which is exactly what the
--          active/legal/inactive customer classification needs (see
--          ciosa.py). The full structure is brought in for consistency
--          with the rest of bronze (exact SAP mirror), even though silver
--          will only use MANDT/PERNR/ENAME/BEGDA/ENDDA.
--          It's a date-effective infotype (BEGDA/ENDDA): the same PERNR
--          can have several historical rows, silver must filter for the
--          currently effective record.
-- Structure verified against real p01 (not guessed), 51 columns.
-- Primary key: standard SAP infotype structure (PSKEY).
-- ============================================================================
IF OBJECT_ID('bronze.sap_pa0001', 'U') IS NOT NULL
    DROP TABLE bronze.sap_pa0001;
GO

CREATE TABLE bronze.sap_pa0001 (
    MANDT      NVARCHAR(3)  NOT NULL,
    PERNR      NVARCHAR(8)  NOT NULL,
    SUBTY      NVARCHAR(4)  NOT NULL,
    OBJPS      NVARCHAR(2)  NOT NULL,
    SPRPS      NVARCHAR(1),
    ENDDA      NVARCHAR(8)  NOT NULL,
    BEGDA      NVARCHAR(8)  NOT NULL,
    SEQNR      NVARCHAR(3)  NOT NULL,
    AEDTM      NVARCHAR(8),
    UNAME      NVARCHAR(12),
    HISTO      NVARCHAR(1),
    ITXEX      NVARCHAR(1),
    REFEX      NVARCHAR(1),
    ORDEX      NVARCHAR(1),
    ITBLD      NVARCHAR(2),
    PREAS      NVARCHAR(2),
    FLAG1      NVARCHAR(1),
    FLAG2      NVARCHAR(1),
    FLAG3      NVARCHAR(1),
    FLAG4      NVARCHAR(1),
    RESE1      NVARCHAR(2),
    RESE2      NVARCHAR(2),
    GRPVL      NVARCHAR(4),
    BUKRS      NVARCHAR(4),
    WERKS      NVARCHAR(4),
    PERSG      NVARCHAR(1),
    PERSK      NVARCHAR(2),
    VDSK1      NVARCHAR(14),
    GSBER      NVARCHAR(4),
    BTRTL      NVARCHAR(4),
    JUPER      NVARCHAR(4),
    ABKRS      NVARCHAR(2),
    ANSVH      NVARCHAR(2),
    KOSTL      NVARCHAR(10),
    ORGEH      NVARCHAR(8),
    PLANS      NVARCHAR(8),
    STELL      NVARCHAR(8),
    MSTBR      NVARCHAR(8),
    SACHA      NVARCHAR(3),
    SACHP      NVARCHAR(3),
    SACHZ      NVARCHAR(3),
    SNAME      NVARCHAR(30),
    ENAME      NVARCHAR(40),
    OTYPE      NVARCHAR(2),
    SBMOD      NVARCHAR(4),
    KOKRS      NVARCHAR(4),
    FISTL      NVARCHAR(16),
    GEBER      NVARCHAR(10),
    FKBER      NVARCHAR(16),
    GRANT_NBR  NVARCHAR(20),
    SGMNT      NVARCHAR(10),
    CONSTRAINT PK_sap_pa0001 PRIMARY KEY CLUSTERED (MANDT, PERNR, SUBTY, OBJPS, ENDDA, BEGDA, SEQNR)
);
PRINT 'Table bronze.sap_pa0001 created successfully using exact SAP lengths.';
GO
