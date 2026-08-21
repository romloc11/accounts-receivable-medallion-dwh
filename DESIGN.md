# Decisiones de diseño — Gold Layer

Este documento explica el *por qué* detrás de cada tabla, vista y decisión de modelado en la capa Gold — no solo qué existe, sino qué alternativas se descartaron y por qué. El código ya tiene comentarios inline extensos (`dwh_architecture/03_gold/*.sql`); este documento los organiza en una narrativa completa para alguien que no vivió el proceso de diseño.

## Principio general: ¿cuándo tabla, cuándo vista?

Cuatro preguntas, en orden, deciden si un objeto de la capa Gold debe ser tabla física o vista:

1. **¿Algo más va a guardar una llave permanente hacia esto?** Si un fact necesita un FK estable que sobreviva aunque el dato origen cambie mañana (una llave sustituta SCD2), tiene que ser tabla — una vista no tiene "memoria" propia, no puede preservar "esta era la versión de marzo" una vez que el dato fuente cambió.
2. **¿La fuente ya retiene la historia que necesito, o se sobrescribe y hay que acumularla?** Si la fuente es un espejo diario completo sin historial (como `silver.sap_bsid`), y necesitas tendencia en el tiempo, tiene que ser tabla — la tabla es la que acumula lo que la fuente no retiene.
3. **¿Filtrar/unir la fuente en cada consulta es caro, y algo lo va a consultar seguido?** Aunque la fuente ya tenga historia (como `silver.sap_bsad`, que si retiene todo), si el filtro/join es costoso y un dashboard lo va a golpear repetidamente, materializar en tabla con índice propio es una decisión válida de rendimiento — no arquitectónicamente obligatoria, pero sí práctica.
4. **Si ninguna de las tres aplica** — es solo re-acomodar/filtrar/unir datos que ya están materializados en otro lado, sin identidad nueva y sin necesidad de acumular — **es vista**. Recalcularla en cada consulta es barato y mantiene la lógica de negocio (que suele seguir evolucionando) separada de las tablas físicas pesadas.

Una quinta pregunta, mayormente para razones/porcentajes: **¿esto se va a consumir solo desde Power BI?** Si sí, ni siquiera debería ser objeto de SQL — debería ser una medida DAX. Promediar una razón ya calculada por fila (en vez de sumar numerador y denominador por separado y dividir al final) da un resultado matemáticamente incorrecto en cualquier corte que no sea el grano exacto de la fila — DAX resuelve esto de forma nativa respetando el contexto de filtro.

---

## Dimensiones

### `gold.dim_fecha` — sin SCD, rango creciente
Calendario auto-extensible: piso fijo en `2022-01-01` (arranque real de `bronze.sap_bsad`), techo `hoy + 1 año` (colchón para fechas de vencimiento futuras, ej. plazos NET-90), extendido automáticamente en cada corrida de `gold.load_gold`. **Antes era estático** (2020-01-01 a 2035-12-31, poblado una sola vez) — se rediseñó porque el filtro de Año en Power BI ofrecía 15 años completos aunque los datos reales solo empezaran en 2022, mala UX. No necesita SCD porque una fecha, por definición, nunca cambia sus atributos derivados (día de la semana, trimestre, etc.).

### `gold.dim_cliente` — SCD Tipo 1
Identidad del cliente (RFC, nombre, dirección). Se sobrescribe completo en cada carga, **sin historial de versiones**, porque estos atributos casi nunca cambian — no hay valor en pagar el costo de SCD2 (más filas, más complejidad de join temporal) para datos que son, en la práctica, estáticos.

### `gold.dim_cliente_comercial` / `gold.dim_cliente_credito` — SCD Tipo 2, dos tablas separadas (mini-dimensiones)

**Por qué no una sola `dim_cliente` con SCD2 para todo**: es el patrón de **mini-dimensiones** de Kimball, aplicado deliberadamente. Si canal/región/ruta y límite/bloqueo de crédito vivieran en la misma tabla SCD2 que la identidad del cliente, cada vez que cambia el atributo más volátil (`bloqueo_credito`, que cambia semanalmente según los datos reales de este proyecto) se generaría una fila nueva que también versiona el nombre, RFC y dirección — que no cambiaron. Con miles de clientes y cambios semanales, la tabla explota de filas casi-duplicadas, y además ya no se puede preguntar limpiamente "¿cómo cambió la región de este cliente?" sin que la respuesta esté contaminada por versiones que existen solo porque cambió el crédito.

