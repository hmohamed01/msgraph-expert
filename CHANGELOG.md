# Changelog

All notable changes to the msgraph-expert skill are documented in this file.

## [1.0.0] - 2026-09-13

### Added
- Initial skill with SKILL.md, four references, and two helper scripts
- **JSON-first metadata lookup** — cmdlet, URI, permission, and API-version facts resolve
  from `MgCommandMetadata.json` (31,201 entries) before any documentation is read
- Seven-step fallback chain: local `Find-MgGraphCommand` → remote JSON via `curl`/`jq` →
  GitHub contents API → raw markdown → `learn.microsoft.com` → WebSearch → local `Get-Help`
- `references/data-sources.md` — source-to-question routing table, verified `jq` recipes,
  entry shapes for all four JSON artifacts, raw markdown URL templates, module inventory,
  per-repository branch table, and 404 triage
- `references/best-practices.md` — auth flow selection, paging, property selection,
  server-side filtering, `$batch`, throttling, structured error codes
- `references/permissions.md` — delegated vs application intersection rule, least-privilege
  resolution per permission type, narrower alternatives to `.All`, app role assignment,
  grant auditing
- `references/migration.md` — AzureAD/MSOnline mapping, verb changes, four behavioural
  differences that break migrated scripts, five-step workflow
- `scripts/graph-meta.sh` — cache and `jq`-query the command map with no PowerShell
  dependency; prefers metadata already on disk from an installed SDK over downloading
- **Explicit-refresh-only cache policy** — no expiry, and no code path reaches the network
  without the user asking. `sync` (`--force`, `--remote`) and `-Refresh` are the only
  downloads; queries read the existing cache and fail with instructions when it is absent.
  Bootstrapping from an installed SDK is exempt as a local file copy. Documented for users
  in README.md and enforced as a constraint in CLAUDE.md
- `scripts/Find-GraphCommand.ps1` — four parameter sets (command, URI, permission, legacy)
  with local-first metadata resolution and remote fallback
- Verification policy requiring permissions, cmdlet existence, beta-only claims, and legacy
  mappings to be resolved from metadata rather than recalled

### Notes
- All URL templates, JSON entry shapes, and `jq` recipes verified against live sources on
  2026-09-13
- `Uri` is `null` on 14 metadata entries (authentication cmdlets bound to no endpoint);
  every `test()` recipe guards with `(.Uri // "")`
- `MgLegacyCommandMapping.json` covers 274 legacy cmdlets across 183 Graph cmdlets — partial
  coverage of the AzureAD and MSOnline surface, documented as such in `migration.md`
