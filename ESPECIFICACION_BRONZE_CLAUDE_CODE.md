# 📋 ESPECIFICACIÓN: BRONZE LAYER - CRÉDITO Y COBRANZA

**Documento para: Claude Code**  
**Objetivo: Construir todas las tablas DDL y procedimientos de carga para Bronze Layer**  
**Módulo SAP: FI (Finanzas) + SD (Ventas)**  
**Base de datos: SQL Server 2022**  

---

## 🎯 RESUMEN EJECUTIVO

Necesitamos construir la **capa BRONZE** de un Data Warehouse enfocado en análisis de **Crédito y Cobranza**.

Bronze es la capa **RAW DATA** (datos crudos tal como están en SAP).

**Arquitectura:**
```
SAP ECC (Producción)
    ↓
BRONZE (Raw, sin transformaciones)
    ↓
SILVER (Curated, lógica de negocio)
    ↓
GOLD (Reporting ready)
    ↓
BI Tools (PowerBI/Tableau)
```

---

## 📊 TABLAS NECESARIAS PARA BRONZE

### TABLA 1: bronze.sap_kna1
**Maestro de Clientes - Información General**

```
Descripción: Datos generales del cliente
Fuente SAP: KNA1
Estrategia Carga: TRUNCATE+INSERT (2x semana)
Registros esperados: 10,000-50,000

Campos principales:
├─ mandt (NVARCHAR(3)) - Mandante SAP
├─ kunnr (NVARCHAR(10)) PRIMARY KEY - Número cliente
├─ name1-name4 (NVARCHAR(35)) - Nombre cliente (4 líneas)
├─ land1 (NVARCHAR(3)) - País
├─ regio (NVARCHAR(3)) - Región
├─ ort01 (NVARCHAR(35)) - Ciudad
├─ pstlz (NVARCHAR(10)) - Código postal
├─ strasse (NVARCHAR(35)) - Dirección
├─ telf1, telf2 (NVARCHAR(16)) - Teléfonos
├─ telfx (NVARCHAR(31)) - Fax
├─ smtp_addr (NVARCHAR(241)) - Email
├─ kdgrp (NVARCHAR(2)) - Grupo cliente
├─ brsch (NVARCHAR(4)) - Sector industrial
├─ sperr (NVARCHAR(1)) - Bloqueado para ventas (X=sí)
├─ loefd (NVARCHAR(1)) - Marcado para borrado (X=sí)
├─ erdat (DATE) - Fecha creación
├─ ernam (NVARCHAR(12)) - Usuario creación
├─ aedat (DATE) - Fecha última modificación
├─ aenam (NVARCHAR(12)) - Usuario última modificación
└─ sap_load_date (DATETIME2) - AUDITORÍA: Fecha carga

Índices obligatorios:
├─ PK: (mandt, kunnr)
├─ idx_name: (name1, mandt)
├─ idx_land: (land1, mandt)
└─ idx_load_date: (sap_load_date)

Propósito en Crédito y Cobranza:
→ Obtener datos generales del cliente para análisis de cobranza
→ Filtrar por estado de bloqueo (sperr)
```

---

### TABLA 2: bronze.sap_knvv
**⭐⭐⭐ CRÍTICA - Maestro de Clientes - Datos de Ventas/Ejecutivo/Región**

