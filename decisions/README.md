# Decisiones de arquitectura (ADRs)

Esta carpeta contiene Architecture Decision Records (ADRs) del producto Helm. Un ADR captura una decisión técnica importante, por qué se tomó, qué alternativas se consideraron y bajo qué condiciones vale reconsiderarla.

## Cuándo escribir un ADR

Una decisión merece ADR cuando cumple al menos uno de estos criterios:

- Cierra una elección entre múltiples alternativas razonables (no "obvio" desde el inicio).
- Tiene consecuencias que se van a sentir en muchos lugares del código.
- Cambiarla en el futuro va a ser costoso.
- Alguien que llegue al proyecto en 6 meses va a preguntar "¿por qué hicieron X y no Y?".

No merecen ADR las decisiones triviales (qué linter usar, qué color tiene un botón) ni las puramente operativas.

## Formato

Usamos [MADR](https://adr.github.io/madr/) en versión simplificada. Cada ADR tiene:

- **Título** descriptivo en kebab-case en el nombre del archivo.
- **Status**: `Proposed` | `Accepted` | `Deprecated` | `Superseded by ADR-NNN`.
- **Date**: fecha en que se aceptó (formato `YYYY-MM-DD`).
- **Context**: qué problema o disyuntiva motiva la decisión.
- **Decision**: qué se decidió, en una frase clara.
- **Consequences**: qué cambia como resultado (pros y contras honestos).
- **Alternatives considered**: opciones evaluadas y por qué se descartaron.
- **Revisit when**: condiciones futuras que justificarían reconsiderar.

## Numeración

ADRs se numeran secuencialmente con 3 dígitos: `001-`, `002-`, etc. Una vez asignado, el número no cambia ni se reusa.

Si un ADR queda obsoleto, su `Status` cambia a `Superseded by ADR-NNN` y se mantiene en el repo como referencia histórica. No se borran.

## Quién escribe ADRs

Cualquiera del equipo (humano o agente). Cuando un agente escribe un ADR, lo abre como PR para review humana — los ADRs son lo más alto en jerarquía de docs y vale revisarlos con cuidado.