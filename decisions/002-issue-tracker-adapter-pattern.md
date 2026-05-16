# 002 — IssueTrackerAdapter pattern with dependency injection

- **Status**: Accepted
- **Date**: 2026-05-16

## Context

Helm necesita soportar múltiples issue trackers (GitHub Projects, Linear, eventualmente Jira/ClickUp) sin que el resto del sistema (workflow engine, ItemStore, API endpoints) conozca el provider concreto. Hay dos decisiones acopladas que vale capturar juntas:

1. **Cómo se abstraen los trackers**: ¿Interfaz uniforme con N implementaciones? ¿Strategy pattern? ¿Plugin system?
2. **Cómo recibe el adapter sus credenciales y config**: ¿Lee variables de entorno directamente? ¿Las recibe por inyección?

## Decision

**Patrón Port-Adapter** con una interfaz `IssueTrackerAdapter` (en `@helm/adapters`) que define el contrato uniforme (`getItem`, `listItems`, `setSubStage`, `setStatus`, `comment`, `parseWebhook`, `registerWebhook`, `ensureSubStages`). Cada provider se implementa como clase concreta que cumple la interfaz: `GitHubProjectsAdapter`, `LinearAdapter` (Sesión 11), etc.

**Pure dependency injection**: los adapters reciben todos sus inputs (config, token, opciones) como argumentos del constructor. **NO leen `process.env` internamente**. El "wiring" entre env vars y constructor argumentos vive en una capa separada (`apps/api/src/services/index.ts`, función `getGitHubAdapter()` con single-flight singleton).

## Consequences

**Positivas:**

- Tests del adapter no requieren manipular `process.env` (cero contaminación entre tests).
- Cada adapter es construible con cualquier source de credenciales — env var, secret manager, archivo, otro singleton.
- El contrato de la interfaz es claro: si cumple los 8 métodos, es un adapter válido.
- Multi-tenant futuro (v1+) es trivial: construí N adapters con N configs distintas. Sin reescribir nada.
- Mock implementations (`MockAdapter`) son fáciles: solo cumplen la interfaz, sin lógica de auth.

**Negativas:**

- El wiring (`getGitHubAdapter`) tiene más boilerplate que "leer env var dentro del adapter".
- Hay dos lugares donde se interpreta config: el adapter (que la usa) y el wiring (que la construye). En la práctica esto no es problema porque Zod ya validó el config antes.
- Para usuarios CLI futuros, el wiring debe replicarse o exportarse.

## Alternatives considered

**Leer `process.env` dentro del adapter** (anti-patrón común).

- *Por qué no*: acopla el adapter a Node/Bun runtime, complica tests, impide multi-tenant trivial.

**Plugin system con discovery dinámico** (cargar adapters según `provider` en el config sin imports explícitos).

- *Por qué no en v0*: overkill para 2 adapters. Genera magic loading que dificulta debugging. Cuando lleguemos a 5+ adapters de comunidad, vale evaluar.

**Strategy pattern con factory function** en lugar de interface + class.

- *Por qué no*: clases con estado interno (cache, lookup tables) son más naturales para este caso. Factory functions serían correctas si los adapters fueran stateless puros, pero no lo son.

## Revisit when

Cambiar de patrón está justificado si:

1. Multi-tenant SaaS requiere instanciar 100s de adapters con configs distintas y el wiring se vuelve cuello de botella.
2. Aparecen adapters muy pesados (>50 MB de deps cada uno) y queremos cargar dinámicamente según provider del config.
3. Permitimos contribuciones de adapters de terceros y el wiring centralizado se vuelve obstáculo.
4. Vemos beneficio claro de moverse a strategy pattern functional (improbable con estado interno).

## References

- [Port-Adapter (Hexagonal Architecture) — Alistair Cockburn](https://alistair.cockburn.us/hexagonal-architecture/)
- [`IssueTrackerAdapter` interface](../../packages/adapters/src/interface.ts)
- [`GitHubProjectsAdapter` implementation](../../packages/adapters/src/github-projects/adapter.ts)
- [`getGitHubAdapter` wiring](../../apps/api/src/services/index.ts)