# 001 — Hand-rolled state machine for workflow engine

- **Status**: Accepted
- **Date**: 2026-05-14

## Context

Helm necesita modelar el ciclo de vida de un Item del workflow (los 9 sub-stages canónicos: `discovery → spec-draft → spec-ready → plan-draft → plan-ready → in-development → code-review → remediation → released`) como una máquina de estados.

Las transiciones tienen restricciones: no todo stage puede ir a cualquier otro. Hay flujo principal hacia adelante con algunas transiciones de vuelta atrás explícitas (`code-review → in-development` cuando reviewer pide cambios, `remediation → code-review` después de fix, `plan-draft → spec-draft` si el plan revela ambigüedad en el spec).

El engine tiene que validar transiciones en runtime (cuando un endpoint API o un evento del tracker dispara un cambio) y idealmente también en compile-time (para que el código que mueva items entre stages no tenga magic strings).

## Decision

Implementar el workflow engine como una **state machine hand-rolled en TypeScript puro**, sin librería externa. La implementación es un objeto `TransitionMap` que mapea `WorkflowStage → WorkflowStage[]` con las transiciones válidas, más funciones puras (`canTransition`, `validateTransition`, `getValidNextStages`).

## Consequences

**Positivas:**

- Cero dependencias runtime. El engine es ~50 líneas de TypeScript que cualquiera puede leer y entender.
- Tipos exhaustivos: cuando agregamos un sub-stage nuevo, el compiler nos avisa de todos los lugares que necesitan actualización (vía `Record<WorkflowStage, ...>` exhaustive checks).
- Tests triviales: no hay engine externo cuya semántica que aprender; solo lógica propia.
- Tree-shaking limpio: lo que no se usa, no se incluye en el bundle.

**Negativas:**

- Si en algún momento necesitamos sub-states (ej. `code-review` con sub-estados `awaiting-code-reviewer`, `awaiting-security-reviewer`, `awaiting-test-reviewer`), tenemos que escribirlos a mano o migrar a una librería.
- Sin features avanzadas como history states, parallel regions, async guards con retry. Si aparecen, hay que construirlas.
- Reinventamos algunos patrones que otras librerías ya tienen resueltos (visualización, debugging tools).

## Alternatives considered

**XState** (≈30 KB minified, soporta sub-states, parallel regions, history, actor model, visualization tools).

- *Por qué no en v0:* overkill para 9 stages lineales con guards simples. Curva de aprendizaje no trivial. Añade superficie de ataque sin beneficio inmediato.
- *Cuándo volverlo a evaluar:* cuando agreguemos paralelismo (ej. tres reviewers corriendo en paralelo modelados como sub-machine del stage `code-review`), retries automáticos con backoff, o necesitemos visualizar el workflow en una UI dedicada.

**Robot3** (≈4 KB, state machines minimalistas).

- *Por qué no:* aún siendo más liviano que XState, agrega dependencia y semántica nueva para resolver algo que es ~50 LOC en TypeScript. El costo de aprenderla y mantenerla no se compensa con beneficio en v0.

**finity / state-machine.js / etc.**

- *Por qué no:* mismas razones — bibliotecas para casos que no tenemos.

## Revisit when

Migrar a una librería de state machines (probablemente XState) está justificado si alguna de estas condiciones se cumple:

1. Aparece la necesidad de modelar paralelismo dentro de un stage (ej. tres reviewers paralelos).
2. Agregamos sub-states (ej. `code-review` con varios sub-estados internos).
3. El workflow se vuelve dinámico (cliente puede definir sus propios stages vía `.helm/product.yaml`, no solo elegir cuáles de los 9 canónicos habilitar).
4. Construimos una UI de visualización del workflow que se beneficie de las herramientas de XState.
5. Necesitamos history states para "volver al stage previo" sin codificarlo manualmente.

Mientras ninguna de esas necesidades aparezca, mantenemos hand-rolled.

## References

- [MADR format](https://adr.github.io/madr/)
- [WorkflowStateMachine code](../../packages/workflow/src/state-machine.ts) (en `lhpaul/helm`)
- [XState docs](https://xstate.js.org/) para evaluación de la alternativa principal.