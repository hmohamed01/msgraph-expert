# Microsoft Graph Expert Skill

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Version](https://img.shields.io/badge/Version-1.0.0-green.svg)](CHANGELOG.md)
[![Platform](https://img.shields.io/badge/Platform-PowerShell%207+%20|%20Windows%20PowerShell%205.1-blue.svg)](https://github.com/PowerShell/PowerShell)
[![Graph SDK](https://img.shields.io/badge/Graph%20SDK-v1.0%20|%20beta-0078D4.svg)](https://learn.microsoft.com/en-us/powershell/microsoftgraph/)
[![Claude Code](https://img.shields.io/badge/Claude%20Code-Skill-blueviolet.svg)](https://claude.ai/code)

A Claude Code skill for Microsoft Graph PowerShell SDK development that resolves cmdlet,
endpoint, and permission facts from **structured JSON metadata first**, falling back to
documentation prose only for parameter tables and examples.

## Why JSON First

The Graph PowerShell SDK is code-generated, and the generator publishes a machine-readable
map of everything it produced — `MgCommandMetadata.json`, 31,000+ entries covering every
cmdlet, its Graph URI, HTTP method, API version, output type, and full permission list
with least-privilege flags.

That map answers most Graph questions *exactly*. The documentation repository answers the
same questions in prose, across 6 GB of markdown.

| Question | JSON | Markdown |
|----------|------|----------|
| Which cmdlet calls `GET /users/{id}/memberOf`? | one `jq` filter | full-text search |
| Least-privilege permission, per auth type? | a flagged field | scattered across a page |
| Is this cmdlet v1.0, beta, or both? | a field | two separate pages |
| What parameters does it take? | — | **the right source** |

The efficiency only materialises when the JSON is **filtered before it reaches context**.
This skill routes metadata through `jq` and `ConvertTo-Json` on selected objects, never
through a bulk fetch.

## Features

- **JSON-first lookup** — cmdlet, URI, permission, and API version resolved from SDK metadata
- **Offline by default** — uses the metadata shipped with an installed `Microsoft.Graph.Authentication`
- **No surprise downloads** — explicit-refresh-only cache; queries never reach the network on their own
- **Least-privilege resolution** — per permission type, not flattened to one answer
- **Legacy migration** — AzureAD/AzureADPreview/MSOnline cmdlet mapping from the official JSON
- **Raw markdown fallback** — deterministic URLs into the docs repo for parameter tables and examples
- **Verification policy** — permissions and cmdlet existence must be resolved, never recalled

## Installation

```bash
cp -r msgraph-expert ~/.claude/skills/
```

Or unzip the packaged skill:

```bash
unzip msgraph-expert.skill -d ~/.claude/skills/
```

**Requirements**: `jq` for the shell helper, `curl` for remote metadata. PowerShell 7+ and
`Microsoft.Graph.Authentication` are optional but make every lookup offline and instant.

## Usage

The skill activates when you ask Claude Code to:

- Write Microsoft Graph PowerShell scripts
- Find which cmdlet calls a Graph endpoint
- Determine the least-privilege permission for an operation
- Choose between v1.0 and beta
- Migrate AzureAD or MSOnline scripts
- Debug authentication, paging, filtering, or throttling

### Example Prompts

```
"Write a script to disable users who haven't signed in for 90 days"
"What's the minimum permission for New-MgGroup with app-only auth?"
"Which cmdlet calls GET /deviceManagement/managedDevices?"
"Migrate this AzureAD script to Microsoft Graph"
"Why is Department null on my Get-MgUser results?"
```

### Command-Line Helpers

Both scripts work standalone, with or without the SDK installed:

```bash
msgraph-expert/scripts/graph-meta.sh sync
msgraph-expert/scripts/graph-meta.sh command Get-MgUser
msgraph-expert/scripts/graph-meta.sh permissions New-MgGroup
msgraph-expert/scripts/graph-meta.sh uri '/deviceManagement/managedDevices'
msgraph-expert/scripts/graph-meta.sh legacy Get-AzureADUser
```

```powershell
./msgraph-expert/scripts/Find-GraphCommand.ps1 -Command Get-MgUser
./msgraph-expert/scripts/Find-GraphCommand.ps1 -Command New-MgGroup -LeastPrivilege
./msgraph-expert/scripts/Find-GraphCommand.ps1 -LegacyCommand Get-AzureADUser
```

### Cache Policy: Explicit Refresh Only

> **Nothing in this skill downloads metadata unless you ask it to.**
> `sync` is the only subcommand that touches the network, and `-Refresh` is the only
> switch that does so from PowerShell. Every query reads what is already cached and
> **fails with instructions** rather than silently pulling 21 MB.

The cache lives in `~/.cache/msgraph-expert` (`MSGRAPH_CACHE_DIR` to relocate) and has
**no expiry** — it is never refreshed behind your back, however old it gets.

| Situation | Behaviour |
|-----------|-----------|
| Cache present | Used as-is, at any age |
| Cache absent, Graph SDK installed locally | Copied from the installed module — a local file copy, no network |
| Cache absent, no SDK installed | **Error with instructions.** Never an automatic download |
| `sync` | Populates anything missing; leaves existing files untouched |
| `sync --force` | Re-resolves even if already cached |
| `sync --remote` | Ignores the installed SDK, takes the copy published on GitHub |

The trade-off is deliberate: a stale cache is visible and correctable, whereas an
unexpected 21 MB download in a metered, air-gapped, or automated context is neither.
Check age at any time with `graph-meta.sh status`, and refresh when it suits you:

```bash
msgraph-expert/scripts/graph-meta.sh status
msgraph-expert/scripts/graph-meta.sh sync --force
```

Because the metadata ships inside `Microsoft.Graph.Authentication`, anyone with the SDK
installed is already current and need never download at all.

## Skill Contents

```
msgraph-expert/
├── SKILL.md                    # Lookup tiers, quick reference, key patterns
├── scripts/
│   ├── graph-meta.sh           # Cache and jq-query the SDK command map
│   └── Find-GraphCommand.ps1   # Cmdlet/URI/permission lookup with remote fallback
└── references/
    ├── data-sources.md         # JSON source map, jq recipes, raw URL routing, 404 triage
    ├── best-practices.md       # Auth, paging, filtering, batching, throttling, errors
    ├── permissions.md          # Permission model, least privilege, consent, auditing
    └── migration.md            # AzureAD / MSOnline → Graph
```

## Data Sources

| Source | Repository | Branch |
|--------|------------|--------|
| Command map (JSON) | `microsoftgraph/msgraph-sdk-powershell` | `main` |
| Legacy cmdlet mapping (JSON) | `microsoftgraph/msgraph-sdk-powershell` | `main` |
| Permission definitions (JSON) | `microsoftgraph/microsoft-graph-devx-content` | `dev` |
| Cmdlet reference (markdown) | `MicrosoftDocs/microsoftgraph-docs-powershell` | `main` |
| OpenAPI descriptions (YAML) | `microsoftgraph/msgraph-metadata` | `master` |

Each repository settled on a different default branch — a frequent source of 404s.

## License

MIT
