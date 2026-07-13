# Helm official backlog (GitHub Project #3)

Canonical board: https://github.com/users/lhpaul/projects/3

Wired in `.helm/product.yaml`:

```yaml
issue_tracker:
  provider: github_projects
  org: lhpaul
  project_number: 3
  custom_field_name: Helm Stage
```

## Required fields

| Field | Purpose |
|-------|---------|
| **Status** | Todo / In Progress / Done (human board) |
| **Helm Stage** | Workflow stage (Helm writeback; includes `merged` per ADR-032) |
| **Type** | Feature / Bug / Refactor / Workflow |

## Creating backlog items

Prefer the helper (creates the issue **and** adds it to the project):

```bash
cd ~/Git/Helm/helm
./scripts/create-helm-backlog-issue.sh \
  --title "Review loop: …" \
  --body "…" \
  --type Workflow \
  --label enhancement \
  --label review-loop
```

Or manually:

```bash
URL=$(gh issue create --repo lhpaul/helm --title "…" --body "…" --label enhancement)
gh project item-add 3 --owner lhpaul --url "$URL"
```

> Creating an issue alone is **not** enough unless the Project **Auto-add**
> workflow is enabled for `lhpaul/helm`.

## Personal-account sync

Project #3 is user-owned. GitHub does not send `projects_v2_item` webhooks for
personal projects. After board changes that Helm should see, run:

```bash
pnpm --filter @helm/api sync helm
```

## Agent rule

When filing Helm framework backlog from a session/retro, always use the helper
(or `issue create` + `item-add`). Never leave orphan issues that are not on
Project #3.