```
Descripción: Datos de ventas, ejecutivo responsable, territorio
Fuente SAP: KNVV
Estrategia Carga: TRUNCATE+INSERT (Diaria)
Registros esperados: 10,000-50,000

Campos CRÍTICOS para Crédito y Cobranza:
├─ mandt (NVARCHAR(3)) PRIMARY KEY
├─ kunnr (NVARCHAR(10)) PRIMARY KEY - Número cliente
├─ vkorg (NVARCHAR(4)) PRIMARY KEY - Organización venta
├─ vtweg (NVARCHAR(2)) PRIMARY KEY - Canal distribución
├─ spart (NVARCHAR(2)) PRIMARY KEY - Sector
├─ verk (NVARCHAR(3)) ⭐⭐⭐ - EJECUTIVO ASIGNADO (CRÍTICO)
│  └─ Ej: "001" = Juan García
│     Ej: "002" = María López
├─ vkbur (NVARCHAR(10)) ⭐⭐⭐ - TERRITORIO/REGIÓN (CRÍTICO)
│  └─ Ej: "NORTE" = Región Norte
│     Ej: "CENTRO" = Región Centro
├─ kdgrp (NVARCHAR(2)) - Grupo cliente
├─ klabc (NVARCHAR(2)) - Clase cliente
├─ zterm (NVARCHAR(4)) - TÉRMINO DE PAGO (Ej: P001=30 días)
├─ sperr (NVARCHAR(1)) - Bloqueado para ventas
├─ kunum (NVARCHAR(6)) - Número de contacto
├─ erdat (DATE) - Fecha creación
├─ aedat (DATE) - Fecha última modificación
└─ sap_load_date (DATETIME2) - AUDITORÍA

Índices obligatorios:
├─ PK: (mandt, kunnr, vkorg, vtweg, spart)
├─ FK: (mandt, kunnr) → sap_kna1
├─ idx_verk: (verk, mandt) - Para búsquedas por ejecutivo
├─ idx_vkbur: (vkbur, mandt) - Para búsquedas por territorio
└─ idx_sperr: (sperr, mandt) - Para filtrar bloqueados

Propósito en Crédito y Cobranza:
→ Identificar QUÉ EJECUTIVO maneja cada cliente
→ Agrupar deudas por TERRITORIO
→ Asignar responsabilidades de cobranza
→ Análisis de performance por ejecutivo
```

---

### TABLA 3: bronze.sap_knkk
**⭐⭐⭐ CRÍTICA - Maestro de Clientes - Datos de Crédito**

```
Descripción: Límite de crédito, estado de bloqueo de crédito
Fuente SAP: KNKK
Estrategia Carga: TRUNCATE+INSERT (Diaria)
Registros esperados: 10,000-50,000

Campos CRÍTICOS para Crédito y Cobranza:
├─ mandt (NVARCHAR(3)) PRIMARY KEY
├─ kunnr (NVARCHAR(10)) PRIMARY KEY - Número cliente
├─ bukrs (NVARCHAR(4)) PRIMARY KEY - Sociedad/Empresa
├─ klimk (DECIMAL(15,2)) ⭐⭐⭐ - LÍMITE DE CRÉDITO (CRÍTICO)
│  └─ Ejemplo: 500000.00 = $500,000 USD
├─ kraus (NVARCHAR(5)) - Moneda límite (USD, MXN, EUR, etc)
├─ klims (DECIMAL(15,2)) - Límite crédito suplementario
├─ sprfv (NVARCHAR(1)) - Bloqueo verificación crédito (X=bloqueado)
├─ kunum (NVARCHAR(6)) - Número cuenta usuario
├─ rcaud (NVARCHAR(12)) - Usuario auditor de riesgo
├─ erdat (DATE) - Fecha creación
├─ erldt (DATE) - Fecha última revisión límite
└─ sap_load_date (DATETIME2) - AUDITORÍA

Índices obligatorios:
├─ PK: (mandt, kunnr, bukrs)
├─ FK: (mandt, kunnr) → sap_kna1
├─ idx_klimk: (klimk DESC, mandt) - Para encontrar top límites
├─ idx_sprfv: (sprfv, mandt) - Para filtrar bloqueados
└─ idx_load_date: (sap_load_date)

Propósito en Crédito y Cobranza:
→ Conocer el LÍMITE DE CRÉDITO de cada cliente
→ Calcular EXPOSICIÓN = Deuda / Límite
→ Alertas: Si cliente excede límite
→ Auditoría de cambios en límites (requiere SCD2 en Silver)
```

---

### TABLA 4: bronze.sap_knvp
**Maestro de Clientes - Contactos/Partners**