La regla aplicada: **agrupar atributos por qué tan seguido cambian juntos, no por a qué entidad de negocio "pertenecen" conceptualmente**. `dim_cliente_comercial` (canal, región, ruta, vendedor) cambia ocasionalmente; `dim_cliente_credito` (límite, bloqueo, clasificación de riesgo) cambia seguido — cada una versiona a su propio ritmo. El costo real: un analista necesita más joins para armar un reporte completo — trade-off consciente, no gratis.

**Mecánica SCD2** (igual en ambas tablas): `id_surrogate` (IDENTITY, la llave técnica que usan los facts), llave de negocio (`cliente_id`), `hash_atributos` (`HASHBYTES('SHA2_256', ...)` sobre las columnas trackeadas — soportado en SQL Server 2012 SP1, confirmado), `fecha_inicio_vigencia`/`fecha_fin_vigencia`/`es_vigente`, más un índice único filtrado `WHERE es_vigente=1` que garantiza una sola versión vigente por cliente. Implementado como pasos secuenciales explícitos en tabla temporal (stage → cerrar versión cambiada → insertar nueva versión), no un solo `MERGE` — más fácil de depurar en este servidor que compactar todo en una sola sentencia.

**`dim_cliente_comercial` conserva `organizacion_ventas`/`canal_distribucion`/`sector`** aunque la llave primaria sea solo `cliente_id`, para que `dim_cliente_credito` pueda reutilizar "qué canal ya se eligió como representante del cliente" al buscar analista de crédito/cobrador — una sola fuente de verdad para esa decisión, no se vuelve a resolver en la segunda tabla.

**Facts se relacionan a estas dos por llave sustituta (`Cliente Comercial Sk`/`Cliente Credito Sk`), nunca por `cliente_id` directo** — la llave sustituta ya está resuelta por fecha en el ETL a la versión correcta. Una relación directa por `cliente_id` aplicaría el atributo *actual* del cliente a toda su historia de transacciones — el mismo error que llevó a retirar la clasificación `CLIENTE_LEGAL` (ver abajo).

---

## Hechos (Facts)

### `gold.fact_saldo_cartera` — periodic snapshot, cliente + fecha
**Por qué es tabla y no vista**: su fuente, `silver.sap_bsid`, es un espejo diario **completo** sin historial retenido (se recarga entero en cada corrida). Una vista sobre `bsid` solo mostraría "hoy" — jamás una tendencia. La tabla existe específicamente para acumular cada día una foto nueva que la fuente no retiene por sí sola. **Consecuencia real de esto**: no se puede rehacer históricamente — solo empieza a acumular desde el primer día que corrió su carga.

**Grano cliente+fecha** (no línea de factura): con ~91,593 partidas / ~4,568 clientes con saldo, el grano línea hubiera crecido ~33M filas/año en un servidor con techo de log de 2GB ya conocido; el grano cliente crece ~1.67M filas/año, manejable.

### `gold.fact_pagos_compensados` / `gold.fact_facturas_compensadas` — espejo filtrado de `bsad`
**Nombres**: renombradas desde `fact_pagos`/`fact_facturas` (2026-08-21) — los nombres originales sobre-prometían alcance. Solo contienen documentos ya **compensados** (liquidados), no todos los pagos/facturas que existen — el nombre ahora lo dice explícitamente.

**Por qué son tabla y no vista, aplicando el criterio 3 (no el 1 ni el 2)**: a diferencia de `fact_saldo_cartera`, aquí ninguna otra tabla les guarda una llave sustituta (criterio 1 no aplica), y su fuente (`silver.sap_bsad`) **sí** retiene historia completa desde 2022 — no se sobrescribe (criterio 2 tampoco aplica). La razón real de materializarlas es **rendimiento**: `bsad` completo tiene ~11.9M filas de todo tipo de documento; filtrar en vivo (`clase_documento='DZ' AND sgtxt='Asignación Aut. Deposito' AND debe_haber<>'S' AND monto>0` para pagos, `clase_documento IN (F1-F6)` para facturas) en cada consulta de un dashboard sería mucho más lento que consultar 611K/4.6M filas ya filtradas con su propio índice (`IX_..._grupo` sobre `documento_compensacion`+`ejercicio_compensacion`, agregado tras confirmar que el join de `vw_pago_factura_simple` sin él escaneaba la tabla completa cada vez). Es una decisión consciente de rendimiento, no un requisito arquitectónico duro.

