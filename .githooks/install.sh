#!/usr/bin/env bash
#
# Point this repository's git hooks at the versioned .githooks directory.
#
# Git does not clone .git/hooks, so a hook only survives if it is committed and
# core.hooksPath points at it. Run this once per clone.

set -euo pipefail

repo_root=$(git rev-parse --show-toplevel)

git -C "$repo_root" config core.hooksPath .githooks
chmod +x "$repo_root/.githooks/pre-commit"

printf 'hooks installed: core.hooksPath -> .githooks\n'
printf 'pre-commit will repack the .skill archive when skill sources change.\n'
printf 'bypass once with: git commit --no-verify\n'