```
Descripción: Contactos, deudores, acreedores relacionados
Fuente SAP: KNVP
Estrategia Carga: TRUNCATE+INSERT (Semanal)
Registros esperados: 20,000-100,000

Campos:
├─ mandt (NVARCHAR(3)) PRIMARY KEY
├─ kunnr (NVARCHAR(10)) PRIMARY KEY - Cliente principal
├─ vkorg (NVARCHAR(4)) - Org venta (puede ser NULL)
├─ parvw (NVARCHAR(2)) PRIMARY KEY - Función partner
│  └─ AG = Deudor, RE = Acreedor, ZG = Garante, etc
├─ kunn2 (NVARCHAR(10)) - Número partner
├─ lifnr (NVARCHAR(10)) - Número proveedor
├─ name1 (NVARCHAR(35)) - Nombre contacto
├─ erdat (DATE)
├─ aedat (DATE)
└─ sap_load_date (DATETIME2)

Índices:
├─ PK: (mandt, kunnr, parvw)
└─ idx_parvw: (parvw, mandt)

Propósito:
→ Información de contactos y relaciones entre clientes
```

---

### TABLA 5: bronze.sap_bsid
**⭐⭐⭐ CRÍTICA - Saldos de Clientes - DOCUMENTOS ABIERTOS**

```
Descripción: Facturas abiertas (no pagadas) de clientes
Fuente SAP: BSID
Estrategia Carga: TRUNCATE+INSERT (Diaria, post-cierre)
Registros esperados: 50,000-500,000

Campos CRÍTICOS para Crédito y Cobranza:
├─ mandt (NVARCHAR(3)) PRIMARY KEY
├─ bukrs (NVARCHAR(4)) PRIMARY KEY - Sociedad
├─ kunnr (NVARCHAR(10)) PRIMARY KEY - ⭐ Cliente
├─ belnr (NVARCHAR(10)) PRIMARY KEY - ⭐ Número documento (factura)
├─ gjahr (NVARCHAR(4)) PRIMARY KEY - ⭐ Año
├─ buzei (NVARCHAR(3)) PRIMARY KEY - Elemento de línea
│
├─ blart (NVARCHAR(2)) - Tipo documento
│  └─ 01=Factura, 15=Abono/Crédito, 02=Nota Débito, etc
│
├─ bldat (NVARCHAR(8)) - Fecha documento (YYYYMMDD) ⭐
├─ budat (NVARCHAR(8)) - Fecha contabilización (YYYYMMDD)
├─ zfbdt (NVARCHAR(8)) - ⭐⭐⭐ FECHA VENCIMIENTO (YYYYMMDD) CRÍTICA
│  └─ EJ: "20240930" = 30 de septiembre 2024
│     Si hoy es "20241015" → 15 días vencida
│
├─ dmbtr (DECIMAL(15,2)) - ⭐⭐⭐ IMPORTE MONEDA LOCAL (CRÍTICO)
│  └─ Ej: 50000.00 = $50,000
├─ wrbtr (DECIMAL(15,2)) - Importe moneda documento
├─ waers (NVARCHAR(5)) - ⭐ MONEDA
│  └─ Ej: "MXN" = Pesos Mexicanos
│     Ej: "USD" = Dólares
│
├─ xblnr (NVARCHAR(16)) - Número de referencia (número externo)
├─ zuonr (NVARCHAR(18)) - REFERENCIA ASIGNACIÓN (útil para búsqueda)
├─ sgtxt (NVARCHAR(50)) - Texto del documento
│
├─ hkont (NVARCHAR(10)) - Cuenta GL (para cuadre contable)
├─ bschl (NVARCHAR(2)) - Clave contabilización
├─ kostl (NVARCHAR(10)) - Centro de coste
│
├─ xauto (NVARCHAR(1)) - Marcado automáticamente
├─ rfbsk (NVARCHAR(4)) - Código rechazo de pago
├─ jtag2 (DATE) - Fecha próxima acción cobranza
├─ mahnv (NVARCHAR(1)) - Número aviso moratorio (0=sin aviso, 1,2,3=avisos)
│
└─ sap_load_date (DATETIME2) - AUDITORÍA

Índices OBLIGATORIOS:
├─ PK: (mandt, bukrs, kunnr, belnr, gjahr, buzei)
├─ idx_kunnr: (kunnr, mandt) - BÚSQUEDA POR CLIENTE
├─ idx_zfbdt: (zfbdt, mandt) - BÚSQUEDA POR VENCIMIENTO (CRÍTICO)
├─ idx_dmbtr: (dmbtr DESC, mandt) - Facturas mayores primero
└─ idx_load_date: (sap_load_date)

Propósito en Crédito y Cobranza:
→ BASE PARA ANÁLISIS DE MOROSIDAD
→ Calcular: Días Vencido = TODAY - ZFBDT
→ Categorizar en buckets: 0-30, 31-60, 61-90, >90
→ Suma de montos por cliente, región, ejecutivo
→ TOP facturas vencidas (para cobrar primero)
→ Validar: ¿Factura pagada? (Si aparece en BSAD, está pagada)
```

