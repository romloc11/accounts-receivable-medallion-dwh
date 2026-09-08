# Fase 0 — Las preguntas que este DWH debe contestar

> **Qué es este documento.** El punto de partida del proyecto, escrito *después* de haberlo
> construido. La lección más cara fue haber modelado antes de fijar las preguntas: se invirtieron
> seis fases en la identificación pago↔factura y al medirla resultó que mueve el indicador de
> negocio menos de un punto porcentual, mientras que lo que el área realmente pedía —cobranza,
> DPP, cartera— ya se contestaba con dos tablas. Este documento existe para que la siguiente
> decisión de construir algo se tome contra una pregunta con dueño, no contra una intuición.
>
> **Cómo usarlo.** Cada pregunta trae el número real de julio 2026 para que la conversación sea
> sobre algo concreto. La columna *Estado* dice si hoy se contesta. Lo que hay que hacer con este
> documento es **corregirlo con el negocio**: sobran preguntas, faltan preguntas, y algunos
> números seguramente no son los que Crédito y Cobranza tiene en mente. Eso es el entregable de
> la Fase 0, no el documento tal como está.

---

## 1. Las preguntas

### Cobranza — cuánto dinero entró

| # | Pregunta | Grano | Fuente | Estado |
|---|---|---|---|---|
| Q1 | ¿Cuánto cobramos en el periodo? | mes / día | `fact_pagos` | ✅ hoy |
| Q2 | ¿Cuánto por canal, vendedor, cobrador y tipo de cliente? | mes × dimensión | `fact_pagos` + dims | ✅ hoy |
| Q3 | ¿Qué porcentaje de la cobranza quedó ligado a una factura? | mes | `fact_aplicacion` | ⏳ requiere backfill |

**Q1 — número de referencia.** Julio 2026 cerró en **~$214.0M** de cobranza total. La cifra
que se usa hoy en el dashboard (~$155.1M) corresponde solo a DZ dentro del alcance de la
vista; no incluye CP (mostrador/contado, ~$34.6M al mes) ni otros canales.

**Q3 — número de referencia.** En el alcance del dashboard, julio: **10,937 depósitos /
~$135.2M identificados**, 25 / ~$239K identificados a nivel lote, y **166 / ~$5.7M sin
identificar**. La falta de identificación está concentrada: **9 cuentas** (Kushky, seis de Mercado
Libre, Conekta) cargan $9.73M de los $16.3M totales, y **3,234 clientes quedan 100% identificados**.

> **Decisión pendiente del negocio:** ¿el dinero de pasarelas de pago se reporta como
> "no identificado" o como una categoría propia ("no identificable por naturaleza")? Una pasarela
> agrega dinero de compradores finales que nunca tuvieron factura de CIOSA; ninguna regla lo puede
> resolver. Hoy ensucia el indicador. Ver `PASARELA` en la sección 3.

---

### Comportamiento de pago — qué tan puntual paga cada cliente

| # | Pregunta | Grano | Fuente | Estado |
|---|---|---|---|---|
| Q4 | ¿Cuántos días tarda un cliente en pagar? (DPP) | factura | `fact_facturas` | ⚠️ con sesgo |
| Q5 | ¿Qué porcentaje del monto se paga a tiempo? | mes × dimensión | `fact_facturas` | ✅ hoy |
| Q6 | ¿Cómo se reparte el atraso en cubetas? | mes | `fact_facturas` | ✅ hoy |

**Q4 — número de referencia**, julio 2026, ponderado por monto:

| canal | DPP promedio simple | DPP ponderado | % del monto a tiempo |
|---|---:|---:|---:|
| 10 | −1.00 | **−0.38** | 48.7% |
| 40 | −40.25 | **−31.56** | 88.5% |
| 60 | −12.46 | **−6.04** | 65.2% |

Nunca se promedian días: se ponderan por monto. La diferencia llega a nueve días en canal 40,
porque el promedio simple trata una factura de $500 igual que una de ~$500K.

**Q4 tiene dos sesgos conocidos y medidos**, ambos corregibles con columnas derivadas:

1. **Facturas liquidadas sin efectivo.** 5,792 facturas / ~$8.6M de julio se compensaron con
   nota de crédito, devolución o ajuste — cero dinero — y hoy entran al DPP como si hubieran sido
   pagadas. Es el 4.5% del valor.
2. **La fecha de compensación no es la fecha del pago.** SAP compensa cuando alguien ejecuta la
   transacción, no cuando llegó el dinero. En agregado da casi igual (el 90% compensa el mismo
   día), pero **293 clientes se desplazan 2 días o más y algunos cambian de signo**: un cliente
   que pagó 3.6 días *antes* de su vencimiento aparece con 6.5 días de atraso. Si un cobrador usa
   ese dato para llamarle, queda mal parado.

**Q6 — número de referencia**, julio 2026, alcance real:

| cubeta | facturas | monto |
|---|---:|---:|
| anticipado | 42,816 | ~$77.1M |
| al vencimiento | 3,002 | ~$10.2M |
| 1–15 días | 19,525 | ~$66.1M |
| 16–30 días | 1,363 | ~$6.2M |
| 31–60 días | 448 | ~$2.9M |
| más de 60 | 142 | ~$1.0M |

> **Advertencia de diseño que hay que escribir en el reporte:** el DPP tiene **sesgo de
> supervivencia**. Solo entra la factura que ya se cobró; el cliente que nunca paga jamás aparece.
> Ver Q7: hoy hay $45.4M vencidos que no existen en ningún DPP. Un reporte de comportamiento de
> pago **debe** llevar las dos mitades —lo cerrado y lo abierto— o miente por omisión.

---

### Cartera — cuánto nos deben

| # | Pregunta | Grano | Fuente | Estado |
|---|---|---|---|---|
| Q7 | ¿Cuánto nos deben hoy y cuánto está vencido? | cliente / factura | `fact_facturas` (abiertas) | ✅ hoy |
| Q8 | ¿Cómo evolucionó la cartera y su antigüedad? | cliente × fecha | `fact_saldo_cartera` | ✅ hoy |
| Q9 | ¿Qué debe este cliente, línea por línea? | factura | `fact_facturas` | ✅ hoy |

**Q7 — número de referencia**, al día de hoy, alcance real:

| estado | facturas | monto |
|---|---:|---:|
| abierta, no vencida | 59,055 | ~$195.6M |
| abierta, vencida 1–30 | 6,951 | ~$23.9M |
| abierta, vencida 31–90 | 837 | ~$4.0M |
| **abierta, vencida +90** | **994** | **~$17.5M** |

---

### Conciliación — el trabajo diario de Crédito y Cobranza

| # | Pregunta | Grano | Fuente | Estado |
|---|---|---|---|---|
| Q10 | ¿Qué facturas pagó este depósito? ¿Qué pagó esta factura? | aplicación | `fact_aplicacion` | ⏳ requiere backfill |
| Q11 | ¿Qué dinero entró sin poder ligarse, y por qué? | aplicación | `fact_aplicacion` | ⏳ requiere backfill |

Q10 y Q11 son las **únicas** preguntas que justifican `fact_aplicacion`. Si el negocio no las
necesita, ese componente no se construye. Q11 no es un defecto que esconder: cada motivo
(`SOBRANTE_EN_HIJO`, `ORIGEN_ABIERTO`, `GRUPO_AMBIGUO`, `CADENA_AMBIGUA`) es accionable en SAP y
constituye una cola de trabajo entregable por sí sola.

---

### Presupuesto — el que todavía no existe

| # | Pregunta | Grano | Fuente | Estado |
|---|---|---|---|---|
| Q12 | ¿Cuánto voy a cobrar cada día del mes que entra? | día | no existe | ❌ por construir |

Es la pregunta de mayor valor de negocio y la única sin ninguna respuesta en el DWH. Hoy se
calcula a mano: el día 1 se suman las facturas que vencen ese mes y ese total se reparte por día
con porcentajes basados en la experiencia.

**El problema medido.** La cobranza de julio 2026 por origen:

| componente | monto | % |
|---|---:|---:|
| **B. vencía en julio** — lo único que el método actual presupuesta | ~$104.0M | **48.6%** |
| C. facturada *y* cobrada dentro del mes | ~$64.3M | 30.0% |
| A. venía vencida de meses anteriores | ~$29.1M | 13.6% |
| D. pago anticipado (vencía después de julio) | ~$16.5M | 7.7% |

**El método actual presupuesta menos de la mitad del dinero.** El 51% restante lo absorben los
porcentajes por día, que es exactamente por qué se siente impreciso. Los cuatro componentes se
modelan por separado; el detalle está en la memoria del proyecto (`presupuesto-cobranza-estrategia`).

---

## 2. Qué se contesta hoy y qué no

| | preguntas | comentario |
|---|---|---|
| ✅ Se contesta hoy | Q1, Q2, Q5, Q6, Q7, Q8, Q9 | 7 de 12, con `fact_facturas` + `fact_pagos` + `fact_saldo_cartera` + dims |
| ⚠️ Se contesta con sesgo | Q4 | necesita 4 columnas derivadas, no una tabla nueva |
| ⏳ Requiere terminar el backfill | Q3, Q10, Q11 | `fact_aplicacion` 2022→2026 |
| ❌ No existe | Q12 | el presupuesto |

**La conclusión que reordena el proyecto:** siete de doce preguntas ya se contestan con las tres
tablas de documento. `fact_aplicacion` sirve a tres preguntas, y una sola de ellas (Q4, vía
`fecha_pago_real`) afecta un reporte que el negocio ya usa. Q12 —la de mayor valor— no depende
de `fact_aplicacion` en absoluto.

---

## 3. Decisiones que necesitan firma del negocio

Ninguna de éstas es técnica. Todas están bloqueando trabajo hoy.

