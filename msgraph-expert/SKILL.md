---
name: msgraph-expert
description: Develop Microsoft Graph PowerShell SDK scripts and automation against Microsoft Entra ID, Exchange, Teams, SharePoint, and Intune. Use when writing Mg cmdlets, resolving which cmdlet calls a Graph endpoint, determining least-privilege permissions, choosing between v1.0 and beta, migrating from AzureAD/MSOnline, or handling authentication, paging, filtering, and throttling. Resolves cmdlet, URI, and permission facts from structured JSON metadata before falling back to documentation prose.
---

# Microsoft Graph Expert

Build production-quality automation on the Microsoft Graph PowerShell SDK, resolving
every cmdlet, endpoint, and permission fact against live metadata rather than recall.

## Quick Reference

### Connect

```powershell
# Interactive (delegated) — scopes are additive across calls
Connect-MgGraph -Scopes 'User.Read.All', 'Group.Read.All'

# App-only with a certificate (unattended, preferred for automation)
Connect-MgGraph -ClientId $appId -TenantId $tenantId -CertificateThumbprint $thumb

# Managed identity (Azure Automation, Azure VMs, Functions)
Connect-MgGraph -Identity

# Inspect the live session before assuming a scope is present
Get-MgContext | Select-Object Account, AppName, TenantId, Scopes, AuthType
```

### Script Skeleton

```powershell
#Requires -Modules Microsoft.Graph.Authentication, Microsoft.Graph.Users

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$TenantId,

    [ValidateSet('v1.0', 'beta')]
    [string]$ApiVersion = 'v1.0'
)

begin {
    $requiredScopes = @('User.Read.All')
    $context = Get-MgContext

    if (-not $context -or $requiredScopes | Where-Object { $_ -notin $context.Scopes }) {
        Connect-MgGraph -TenantId $TenantId -Scopes $requiredScopes -NoWelcome
    }
}

process {
    Get-MgUser -All -Property Id, DisplayName, UserPrincipalName, AccountEnabled |
        Where-Object { -not $_.AccountEnabled }
}
```

## Metadata Lookup

**Resolve cmdlet, URI, permission, and API-version facts from JSON before reading any
documentation page.** The SDK ships a machine-readable map of every command; the docs
repository ships prose about them. JSON answers *which cmdlet, which endpoint, which
permission* deterministically. Markdown answers *which parameters, what shape, what
example*. Route by the question, and start at JSON.

### Tier 1 — JSON (first choice)

JSON only wins if it is **filtered before it enters context**. Pipe through `jq` or
`ConvertTo-Json` on a selected object — never read a metadata file wholesale.

#### 1a. Local SDK metadata (no network)

When `Microsoft.Graph.Authentication` is installed, the full command map is already on
disk and queryable offline. Always try this first.

```powershell
# Cmdlet -> URI, method, API version, variants
Find-MgGraphCommand -Command Get-MgUser | Select-Object -First 1 |
    Select-Object Command, URI, Method, APIVersion, Variants | ConvertTo-Json -Depth 3

# Graph URI -> the cmdlets that call it (wildcards allowed, regex under the hood)
Find-MgGraphCommand -Uri '/users/{id}/memberOf' -Method GET |
    Select-Object Command, APIVersion, Variants | ConvertTo-Json -Depth 3

# Permissions a cmdlet needs, least-privilege first
(Find-MgGraphCommand -Command Get-MgUser).Permissions |
    Where-Object IsLeastPrivilege | Select-Object Name, PermissionType, IsAdmin

# Permission name -> id, consent type, description
Find-MgGraphPermission -SearchString 'User.Read.All' -PermissionType Application
```

Backing files under `(Get-Module Microsoft.Graph.Authentication -ListAvailable).ModuleBase`:

| File | Size | Contents |
|------|------|----------|
| `custom/common/MgCommandMetadata.json` | ~21 MB | 31,000+ command/URI entries with permissions |
| `custom/common/MgLegacyCommandMapping.json` | ~27 KB | AzureAD / MSOnline cmdlet → Mg cmdlet |

