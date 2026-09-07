/*
========================================================================================
dbo.fact_pagos  -  el dinero que ENTRO, una fila por linea de pago
========================================================================================
Ventana: un mes por fecha_compensacion (hoy AGOSTO 2026, ver el WHERE).
Alcance: canal 10/40/60, sin FUERA_DE_ALCANCE.

LINEA BASE VALIDADA - julio 2026: 12,053 filas / 12,050 documentos / $149,244,694.89
  -> ese total es EXACTAMENTE el que reporta SAP para ese mes.
  Agosto es la segunda corrida; sus cifras aun no estan contrastadas contra SAP.
  Por clave: 11 = 10,878 ($136,228,205.77) | 15 = 1,168 ($13,098,038.94)
             05 = 2 (-$68,705.85)          | 08 = 5 (-$12,843.97)

QUE CUENTA COMO PAGO AQUI (decision del usuario 2026-09-07, opcion "clave 11 + pagos
directos"): dinero que entro, sin contar nada dos veces.
  - clave 11 = deposito virgen. El dinero llegando al banco.
  - clave 15 en documento que NO es hijo = pago directo. Dinero real que entro sin
    pasar por un deposito virgen.
  - clave 05/08 sueltas que sobreviven al filtro = reversos y traspasos; se quedan
    porque son ajustes negativos de pagos que SI estan en la tabla. Quitarlos dejaria
    el pago sin su contrapartida, que es peor.

LO QUE SE EXCLUYE, Y POR QUE IMPORTA: las lineas que pertenecen a un DOCUMENTO HIJO.
Un hijo es el destino de un deposito virgen: su clave 15 reaplica dinero que ya se
conto en la clave 11, y su clave 08 es el espejo de esa misma reaplicacion. Ninguna
de las dos es dinero nuevo.
  Sin el filtro entraban 123 lineas clave 15 (+$1,807,278) y 53 clave 08 (-$831,007).
  Esos $1.8M son el MISMO deposito contado dos veces - y es el mismo bug ya
  documentado en la gold.fact_pagos_compensados vieja (123 lineas tambien). Reaparecio
  por usar el mismo filtro de origen.

PK (ejercicio, documento_id, posicion): documento_id NO es unico - hay 3 documentos con
dos lineas. `posicion` es obligatoria. `ejercicio` va porque en SAP el numero de
documento es unico POR EJERCICIO, no globalmente (hoy no colisiona ninguno en 12.47M
filas, pero es la semantica correcta).
========================================================================================
*/

IF OBJECT_ID('dbo.fact_pagos', 'U') IS NOT NULL
    DROP TABLE dbo.fact_pagos;
GO

CREATE TABLE dbo.fact_pagos (
    cliente_id              VARCHAR(10)   NOT NULL,
    ejercicio               INT           NOT NULL,
    documento_id            VARCHAR(10)   NOT NULL,
    posicion                INT           NOT NULL,
    documento_compensacion  VARCHAR(10)   NULL,
    fecha_documento         DATE          NULL,
    fecha_contabilizacion   DATE          NULL,
    fecha_compensacion      DATE          NULL,
    monto                   DECIMAL(15,2) NOT NULL,
    texto                   VARCHAR(50)   NULL,
    clave_contabilizacion   VARCHAR(2)    NULL,
    fecha_carga             DATE          NOT NULL
        CONSTRAINT DF_fact_pagos_carga DEFAULT CAST(GETDATE() AS DATE),
    CONSTRAINT PK_fact_pagos PRIMARY KEY (ejercicio, documento_id, posicion)
);
GO

-- El puente une por aqui.
CREATE INDEX IX_fact_pagos_grupo ON dbo.fact_pagos (documento_compensacion);
GO


INSERT INTO dbo.fact_pagos (
    cliente_id, ejercicio, documento_id, posicion, documento_compensacion,
    fecha_documento, fecha_contabilizacion, fecha_compensacion,
    monto, texto, clave_contabilizacion
)
SELECT
    b.cliente_id,
    b.ejercicio,
    b.documento_id,
    b.posicion,
    b.documento_compensacion,
    b.fecha_documento,
    b.fecha_contabilizacion,
    b.fecha_compensacion,
    -- silver.sap_bsad NUNCA trae el monto firmado: siempre positivo. El signo hay que
    -- aplicarlo con debe_haber ('H' = credito = dinero que entra).
    CASE WHEN b.debe_haber = 'H' THEN b.monto_moneda_local
         ELSE -1 * b.monto_moneda_local
    END,
    b.sgtxt,
    b.clave_contabilizacion
FROM silver.sap_bsad b
WHERE b.mandante = '400'
  AND b.clase_documento = 'DZ'
  AND b.sgtxt = 'Asignación Aut. Deposito'
  AND b.fecha_compensacion >= '2026-08-01'
  AND b.fecha_compensacion <  '2026-09-01'
  AND b.cliente_id IN (
        SELECT c1.cliente_id
        FROM   gold.dim_cliente_comercial c1
        WHERE  c1.estatus_comercial <> 'FUERA_DE_ALCANCE'
          AND  c1.canal_distribucion IN (10, 40, 60)
      )
  -- Excluye las lineas que pertenecen a un DOCUMENTO HIJO (ver cabecera).
  -- El alias `b.` NO es cosmetico: sin calificar, `documento_id` se resuelve contra la
  -- tabla INTERNA `h`, la condicion se vuelve `h.x = h.x` (siempre verdadera) y el
  -- NOT EXISTS excluye TODO. Es un error que no avisa.
  AND NOT EXISTS (
        SELECT 1
        FROM   silver.sap_bsad h
        WHERE  h.mandante               = '400'
          AND  h.clase_documento        = 'DZ'
          AND  h.clave_contabilizacion  = '11'
          AND  h.documento_compensacion = b.documento_id
      );
GO


-- ========================================================================================
-- Verificacion
-- ========================================================================================
SELECT COUNT(*)                    AS filas,
       COUNT(DISTINCT documento_id) AS documentos,
       CAST(SUM(monto) AS DECIMAL(18,2)) AS monto
       -- julio fue: 12,053 / 12,050 / 149,244,694.89
FROM   dbo.fact_pagos;

SELECT clave_contabilizacion, COUNT(*) AS filas,
       CAST(SUM(monto) AS DECIMAL(18,2)) AS monto
FROM   dbo.fact_pagos
GROUP BY clave_contabilizacion
ORDER BY clave_contabilizacion;
GO
