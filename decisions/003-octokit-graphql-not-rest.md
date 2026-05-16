# 003 — Octokit GraphQL only, no @octokit/rest

- **Status**: Accepted
- **Date**: 2026-05-16

## Context

`GitHubProjectsAdapter` necesita hablar con la GitHub API. Hay tres operaciones distintas:

1. Read/write de project items (GitHub Projects v2 — **solo GraphQL**, no REST).
2. Close/reopen de Issues y posting de comments (disponible en ambos: GraphQL y REST).
3. Crear un webhook en el repo o org (solo REST — los webhooks no están en GraphQL API).

La pregunta: ¿qué librerías HTTP usamos?

## Decision

- **`@octokit/graphql` ^9** como única dependencia de Octokit. Se usa para Projects v2 (obligatorio) y para todas las mutations de Issues que tienen equivalente GraphQL (close/reopen/comment).
- **`fetch` nativo** de Bun/Node para el único endpoint REST que necesitamos: `POST /orgs/{org}/hooks` en `registerWebhook`. Inyectable como `FetchFn` para tests.

NO agregamos `@octokit/rest` como dependencia.

## Consequences

**Positivas:**

- Una dep en lugar de dos. `@octokit/rest` arrastra ~500 KB de plugins (paginate, retry, throttle, etc.) que no usamos.
- Consistencia interna: 90% de las operaciones del adapter pasan por el mismo cliente (`graphql`), facilita razonar sobre rate limits y manejo de errores.
- `fetch` nativo está disponible en cualquier runtime moderno (Bun, Node 18+, Deno) sin instalación.
- La inyección de `FetchFn` permite mockear `registerWebhook` sin complejidad.

**Negativas:**

- Si en v1 agregamos más operaciones REST de GitHub (e.g., gestión de secrets, deployments, codescanning), cada una requiere su propio bloque de `fetch` con manejo de errores, timeouts, retries. `@octokit/rest` ya tiene eso resuelto.
- No tenemos retry/throttle plugin de Octokit para Projects GraphQL. Si nos pegan los rate limits de GitHub, hay que implementar a mano.

## Alternatives considered

**`@octokit/rest` completo + `@octokit/graphql`**.

- *Por qué no en v0*: 1 operación REST no justifica 500 KB de dep + complejidad mental adicional.

**Solo `@octokit/rest`, ignorar GraphQL**.

- *Por qué no*: Projects v2 **solo** tiene GraphQL API. No es opción.

**Cliente HTTP genérico (`axios`, `ky`, etc.) sin Octokit en absoluto**.

- *Por qué no*: perderíamos los types autogenerados de Octokit para GraphQL responses, manejo de errores específico de GitHub (rate limit, abuse detection), y compatibilidad con cambios de la API. Vale 60 KB de dep para ganar todo eso.

## Revisit when

Migrar a `@octokit/rest` completo está justificado si:

1. Agregamos 3+ operaciones REST nuevas (deployments, secrets, runners, etc.) y los bloques de `fetch` repetitivos se vuelven costosos de mantener.
2. Pegamos rate limits de GraphQL y necesitamos el throttling plugin de Octokit.
3. Vemos beneficio de los retry plugins de Octokit para resilience automática.

Mientras solo necesitemos `registerWebhook` como única operación REST, mantenemos `fetch`.

## References

- [GitHub Projects v2 GraphQL docs](https://docs.github.com/en/issues/planning-and-tracking-with-projects/automating-your-project)
- [Webhooks REST endpoint](https://docs.github.com/en/rest/webhooks/orgs)
- [`GitHubProjectsAdapter` implementation](../../packages/adapters/src/github-projects/adapter.ts)