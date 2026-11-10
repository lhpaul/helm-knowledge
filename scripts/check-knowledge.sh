#!/usr/bin/env bash
# Lightweight structural checks for knowledge-repo PRs (#127).
#
# Usage: scripts/check-knowledge.sh [BASE_REF]
#   Always checks required files and REVIEW.md. With BASE_REF (for example
#   origin/main) it also checks the specs/plans changed since the merge base.
# Exit code is non-zero when any check fails.
set -u

BASE_REF="${1:-}"
FAILS=0

fail() {
  echo "::error::$*"
  FAILS=$((FAILS + 1))
}

require_file() {
  if [ ! -f "$1" ]; then
    fail "required file missing: $1"
  elif [ ! -s "$1" ]; then
    fail "required file is empty: $1"
  fi
}

# 1. Required files.
for f in README.md REVIEW.md strategy.md .helm/product.yaml \
  specs/README.md plans/README.md decisions/README.md; do
  require_file "$f"
done

# 2. REVIEW.md: must keep the review contract the external reviewer reads.
if [ -s REVIEW.md ]; then
  head -n 1 REVIEW.md | grep -q '^# ' ||
    fail "REVIEW.md must start with a level-1 heading"
  grep -qi 'blocking' REVIEW.md ||
    fail "REVIEW.md must define what counts as a blocking finding"
  grep -qi 'clean' REVIEW.md ||
    fail "REVIEW.md must define when a review is clean"
fi

# 3. Specs and plans changed by this PR.
if [ -n "$BASE_REF" ]; then
  if ! MERGE_BASE=$(git merge-base "$BASE_REF" HEAD 2>/dev/null); then
    fail "cannot compute merge base against $BASE_REF"
  else
    # Added, copied, modified or renamed files only (deleted files are skipped).
    CHANGED=$(git diff --name-only --diff-filter=ACMR "$MERGE_BASE" HEAD -- \
      'specs/*.md' 'plans/*.md')
    while IFS= read -r f; do
      [ -z "$f" ] && continue
      case "$f" in
        specs/README.md | plans/README.md) continue ;;
      esac
      case "$f" in
        specs/issue_[0-9]*.md | plans/issue_[0-9]*.md) ;;
        *) fail "$f: spec/plan files must be named issue_<number>.md" ;;
      esac
      if [ ! -s "$f" ]; then
        fail "$f: file is empty"
        continue
      fi
      head -n 1 "$f" | grep -q '^# ' ||
        fail "$f: must start with a level-1 heading"
      grep -q '^## ' "$f" ||
        fail "$f: must contain at least one level-2 section"
    done <<< "$CHANGED"
  fi
fi

if [ "$FAILS" -gt 0 ]; then
  echo "knowledge checks failed: $FAILS problem(s)"
  exit 1
fi
echo "knowledge checks passed"