**Filtros del pago virgen, iterados con evidencia real**: `debe_haber<>'S'` se agregó tras encontrar que 4 de 5 grupos de muestra "ambiguos" eran en realidad un solo pago real duplicado por su propia línea espejo/contrapartida (mismo documento, mismo monto, mismo texto) — aplicar el filtro redujo el residuo ambiguo de julio de $1.52M a $249K. `monto_moneda_local>0` se agregó después al encontrar que 6 de 14 grupos restantes eran la línea "H" propia del hijo con monto $0.00 (residuo técnico) inflando el conteo de candidatos.

**Backfill separado de la carga incremental**: `backfill_fact_pagos_facturas_compensados.sql` (histórico completo desde 2022, corrido una sola vez) vs. `gold.load_fact_pagos_compensados`/`load_fact_facturas_compensadas` (incremental, mes actual + anterior) — mismo patrón que usa `silver.load_silver` para `bsad`, para no reprocesar 11.9M filas en cada refresh diario.

---

## Vistas

### `gold.vw_cliente_canal_estatus`
Clasifica cada fila cliente+canal de `silver.sap_knvv` como ACTIVO/LEGAL/INACTIVO/REVISAR/FUERA_DE_ALCANCE, portado de un script Python ya en uso (`ciosa.py`) y validado contra datos reales. **Vista y no tabla** porque es puro filtro/CASE sobre una tabla que ya existe — nada la va a referenciar por llave, no acumula nada que la fuente no tenga. `gold.dim_cliente_comercial` se carga *sobre* esta vista, reduciendo a 1 fila por cliente con el criterio de prioridad ACTIVO > LEGAL > REVISAR > INACTIVO > FUERA_DE_ALCANCE.

### `gold.vw_pago_factura_simple` — la vista de reporte
Relaciona pago↔factura solo cuando el grupo de compensación tiene **exactamente 1 pago candidato** — si 2+ pagos comparten el mismo grupo, no se puede saber con certeza cuál cubrió cuál factura, así que se deja fuera en vez de forzar un match arbitrario (mismo principio de "no adivinar" en todo el proyecto).

**Salvaguarda de RFC único por grupo**: solo se incluyen pagos cuyo grupo de compensación completo (todas las líneas, no solo pago+factura) pertenece a un único RFC real — permite cruces legítimos de `cliente_id` dentro del mismo RFC (misma persona/empresa con varias cuentas), pero excluye lotes donde se mezclan RFCs de verdad distintos (cuentas técnicas de marketplace, etc.). Medido: solo 0.12% del monto de clientes GENERICO cae en grupos con 2+ RFC distintos — el filtro excluye justo eso, deja pasar el 99.88% restante.

**`CLIENTE_LEGAL` fue retirado (2026-08-20)** de la clasificación por una razón de confiabilidad histórica, no de gusto: `dim_cliente_comercial` es SCD2, pero la versión inicial de cada cliente fue retrasada artificialmente a `2020-01-01` (solo para permitir el join temporal con facts históricos) — no representa una transición real observada. Un cliente que se volvió LEGAL hace unos meses, sin otra transición capturada, aparecía como LEGAL desde 2020 en el join temporal — etiquetando como `CLIENTE_LEGAL` pagos de 2022-2025 en los que ese cliente en realidad pagaba con normalidad. **Lección que aplica a cualquier atributo SCD2 futuro**: una clasificación que depende de proyectar un atributo *actual* hacia atrás en el tiempo solo es tan confiable como qué tan atrás se hayan observado transiciones reales.

