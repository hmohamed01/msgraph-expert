# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is a Claude Code skill for Microsoft Graph PowerShell SDK development. The skill
resolves cmdlet, endpoint, and permission facts from structured JSON metadata published by
the SDK, and falls back to the documentation repository only for parameter tables and
worked examples.

## Build Commands

```bash
# Package the skill (creates .skill zip file)
zip -r msgraph-expert.skill msgraph-expert -x "*.DS_Store"

# Install to Claude Code skills directory
cp -r msgraph-expert ~/.claude/skills/

# Verify the helper scripts
bash -n msgraph-expert/scripts/graph-meta.sh
msgraph-expert/scripts/graph-meta.sh sync && msgraph-expert/scripts/graph-meta.sh command Get-MgUser
pwsh -NoProfile -File msgraph-expert/scripts/Find-GraphCommand.ps1 -Command Get-MgUser
```

## Architecture

Standard Claude Code skill structure:

- `msgraph-expert/SKILL.md` — skill definition with frontmatter (name, description), the
  metadata lookup tiers, and core patterns. This is what Claude loads when the skill triggers.
- `msgraph-expert/references/` — loaded on demand to keep context efficient:
  - `data-sources.md` — JSON source routing, `jq` recipes, raw URL templates, 404 triage
  - `best-practices.md` — auth, paging, filtering, batching, throttling, error handling
  - `permissions.md` — permission model, least privilege, consent, auditing
  - `migration.md` — AzureAD / MSOnline → Graph
- `msgraph-expert/scripts/` — executable without loading into context:
  - `graph-meta.sh` — cache and `jq`-query the SDK command map (no PowerShell needed)
  - `Find-GraphCommand.ps1` — cmdlet/URI/permission lookup, local metadata with remote fallback

## Skill Design Principles

- SKILL.md stays under 500 lines; detail goes in `references/`
- Reference files load only when needed (progressive disclosure)
- Scripts execute without entering context
- The frontmatter description determines when the skill triggers

## The JSON-First Rule

This is the skill's defining constraint and the reason it differs from `powershell-expert`.

**Structured JSON is the first source; markdown is the second.** The ordering is not a
blanket efficiency claim — it is a routing rule based on which source actually holds the
answer:

| Answer shape | Source |
|--------------|--------|
| A name, URI, version, or permission | `MgCommandMetadata.json` |
| A signature, parameter table, or example | Raw markdown |

**JSON only pays off when filtered before it enters context.** The command map is 21 MB.
Always pipe through `jq` or project with `Select-Object` before emitting. Never WebFetch a
metadata file — WebFetch has no server-side filter and would pull the whole payload in.

Use **Bash + `curl` + `jq`** for remote JSON, and **WebFetch** only for markdown.

## Cache Policy: Explicit Refresh Only

Neither helper script may reach the network without the user asking. `graph-meta.sh sync`
and `Find-GraphCommand.ps1 -Refresh` are the only paths that download; every query reads
the existing cache and fails with instructions when it is absent. The cache has no expiry
and is never refreshed implicitly.

Copying from an installed `Microsoft.Graph.Authentication` module is exempt — it is a
local file copy, not a network fetch.

Preserve this when editing: a stale cache is visible and correctable, an unexpected 21 MB
download in a metered or automated context is not. Do not reintroduce a TTL, a background
refresh, or an auto-download fallback.

## Verification Requirements

Permissions, cmdlet existence, beta-only claims, and legacy cmdlet mappings **must** be
resolved from metadata, never recalled. Over-privileged permission recommendations are the
highest-cost failure mode for this skill — `IsLeastPrivilege` is recorded per permission
type, and flattening it to a single answer over-privileges one auth flow.

## Editing Notes

- Verify every URL before documenting it; the four upstream repositories use three
  different default branches (`main`, `dev`, `master`)
- Raw GitHub paths are case-sensitive — preserve dotted PascalCase module folders
- `Uri` is `null` on 14 metadata entries; guard `jq` `test()` calls with `(.Uri // "")`