---

### TABLA 6: bronze.sap_bsad
**Saldos de Clientes - DOCUMENTOS CERRADOS/PAGADOS**

```
Descripción: Facturas pagadas (compensadas) de clientes
Fuente SAP: BSAD
Estrategia Carga: TRUNCATE+INSERT (Diaria, post-cierre)
Registros esperados: 50,000-500,000

Campos: (IGUAL a BSID, más campo augdt)
├─ [TODOS los campos de BSID]
├─ augdt (NVARCHAR(8)) - Fecha compensación (YYYYMMDD)
│  └─ Cuándo fue pagada
└─ sap_load_date (DATETIME2)

Índices:
├─ PK: (mandt, bukrs, kunnr, belnr, gjahr, buzei)
├─ idx_kunnr: (kunnr, mandt)
├─ idx_augdt: (augdt, mandt) - Para búsquedas por fecha pago
└─ idx_load_date: (sap_load_date)

Propósito en Crédito y Cobranza:
→ Saber qué facturas YA FUERON PAGADAS
→ Calcular: DSO (Days Sales Outstanding) = Fecha pago - Fecha factura
→ Análisis de comportamiento de pago
→ Comparar: BSID (abiertos) vs BSAD (cerrados) = Pago diario
```

---

### TABLA 7: bronze.sap_ausp
**Asignación de Pagos - Vincula factura con pago**

```
Descripción: Registro de CUÁNDO y CÓMO se pagó cada factura
Fuente SAP: AUSP
Estrategia Carga: INCREMENTAL (diaria, append-only)
Registros esperados: 50,000-500,000

Campos CRÍTICOS:
├─ mandt (NVARCHAR(3)) PRIMARY KEY
├─ vbeln (NVARCHAR(10)) PRIMARY KEY - ⭐ Número factura
├─ bubtp (NVARCHAR(1)) PRIMARY KEY - Tipo item asignación
├─ posnn (NVARCHAR(3)) PRIMARY KEY - Número posición
│
├─ augbl (NVARCHAR(10)) - ⭐⭐ Número documento pago (pago)
│  └─ Vincula a número de recibido de pago
│
├─ augdt (NVARCHAR(8)) - ⭐⭐ Fecha pago (YYYYMMDD)
│  └─ YYYYMMDD: Cuándo se pagó
│
├─ augcp (DECIMAL(15,2)) - ⭐ Importe pagado
│  └─ Cuánto se pagó (puede ser parcial)
│
├─ waers (NVARCHAR(5)) - Moneda
├─ zuord (NVARCHAR(18)) - Asignación
├─ tstmp (DATETIME2) - Timestamp SAP (para INCREMENTAL)
└─ sap_load_date (DATETIME2)

Índices:
├─ PK: (mandt, vbeln, bubtp, posnn, augbl)
├─ idx_vbeln: (vbeln, mandt) - Búsqueda por factura
├─ idx_augbl: (augbl, mandt) - Búsqueda por pago
├─ idx_augdt: (augdt, mandt) - Búsqueda por fecha pago
└─ idx_tstmp: (tstmp DESC) - INCREMENTAL ← USO TIMESTAMP

Propósito en Crédito y Cobranza:
→ Saber EXACTAMENTE qué factura fue pagada con qué documento
→ Calcular DSO real: fecha_pago - fecha_factura
→ Detectar pagos parciales (varias asignaciones para 1 factura)
→ Trazabilidad completa del pago
→ ESTE ES INCREMENTAL porque transacciones nunca cambian
```

