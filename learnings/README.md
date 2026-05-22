# Learnings

This folder stores reusable knowledge captured from solved bugs, reviewer
findings, implementation discoveries, workflow failures, and operational
incidents.

The goal is compounding: once Helm or the team learns a pattern, future agents
should not rediscover it from scratch.

## When to add a learning

Add a learning when a finding can be generalized beyond the immediate PR:

- A bug exposed a wrong assumption about a framework, API, runtime, or workflow.
- A reviewer found a class of issue that could recur.
- A debugging path revealed what did not work and why.
- A process failure suggests a new guardrail.
- A workaround should be avoided or repeated deliberately.

Do not add a learning for purely mechanical typos or one-off local fixes unless
the investigation path itself is valuable.

## Categories

Use one category per file:

- `bug-pattern`
- `workflow-process`
- `agent-behavior`
- `security`
- `testing`
- `architecture`
- `integration`
- `operations`

## Template

```markdown
---
title: "<short title>"
category: "<category>"
date: "YYYY-MM-DD"
source:
  type: "pr | issue | session | incident | review"
  ref: "<url or identifier>"
tags: []
---

# <Title>

## Context

What situation produced this learning?

## Learning

What should future humans or agents remember?

## Why it matters

What breaks, slows down, or becomes risky if this is ignored?

## Apply when

When should an agent search for or use this learning?

## Related artifacts

- <links to specs, plans, PRs, ADRs, or pulse reports>
```