**GENERICO sí se incluye** (revirtiendo una exclusión de un día): se le mostró al dueño del proceso de negocio la lista completa de clientes genéricos (Mercado Libre, mostrador, empleados, pruebas) y confirmó que deben considerarse — "son parte del flujo".

---

## Objetos retirados (y por qué siguen documentados aquí)

- **`gold.fact_aplicacion_pagos`** (eliminada 2026-08-19) — el diseño de matching en 3 niveles (`REBZG`/grupo-inambiguo/sin-match) tenía bugs reales de sobre-atribución: un documento de $137 podía "explicar" $2.5M en facturas dentro de un grupo de compensación masivo, confirmado en varios casos reales. Reemplazada por el diseño deliberadamente más simple de `fact_pagos_compensados`/`fact_facturas_compensadas` + `vw_pago_factura_simple` — solo relaciona grupos con exactamente 1 candidato, sin niveles de match ni aplicación parcial. Menos cobertura, pero sin el riesgo de atribución incorrecta.
- **`gold.fact_movimientos_compensados`** (eliminada 2026-08-13) — mirror completo de TODO `bsad` a nivel línea. Decisión explícita de no llevar una tabla de silver completa a gold sin diferenciación — en su lugar, construir facts enfocados a preguntas de negocio específicas (el origen de `fact_aplicacion_pagos`, y después de `fact_pagos_compensados`/`fact_facturas_compensadas`).
- **`gold.vw_pago_virgen` / `gold.vw_factura` / `gold.vw_clasificacion_vencimiento_pago`** — prototipos de la etapa de diseño de `fact_aplicacion_pagos` y `clasificacion_cobranza`. El código ya decía "retiradas", pero el `DROP` real en el servidor nunca se ejecutó — encontradas y limpiadas en la auditoría de objetos huérfanos del 2026-08-21.
- **`gold.load_fact_pagos` / `gold.load_fact_facturas`** — procedimientos con el nombre anterior al rename, cuerpo interno todavía apuntando a tablas que ya no existen. Huérfanos por el mismo motivo: el rename creó los nuevos objetos pero nunca hizo `DROP` de los viejos.

---

## Propuestas en diseño — no implementadas todavía

Documentadas aquí porque ya se discutió el diseño completo, pero construirlas es trabajo pendiente:

- **`gold.vw_cartera_abierta`** — detalle línea-por-línea de facturas actualmente abiertas (`silver.sap_bsid`, mismo patrón de columnas/joins que `vw_pago_factura_simple`). Hoy solo existe el agregado por cliente en `fact_saldo_cartera`. Útil para: ver qué facturas específicas componen la cartera vencida de un cliente, drill-down desde Power BI, consultas operativas de cobranza diaria.
- **`gold.dim_empleado`** — conforma `vendedor`/`gerente`/`analista_credito`/`cobrador` (hoy texto plano repetido en `dim_cliente_comercial`/`dim_cliente_credito`) en una sola dimensión de rol compartido, fuente `bronze.sap_pa0001`. No reemplaza los IDs existentes, solo agrega la dimensión para reportería "por persona".
- **Utilización de crédito** — **no como vista SQL, como medida DAX** (`DIVIDE(SUM(saldo_total), SUM(limite_credito))`) directamente en Power BI, ya que `fact_saldo_cartera` y `dim_cliente_credito` ya están relacionadas en el modelo. Una vista o columna precalculada invitaría a que alguien la promedie mal (promediar razones ya calculadas es matemáticamente incorrecto en cualquier corte que no sea el grano exacto de la fila).
- **Etapa 2 del reporte de cobranza** ("presupuesto esperado" — cartera vencida/por vencer al inicio del mes) — `vw_cartera_abierta` solo resuelve la mitad *hacia adelante* (a partir de hoy). La reconstrucción retroactiva para meses pasados requiere combinar `bsid` (lo que sigue abierto hoy y ya estaba abierto en esa fecha) con `bsad` (lo que estaba abierto en esa fecha pero ya se compensó después) — diseño no trivial, todavía sin resolver.
- **Gestión de cobranza, castigos/incobrables, aprobación de límite de crédito** — procesos de negocio reales sin fuente de datos confirmada todavía. No se diseñan hasta confirmar con el equipo dónde vive esa información (SAP, Excel, otro sistema).