---

### TABLA 8: bronze.sap_bkpf
**Cabecera de Documentos Contables**

```
Descripción: Encabezados de asientos contables (para cuadre contable)
Fuente SAP: BKPF
Estrategia Carga: INCREMENTAL (diaria)
Registros esperados: 10,000-100,000

Campos:
├─ mandt (NVARCHAR(3)) PRIMARY KEY
├─ bukrs (NVARCHAR(4)) PRIMARY KEY - Sociedad
├─ belnr (NVARCHAR(10)) PRIMARY KEY - Número asiento
├─ gjahr (NVARCHAR(4)) PRIMARY KEY - Año
├─ blart (NVARCHAR(2)) - Tipo documento
├─ bldat (NVARCHAR(8)) - Fecha documento
├─ budat (NVARCHAR(8)) - Fecha contabilización
├─ usnam (NVARCHAR(12)) - Usuario creador
├─ xblnr (NVARCHAR(16)) - Referencia
├─ bktxt (NVARCHAR(25)) - Texto
├─ monat (NVARCHAR(2)) - Mes
├─ rfstat (NVARCHAR(1)) - Estado rechazo
├─ waers (NVARCHAR(5)) - Moneda
├─ tstmp (DATETIME2) - Para INCREMENTAL
└─ sap_load_date (DATETIME2)

Propósito:
→ Cuadre contable con BSID/BSAD
→ Validar integridad de datos
→ INCREMENTAL porque asientos no cambian
```

---

### TABLA 9: bronze.sap_bseg
**Líneas de Documentos Contables**

```
Descripción: Líneas de asientos contables
Fuente SAP: BSEG
Estrategia Carga: INCREMENTAL (diaria)
Registros esperados: 50,000-500,000

Campos:
├─ [Similar a BKPF]
├─ buzei (NVARCHAR(3)) - Elemento de línea
├─ hkont (NVARCHAR(10)) - Cuenta GL
├─ konto (NVARCHAR(10)) - Número cliente/proveedor
├─ dmbtr (DECIMAL(15,2)) - Importe
├─ bschl (NVARCHAR(2)) - Clave contabilización
├─ tstmp (DATETIME2)
└─ sap_load_date (DATETIME2)

Propósito:
→ Detalle contable por línea
→ Vincular con clientes en asientos
```

---

### TABLA 10: bronze.sap_vbrk
**Cabecera de Facturas de Venta (SD)**

```
Descripción: Encabezado facturas emitidas
Fuente SAP: VBRK
Estrategia Carga: INCREMENTAL (diaria)
Registros esperados: 10,000-100,000

Campos:
├─ mandt (NVARCHAR(3)) PRIMARY KEY
├─ vbeln (NVARCHAR(10)) PRIMARY KEY - Número factura
├─ kunag (NVARCHAR(10)) - Deudor (cliente)
├─ kunrg (NVARCHAR(10)) - Contacto
├─ auart (NVARCHAR(4)) - Tipo documento venta
├─ fkdat (NVARCHAR(8)) - Fecha factura
├─ vkorg (NVARCHAR(4)) - Org venta
├─ waers (NVARCHAR(5)) - Moneda
├─ usnam (NVARCHAR(12)) - Usuario
├─ tstmp (DATETIME2)
└─ sap_load_date (DATETIME2)

Propósito:
→ Vincular factura SD con BSID (saldo)
→ Análisis de ventas vs cobranza
```

---

### TABLA 11: bronze.sap_vbrp
**Líneas de Facturas de Venta (SD)**

```
Descripción: Líneas de facturas emitidas
Fuente SAP: VBRP
Estrategia Carga: INCREMENTAL (diaria)
Registros esperados: 50,000-500,000

Campos:
├─ mandt (NVARCHAR(3)) PRIMARY KEY
├─ vbeln (NVARCHAR(10)) PRIMARY KEY - Factura
├─ posnr (NVARCHAR(6)) PRIMARY KEY - Ítem
├─ matnr (NVARCHAR(18)) - Material
├─ netwr (DECIMAL(15,2)) - Importe neto
├─ mwsbp (DECIMAL(15,2)) - Impuesto
├─ waers (NVARCHAR(5)) - Moneda
├─ fkimg (DECIMAL(13,3)) - Cantidad
├─ meins (NVARCHAR(3)) - Unidad medida
├─ tstmp (DATETIME2)
└─ sap_load_date (DATETIME2)

Propósito:
→ Detalle de productos en facturas
```

