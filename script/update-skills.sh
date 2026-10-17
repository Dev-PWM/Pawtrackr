#!/usr/bin/env bash
# Reinstall the CodeRabbit agent skills tracked in skills-lock.json into
# .claude/skills only.
#
# Don't run `npx skills update` or `npx skills add` without `-a` here. Both
# install into every agent the CLI detects in your home directory, plus
# .agents/skills, and that is how 48 copies of these skills got into the
# repo. With one explicit agent the CLI copies files instead of symlinking
# them, so .claude/skills keeps real files.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

# Pinned to the version whose agent selection was checked (2026-10-16).
npx --yes skills@1.7.1 add coderabbitai/skills \
  --skill autofix --skill code-review \
  --agent claude-code --copy --yes