| # | Decisión | Por qué importa | Dueño propuesto |
|---|---|---|---|
| D1 | Definición de `clasificacion_cobranza` (`PAGO_ANTICIPADO` / `PAGO_A_VENCIMIENTO` / `PAGO_A_MES`) | cohorte mensual vs día exacto cambia <4% pero hay que fijarlo; ahora también cubre pagos parciales abiertos | Crédito y Cobranza |
| D2 | ¿`PASARELA` se separa de `MARKETPLACE`? | convierte $9.73M de "no identificado" (parece defecto) en "no identificable por naturaleza" (categoría legítima) | Crédito y Cobranza |
| D3 | ¿Las pasarelas y marketplaces entran al DPP? | no tienen comportamiento de pago; liquidan por otra mecánica y ensucian el promedio | Crédito y Cobranza |
| D4 | ¿El presupuesto incluye el componente C (facturación nueva)? ¿Quién produce ese pronóstico? | es el 30% del dinero y probablemente vive en Ventas, no en el DWH | Dirección / Ventas |
| D5 | Criterio de retiro de `vw_pago_factura_simple` | hay dos familias paralelas para lo mismo; nadie sabe cuál usar | Datos, con aviso a los consumidores |
| D6 | ¿Se acepta un pronóstico con margen de error publicado? | ningún pronóstico debería adoptarse sin su error medido | Dirección |

---

## 4. Reglas de diseño que salen de la experiencia

Se documentan aquí porque son las que hay que respetar al construir lo que sigue.

1. **El reporte primero, la plomería después.** No se construye un componente sin una pregunta de
   la sección 1 que lo exija, con dueño.
2. **Nunca inventar una aplicación.** Es preferible "Pago no identificado" a asignar mal. Es lo
   que hace que los números se puedan defender.
3. **Las invariantes son compuerta, no reporte.** Cacharon tres defectos que habrían publicado
   $1.1M de sobre-aplicación en silencio. Ningún dato se publica con una invariante en rojo.
4. **Cualquier regla que compare un documento contra "lo que ya se le aplicó" es global.** No
   puede filtrar por la ventana de carga. Este error apareció tres veces (topes acumulados, guarda
   de R0, y R6 se salvó por diseño más que por criterio). La consecuencia de fondo: **las reglas
   acumulativas y la carga incremental son incompatibles**; para hechos con reglas acumulativas,
   reconstrucción completa.
5. **El número correcto tiene que ser el que sale por default.** `SUM(monto_moneda_local)` sobre
   `fact_pagos` está mal porque la tabla trae espejos, traspasos y reversos. Debe existir
   `monto_cobranza`, que vale 0 en lo que no es cobranza.
6. **Modelable desde el día uno:** llave surrogada de una columna, PK compuesta solo como
   restricción de unicidad, una dimensión de cliente expuesta, una fecha oficial por hecho.
7. **Toda métrica publica su cobertura.** "DPP 34 días sobre el 93% de la cobranza identificada"
   es una afirmación honesta; "DPP 34 días" no lo es.

---

## 5. Hoja de ruta que se deriva de todo lo anterior

| orden | trabajo | pregunta que desbloquea | por qué en este lugar |
|---|---|---|---|
| 1 | Terminar el backfill de `fact_aplicacion` | Q3, Q10, Q11, y `fecha_pago_real` para Q4 | ya está a medio camino; abandonarlo cuesta más que terminarlo |
| 2 | Llaves surrogadas (`factura_key`, `pago_key`, `recibe_key`, `aplica_key`) | todas | sin ellas el modelo no se puede armar en Power BI: es el desbloqueo |
| 3 | Columnas aditivas por default: `monto_cobranza`, y `fecha_pago_real` / `forma_liquidacion` / `monto_liquidado_efectivo` / `dpp_confiable` | Q1, Q4 | quita los dos sesgos medidos y hace que el default sea correcto |
| 4 | `vw_cliente_360` y las vistas por pregunta de negocio | Q1–Q9 | es lo que hace el modelo usable para un analista |
| 5 | D1 y D2 con el negocio | Q3, Q4 | bloquean el cierre de los reportes |
| 6 | Retirar la familia vieja | todas | dos familias paralelas es el mayor problema de usabilidad de la capa |
| 7 | Calendario de días hábiles y festivos | Q12 | la pieza más barata del presupuesto y la que más ruido quita |
| 8 | Modelo de presupuesto + backtest de 3 meses | Q12 | el mayor valor de negocio del proyecto |

Los pasos 2 y 3 son los que cambian la experiencia de golpe y no dependen de nadie más.

---

## 6. Lo que no cambia

La estructura medallón, la investigación semántica en SAP GUI (el mejor trabajo del proyecto: es
lo que reveló el mecanismo real de depósito virgen → hijo → nietos → facturas, y eso no se deduce
consultando tablas), las invariantes como compuerta, el SQL explícito multi-paso, y la narrativa
de decisiones en `DESIGN.md`.