---

## 🔄 ESTRATEGIA DE CARGA

### TRUNCATE+INSERT (Snapshots):
```
MAESTROS (2x semana - lunes, jueves):
├─ sap_kna1 (clientes general)
├─ sap_knvv (ejecutivos/región) 
├─ sap_knkk (límites crédito)
└─ sap_knvp (contactos)

SNAPSHOTS (diaria - post-cierre 22:00):
├─ sap_bsid (abiertos - estado HOY)
└─ sap_bsad (cerrados - estado HOY)

Estrategia: TRUNCATE TABLE → INSERT FROM SAP
Resultado: Última foto del día
```

### INCREMENTAL (Append-Only):
```
TRANSACCIONALES (diaria):
├─ sap_ausp (pagos)
├─ sap_bkpf (asientos)
├─ sap_bseg (líneas)
├─ sap_vbrk (facturas)
└─ sap_vbrp (líneas facturas)

Estrategia: INSERT FROM SAP WHERE tstmp > MAX(sap_load_date)
Resultado: Histórico completo
Ventaja: Performance (solo nuevos)
```

---

## 🏗️ ESTRUCTURA SQL ESPERADA

Para cada tabla, necesitamos:

### 1. DDL (Data Definition Language)
```sql
CREATE TABLE schema.tabla (
    -- Campos...
    -- Constraints...
    -- Índices...
)
```

### 2. Procedimientos de Carga
```sql
CREATE PROCEDURE sp_load_tabla
    @StartTime DATETIME2 OUTPUT,
    @EndTime DATETIME2 OUTPUT,
    @RowsAffected INT OUTPUT
AS
BEGIN
    -- TRUNCATE o INCREMENTAL
    -- INSERT FROM SAP
    -- LOG en control.sap_load_control
END
```

### 3. Tabla de Control
```sql
control.sap_load_control
├─ table_name
├─ load_status (SUCCESS/FAILED)
├─ rows_processed
├─ duration_seconds
└─ error_message
```

---

## ✅ VALIDACIONES REQUERIDAS

Después de cargar Bronze, validar:

```sql
-- 1. Completitud
SELECT table_name, COUNT(*) as row_count
FROM [schema].[table]
GROUP BY table_name;

-- 2. Reconciliación SAP ↔ Bronze
SELECT COUNT(*) FROM SAP_ECC.dbo.KNA1
SELECT COUNT(*) FROM bronze.sap_kna1
-- Deben coincidir (o cercano)

-- 3. Campos críticos no NULL
SELECT COUNT(*) FROM bronze.sap_bsid WHERE zfbdt IS NULL;
-- Debe ser 0 (todas tienen fecha vencimiento)

-- 4. Fechas válidas
SELECT * FROM bronze.sap_bsid 
WHERE TRY_CAST(zfbdt AS DATE) IS NULL;
-- Debe ser 0 (todas son fechas válidas)

-- 5. Duplicados
SELECT kunnr, belnr, gjahr, buzei, COUNT(*)
FROM bronze.sap_bsid
GROUP BY kunnr, belnr, gjahr, buzei
HAVING COUNT(*) > 1;
-- Debe ser 0 (sin duplicados en PK)
```

---

## 🎯 PASOS PARA CLAUDE CODE

### Fase 1: DDL Maestros (Día 1)
```
1. Crear schema: bronze
2. DDL: sap_kna1 (clientes general)
3. DDL: sap_knvv (ejecutivo + región) ⭐
4. DDL: sap_knkk (límite crédito) ⭐
5. DDL: sap_knvp (contactos)

Validar: 4 tablas creadas, 0 errores
```

