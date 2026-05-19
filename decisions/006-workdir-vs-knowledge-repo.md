# ADR-006: Workdir vs Knowledge Repo — Modelo de Dos Capas para Artefactos de Agentes

**Status**: Accepted
**Date**: 2026-05-19
**Deciders**: LH (con input de Cowork session)

## Contexto

Helm orquesta agentes que producen artefactos: specs, plans, código generado, reviews. Esos artefactos eventualmente deben vivir en repos con source control para review humano e historia. Pero los agentes también necesitan espacio efímero de trabajo donde pueden iterar libremente (escribir scratch files, ejecutar herramientas, mantener estado intermedio).

La pregunta arquitectónica: ¿dónde escriben los agentes durante su sesión, y cómo llegan esos artefactos al source control eventualmente?

Esta distinción se hizo explícita al final de Sesión 9 cuando el smoke test del spec-writer mock buscó el `spec.md` generado en el directorio del knowledge repo (`<product>-knowledge/specs/`) y no lo encontró — porque el mock lo había escrito en un workdir efímero (`apps/api/data/worktrees/<product>/<item>/`). Funcionalmente correcto pero la ambigüedad de "dónde vive el artefacto" emerge.

## Decisión

**Adoptar un modelo explícito de dos capas con semánticas distintas:**

| Capa | Path | Propiedad | Lifecycle | Quién escribe |
|---|---|---|---|---|
| **Workdir** | `apps/api/data/worktrees/<productSlug>/<externalId>/` | Helm (operativa) | Efímero por item | Agent runtime durante la sesión |
| **Knowledge repo** | `<product>-knowledge/specs/`, `/plans/`, `/decisions/` | Humanos (review) | Persistente, source-of-truth | Git PR contra el knowledge repo |

**Reglas**:

1. Los agentes (mock o reales) escriben libremente en su workdir asignado. El workdir es per-item, aislado.
2. Knowledge repos **nunca son escritos directamente por agentes**. Solo se escriben via git PR.
3. Post-completion handlers de specialists son responsables del "publish step": commit + push + abrir PR contra el knowledge repo correspondiente.
4. El workdir puede ser limpiado entre runs sin pérdida de información (todo lo importante ya está en knowledge repo o en `data/items/`).

## Alternativas consideradas

- **Escribir directo al knowledge repo**: rechazada. Sin review humano, sin rollback fácil, debug más difícil. Cualquier bug en un specialist contamina la fuente de verdad inmediatamente.
- **Solo workdir, sin knowledge repo**: rechazada. No hay source of truth persistente; pierde la historia entre runs y entre máquinas.
- **Almacenamiento en DB en lugar de knowledge repo**: rechazada. Helm es filesystem-first por diseño (ver ADR-001 sobre la decisión de no usar DB local). Knowledge repo es git, por consistencia.

## Consecuencias

**Positivas**:
- Boundary de ownership clara entre Helm (operacional) y humanos (revisión).
- Knowledge repo siempre contiene contenido revisado.
- Workdir es seguro de limpiar — no es source of truth.
- El "publish step" es un punto natural para insertar validación, política, y filtrado de contenido sensible.

**Negativas**:
- Step extra (publish) entre completion del agent y update del knowledge repo. Más complejidad operacional.
- Posibles conflictos en workdir si dos agentes operan sobre el mismo item simultáneamente (mitigado por usar per-item subdirectorios, pero no completamente prevenido).
- Latencia: el conocimiento producido por un agent no está disponible en knowledge repo hasta que el PR de publish se mergea.

## Implementación

- **Sesión 9** (cerrada): implementación del workdir con `MockAgentRuntime`. Specialists post-completion handlers verifican el artefacto en workdir y transitan el stage. No hay publish step todavía.
- **Sesión 10-11**: implementación del publish step. El `ClaudeCodeRuntime` real va a producir specs/plans en su workdir; el handler post-completion va a hacer git commit + push + abrir PR contra `<product>-knowledge`. La transición del item solo se aplica después que el PR esté mergeado (o con flag opcional `optimistic: true` para entornos sin gate humano).

## Notas

- El workdir está bajo `data/worktrees/` (no `tmp/`) intencionalmente: persiste entre restarts del server, permitiendo debug post-mortem de sesiones de agent que fallaron.
- El nombre "worktree" no es accidental: anticipa la implementación con `git worktree` para specialists de código (`implementer`) que necesitan branches aislados de un code repo.

## Referencias

- ADR-001: Hand-rolled state machine para workflow transitions.
- ADR-005: IAgentRuntime uniform interface.
- agent-hq architecture: usa el mismo patrón (workdir + git worktrees) con `worktrees/` y branches; Helm hereda esto.