#### 1b. Remote JSON (module not installed, or verifying against latest)

Use **Bash + `curl` + `jq`**, not WebFetch — WebFetch would pull the whole payload into
context. Cache once, then query the cache.

```bash
# Cache the command map (~21 MB, ~2s), then query it for pennies
scripts/graph-meta.sh sync
scripts/graph-meta.sh command Get-MgUser
scripts/graph-meta.sh uri '/users/{user-id}/memberOf'
scripts/graph-meta.sh permissions Get-MgUser
scripts/graph-meta.sh legacy Get-AzureADUser
```

**The cache never refreshes itself.** `sync` is the only subcommand that downloads;
queries read what is cached and error out if it is absent. If a query reports a missing
cache, say so and let the user run `sync` — do not work around it by fetching the
metadata another way.

Source URLs and raw `jq` recipes are in **[data-sources.md](references/data-sources.md)**.

#### 1c. GitHub contents API (directory discovery)

Returns plain JSON listings. Use it to resolve an unknown module folder before building
a raw markdown URL — never to fetch a file whose path is already known.

```
https://api.github.com/repos/{owner}/{repo}/contents/{path}
```

Unauthenticated: 60 requests/hour. With `gh` available, `gh api` uses your token and
raises that to 5,000.

### Tier 2 — Raw markdown (parameters, syntax, examples)

Reach for markdown when the question is about **parameter names, types, defaults, or
worked examples** — facts the command map does not carry.

```
https://raw.githubusercontent.com/MicrosoftDocs/microsoftgraph-docs-powershell/main/microsoftgraph/{docset}/{Module}/{Cmdlet}.md
```

| Docset | Module prefix | Modules |
|--------|---------------|---------|
| `graph-powershell-1.0` | `Microsoft.Graph.*` | 39 |
| `graph-powershell-beta` | `Microsoft.Graph.Beta.*` | 43 |

```
.../graph-powershell-1.0/Microsoft.Graph.Users/Get-MgUser.md
.../graph-powershell-beta/Microsoft.Graph.Beta.Users/Get-MgBetaUser.md
```

Paths are **case-sensitive** and raw serves blobs only — a trailing `/` always 404s.
Full routing, the module inventory, and 404 triage live in
**[data-sources.md](references/data-sources.md)**.

**WebFetch prompt**: `Extract the complete syntax blocks, the full parameter table with
types and defaults, and the examples.`

### Fallback Chain

Escalate one step at a time, only on failure:

| Step | Tool | Use when |
|------|------|----------|
| 1 | `Find-MgGraphCommand` / `Find-MgGraphPermission` | Module installed — instant and offline |
| 2 | **Bash** `curl` + `jq` on remote JSON | Module absent, or confirming against the latest SDK release |
| 3 | **Bash** `gh api` / contents API | A module folder name is unknown |
| 4 | **WebFetch** raw markdown | Parameter tables, syntax blocks, examples |
| 5 | **WebFetch** `learn.microsoft.com` | Conceptual articles with no raw source |
| 6 | **WebSearch** | Path cannot be derived — then convert back to a raw URL and re-enter at step 4 |
| 7 | Local execution | Ask the user to run `Get-Help {Cmdlet} -Full` or `Find-MgGraphCommand -Command {Cmdlet}` |

If every step fails, state the uncertainty rather than guessing:

> "I couldn't verify this against live metadata. Please confirm with:
> `Find-MgGraphCommand -Command Get-MgUser | Select-Object -Expand Permissions`"

### Verification Requirements

| Scenario | Requirement |
|----------|-------------|
| Stating which permission a cmdlet needs | **MUST** resolve from JSON metadata |
| Claiming a cmdlet exists | **MUST** resolve from JSON metadata |
| Saying a feature is beta-only | **MUST** check both `v1.0` and `beta` in metadata |
| Mapping an AzureAD/MSOnline cmdlet | **MUST** check `MgLegacyCommandMapping.json` |
| Giving exact parameter syntax | **SHOULD** verify against raw markdown |
| General patterns and idioms | Static references suffice |