### Fase 2: DDL Transaccionales (Día 2)
```
1. DDL: sap_bsid (abiertos) ⭐⭐⭐
2. DDL: sap_bsad (cerrados)
3. DDL: sap_ausp (pagos) ⭐
4. DDL: sap_bkpf (asientos)
5. DDL: sap_bseg (líneas)
6. DDL: sap_vbrk (facturas)
7. DDL: sap_vbrp (líneas)

Validar: 7 tablas creadas, 0 errores
```

### Fase 3: Control & Procedures (Día 3)
```
1. Crear schema: control
2. Tabla: control.sap_load_control (auditoría)
3. Procedure: sp_load_bronze_maestros
4. Procedure: sp_load_bronze_snapshots (BSID+BSAD)
5. Procedure: sp_load_bronze_incremental (AUSP+BKPF+etc)
6. Procedure: sp_load_bronze_all (MASTER)

Validar: Todo crea sin errores
```

### Fase 4: Validación (Día 4)
```
1. Ejecutar sp_load_bronze_all
2. Validar: control.sap_load_control con SUCCESS
3. Validar: Conteos coinciden SAP ↔ Bronze
4. Validar: NO hay duplicados
5. Validar: Fechas son válidas
```

---

## 📌 NOTAS IMPORTANTES

### Base de Datos
- Database: **ANALISIS_DATOS**
- SQL Server: **2022**
- Compatibility: T-SQL estándar

### Convenciones de Naming
```
Tablas: bronze.sap_[nombre_sap]
        Ejemplo: bronze.sap_kna1, bronze.sap_bsid
        
Procedimientos: sp_load_[grupo]
                Ejemplo: sp_load_bronze_maestros
                
Vistas: vw_[descripcion]
        Ejemplo: vw_customer_aging (SERÁ EN SILVER/GOLD)
        
Campos: snake_case
        Ejemplo: customer_id, is_current, sap_load_date
        
Índices: idx_tabla_campo
         Ejemplo: idx_bsid_kunnr, idx_bsid_zfbdt
```

### Campos Obligatorios Auditoría
Toda tabla DEBE tener:
```sql
sap_load_date DATETIME2 NOT NULL DEFAULT GETDATE()
```

### Comentarios
Incluir comentarios explicativos:
```sql
-- ============================================================
-- TABLE: bronze.sap_bsid
-- PURPOSE: Saldos abiertos (facturas no pagadas)
-- LOAD_STRATEGY: TRUNCATE+INSERT Diaria (post-cierre 22:00)
-- RECORDS: 50K-500K
-- ============================================================
```

---

## 🔗 CONEXIÓN CON SILVER

Después de Bronze, Silver usará estas tablas:

```
BRONZE                  SILVER
────────────────────────────────────────
sap_kna1        →       dim_customer_scd2
sap_knvv        →       dim_sales_organization_scd2
sap_knkk        →       dim_credit_limit_scd2
sap_knvp        →       dim_partner_function
sap_bsid + 
sap_bsad        →       fact_receivables_detail
sap_ausp        →       fact_payment_assigned
sap_bkpf +
sap_bseg        →       fact_journal_entry
sap_vbrk +
sap_vbrp        →       fact_invoice_sales
```

---

## 🚀 COMANDOS INICIALES

Para empezar, Claude Code debe ejecutar:

```sql
-- 1. Crear database (si no existe)
CREATE DATABASE ANALISIS_DATOS;
GO

USE ANALISIS_DATOS;
GO

-- 2. Crear schema
IF NOT EXISTS (SELECT * FROM sys.schemas WHERE name = 'bronze')
    EXEC('CREATE SCHEMA bronze');
GO

IF NOT EXISTS (SELECT * FROM sys.schemas WHERE name = 'control')
    EXEC('CREATE SCHEMA control');
GO

-- 3. Verificar
SELECT * FROM sys.schemas WHERE name IN ('bronze', 'control');

-- 4. Luego ejecutar DDLs de las 11 tablas
-- 5. Luego crear procedimientos
```

---

## 📊 EJEMPLO: Primera Tabla (sap_kna1)

Para que entiendas qué se espera:

```sql
-- ============================================================
-- TABLE: bronze.sap_kna1
-- PURPOSE: Maestro de Clientes - Datos Generales
-- LOAD_STRATEGY: TRUNCATE+INSERT (2x/week)
-- ============================================================

IF OBJECT_ID('bronze.sap_kna1', 'U') IS NOT NULL
    DROP TABLE bronze.sap_kna1;
GO

CREATE TABLE bronze.sap_kna1 (
    -- Identificadores
    mandt NVARCHAR(3) NOT NULL,
    kunnr NVARCHAR(10) NOT NULL,
    
    -- Datos generales
    name1 NVARCHAR(35),
    name2 NVARCHAR(35),
    name3 NVARCHAR(35),
    name4 NVARCHAR(35),
    
    -- Ubicación
    land1 NVARCHAR(3),
    regio NVARCHAR(3),
    ort01 NVARCHAR(35),
    pstlz NVARCHAR(10),
    strasse NVARCHAR(35),
    
    -- Contacto
    telf1 NVARCHAR(16),
    telf2 NVARCHAR(16),
    telfx NVARCHAR(31),
    smtp_addr NVARCHAR(241),
    
    -- Clasificación
    kdgrp NVARCHAR(2),
    brsch NVARCHAR(4),
    
    -- Estados
    sperr NVARCHAR(1),
    loefd NVARCHAR(1),
    
    -- Fechas
    erdat DATE,
    ernam NVARCHAR(12),
    aedat DATE,
    aenam NVARCHAR(12),
    
    -- Auditoría
    sap_load_date DATETIME2 NOT NULL DEFAULT GETDATE(),
    
    -- Constraints
    CONSTRAINT pk_sap_kna1 PRIMARY KEY (mandt, kunnr)
);

-- Índices
CREATE INDEX idx_kna1_name ON bronze.sap_kna1(name1, mandt);
CREATE INDEX idx_kna1_land ON bronze.sap_kna1(land1, mandt);
CREATE INDEX idx_kna1_load_date ON bronze.sap_kna1(sap_load_date);

PRINT 'Table bronze.sap_kna1 created successfully.';
GO
```

---

## ✅ CHECKLIST FINAL

**Cuando termines Bronze, debes tener:**

- [ ] 11 Tablas creadas (0 errores)
  - [ ] 4 Maestros (kna1, knvv, knkk, knvp)
  - [ ] 7 Transaccionales (bsid, bsad, ausp, bkpf, bseg, vbrk, vbrp)
  
- [ ] Schema control creado
  - [ ] Tabla control.sap_load_control

- [ ] 4 Procedures creados
  - [ ] sp_load_bronze_maestros
  - [ ] sp_load_bronze_snapshots
  - [ ] sp_load_bronze_incremental
  - [ ] sp_load_bronze_all (MASTER)

- [ ] Validaciones pasadas
  - [ ] No hay duplicados en PKs
  - [ ] Fechas son válidas
  - [ ] Conteos coinciden SAP ↔ Bronze
  - [ ] Campos críticos no son NULL

- [ ] Documentación
  - [ ] Comentarios en cada tabla
  - [ ] README.md en carpeta bronze/
  - [ ] Archivos guardados en GitHub

---

## 🎯 TU SIGUIENTE PASO

**Copia este archivo completo y pásalo a Claude Code con este mensaje:**

```
"Necesito que construyas TODAS las tablas de Bronze Layer 
para mi DWH de Crédito y Cobranza.

Usa esta especificación como referencia:
[PEGA ESTE ARCHIVO COMPLETO]

Estructura:
- 11 tablas (4 maestros + 7 transaccionales)
- Schema: bronze
- Estrategia: TRUNCATE+INSERT y INCREMENTAL
- Control: tabla audit + 4 procedures

Empieza con los 4 maestros (KNA1, KNVV, KNKK, KNVP)
Luego las 7 transaccionales
Luego control y procedures

Usa los ejemplos que mostré como referencia de formato.
Incluye comentarios, índices y validaciones."
```

---

**¡Listo! Ahora tienes TODO lo que necesita Claude Code para construir Bronze.** 🚀