**Good** (resolved from metadata):
> `Get-MgUser` calls `GET /users/{user-id}`. Least privilege is `User.ReadBasic.All`
> (application) — not `User.Read.All`, which grants more than this cmdlet needs.

**Bad** (recalled):
> "You'll need `User.Read.All` for that." ← likely over-privileged, possibly wrong

## Key Patterns

### Paging — never hand-roll `@odata.nextLink`

```powershell
# Correct: -All follows nextLink internally
$users = Get-MgUser -All -Property Id, DisplayName

# Correct: bounded page size for large tenants
Get-MgUser -All -PageSize 999 -Property Id, UserPrincipalName
```

`-Top` limits the *total* returned, not the page size. `-PageSize` sets the page
(max 999 for most resources).

### Select only what you need

Graph returns a default property set; anything outside it comes back `$null` **without
error** — the quietest failure in the SDK.

```powershell
# $_.Department is silently $null — it is not in the default set
Get-MgUser -All | Select-Object DisplayName, Department

# Correct
Get-MgUser -All -Property Id, DisplayName, Department |
    Select-Object DisplayName, Department
```

### Server-side filtering beats `Where-Object`

```powershell
# Filters in the tenant, transfers only matches
Get-MgUser -Filter "accountEnabled eq false" -All

# Advanced queries ($count, endsWith, not, OR on multi-value) need ConsistencyLevel
Get-MgUser -Filter "endsWith(mail,'@contoso.com')" -ConsistencyLevel eventual -CountVariable c -All
```

### Error handling

```powershell
try {
    Get-MgUser -UserId $upn -ErrorAction Stop
}
catch {
    # Graph errors are generic RestException[T]; match on the body's code, not the type
    $detail = $_.ErrorDetails.Message | ConvertFrom-Json -ErrorAction SilentlyContinue

    switch ($detail.error.code) {
        'Request_ResourceNotFound'    { Write-Warning "No such user: $upn"; return }
        'Authorization_RequestDenied' { throw "Missing scope. Have: $((Get-MgContext).Scopes -join ', ')" }
        default                       { throw }
    }
}
```

### Throttling

Graph returns `429` with a `Retry-After` header. The SDK retries automatically, but
batch and loop-heavy scripts should still back off — see
[best-practices.md](references/best-practices.md).

## Module Selection

Install per-service modules, not the `Microsoft.Graph` meta-module — it pulls 40+
modules and slows every session start.

```powershell
Install-PSResource Microsoft.Graph.Users, Microsoft.Graph.Groups -Scope CurrentUser -TrustRepository
```

`Microsoft.Graph` (v1.0) and `Microsoft.Graph.Beta` cmdlets differ by an infixed `Beta`:
`Get-MgUser` / `Get-MgBetaUser`. Both can be loaded at once; the beta modules are a
separate install. **Never ship beta cmdlets to production without flagging it** — beta
endpoints change without notice and carry no deprecation guarantee.

## Reference Files

| Topic | File |
|-------|------|
| JSON source map, `jq` recipes, raw URL routing, 404 triage | [references/data-sources.md](references/data-sources.md) |
| Auth, paging, batching, filtering, throttling, error handling | [references/best-practices.md](references/best-practices.md) |
| Permission model, least privilege, consent, app-only setup | [references/permissions.md](references/permissions.md) |
| AzureAD / MSOnline → Graph migration | [references/migration.md](references/migration.md) |

## Included Scripts

| Script | Purpose |
|--------|---------|
| [scripts/graph-meta.sh](scripts/graph-meta.sh) | Cache and `jq`-query the SDK command map without PowerShell |
| [scripts/Find-GraphCommand.ps1](scripts/Find-GraphCommand.ps1) | Cmdlet/URI/permission lookup, local metadata with remote fallback |
