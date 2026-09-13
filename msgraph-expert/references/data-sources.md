# Microsoft Graph Data Sources

Routing map for resolving Graph PowerShell facts. **Structured JSON first, documentation
prose second.**

The Microsoft Graph PowerShell SDK is generated from the Graph OpenAPI description, and
the generator emits a machine-readable map of everything it produced. That map — not the
documentation — is the authoritative answer to *which cmdlet, which endpoint, which
permission, which API version*. The docs repository is 6 GB of markdown describing those
same commands in prose; it is the right source for parameter tables and examples, and the
wrong source for anything the map already states exactly.

---

## Which Source Answers Which Question

| Question | Source | Tier |
|----------|--------|------|
| Which cmdlet calls `GET /users/{id}/memberOf`? | `MgCommandMetadata.json` | 1 |
| What permissions does `Get-MgUser` need? | `MgCommandMetadata.json` | 1 |
| What is the *least-privilege* permission? | `MgCommandMetadata.json` (`IsLeastPrivilege`) | 1 |
| Is this cmdlet in v1.0, beta, or both? | `MgCommandMetadata.json` (`ApiVersion`) | 1 |
| What replaces `Get-AzureADUser`? | `MgLegacyCommandMapping.json` | 1 |
| What does permission X grant, and who consents? | `permissions.json` / `Find-MgGraphPermission` | 1 |
| Which endpoints accept permission X? | `permissions.json` (`pathSets`) | 1 |
| What module folder holds this cmdlet? | GitHub contents API | 1 |
| What parameters does `Get-MgUser` take? | Raw markdown | 2 |
| What does a worked example look like? | Raw markdown | 2 |
| How does app-only auth work conceptually? | `docs-conceptual/` markdown | 2 |

**The rule:** if the answer is a name, a URI, a version, or a permission, it is in JSON.
If the answer is a signature or a narrative, it is in markdown.

---

## Tier 1a — Local SDK Metadata

Installed with `Microsoft.Graph.Authentication`. No network, no rate limit, ~50 ms.

```powershell
$moduleBase = (Get-Module Microsoft.Graph.Authentication -ListAvailable |
    Sort-Object Version -Descending | Select-Object -First 1).ModuleBase
```

| File | Size | Shape |
|------|------|-------|
| `$moduleBase/custom/common/MgCommandMetadata.json` | ~21 MB | Flat array, 31,000+ entries |
| `$moduleBase/custom/common/MgLegacyCommandMapping.json` | ~27 KB | Flat array, `Command` + `LegacyMapping[]` |

The shipped cmdlets query these directly:

```powershell
Find-MgGraphCommand -Command Get-MgUser
Find-MgGraphCommand -Uri '/users/{id}/memberOf' -Method GET
Find-MgGraphCommand -Command 'Get-MgUser' -ApiVersion beta
Find-MgGraphPermission -SearchString 'Directory.Read' -PermissionType Application
```

`-Uri` matching is regex-based, so a literal `{id}` segment matches any placeholder name.
`-Command` accepts wildcards.

Prefer the cmdlets over reading the file — they index it and return typed objects. Read
the raw file only when `jq` filtering is more expressive than the cmdlet's parameters.

---

## Tier 1b — Remote JSON

Use `curl` piped to `jq` from **Bash**. Do not WebFetch these — the payloads are tens of
megabytes and WebFetch has no server-side filter.

### MgCommandMetadata.json

The command map. Same file the SDK ships, at the tip of `main`.

```
https://raw.githubusercontent.com/microsoftgraph/msgraph-sdk-powershell/main/src/Authentication/Authentication/custom/common/MgCommandMetadata.json
```

~21 MB, ~2s on a normal connection. **Cache it** — see
[scripts/graph-meta.sh](../scripts/graph-meta.sh).

**Entry shape** (verified):

```json
{
  "Uri": "/applications/{application-id}/addKey",
  "Command": "Add-MgApplicationKey",
  "ApiVersion": "v1.0",
  "Variants": ["Add", "AddExpanded", "AddViaIdentity", "AddViaIdentityExpanded"],
  "Method": "POST",
  "Permissions": [
    {
      "Name": "Application.ReadWrite.All",
      "Description": "Read and write applications",
      "FullDescription": "Allows the app to create, read, update and delete applications...",
      "IsAdmin": true,
      "PermissionType": "DelegatedWork",
      "IsLeastPrivilege": true
    }
  ],
  "OutputType": "IMicrosoftGraphKeyCredential",
  "Module": "Applications",
  "ApiReferenceLink": "https://learn.microsoft.com/graph/api/application-addkey?view=graph-rest-1.0",
  "CommandAlias": null
}
```

Every entry carries exactly these ten keys: `ApiReferenceLink`, `ApiVersion`, `Command`,
`CommandAlias`, `Method`, `Module`, `OutputType`, `Permissions`, `Uri`, `Variants`.

`ApiVersion` is `v1.0`, `beta`, or empty (a handful of authentication cmdlets bound to no
endpoint). `PermissionType` is `DelegatedWork`, `DelegatedPersonal`, or `Application`.

`ApiReferenceLink` is the highest-leverage field in the file: it hands back the exact REST
reference URL for the underlying endpoint, removing the search step entirely when a
question crosses from PowerShell into the REST API.

`Uri` is `null` on 14 entries — the authentication and profile cmdlets that call no
endpoint. **Guard every `test()` against it** (`(.Uri // "")`), or `jq` aborts the whole
scan on the first null.

**`jq` recipes** — all filter before anything reaches context:

```bash
META=~/.cache/msgraph-expert/MgCommandMetadata.json

# Cmdlet -> endpoint facts
jq -c '.[] | select(.Command=="Get-MgUser") | {Command,Uri,Method,ApiVersion,Variants}' "$META"

# Least-privilege permissions only
jq -c '[.[] | select(.Command=="Get-MgUser") | .Permissions[] |
        select(.IsLeastPrivilege)] | unique_by(.Name+.PermissionType) |
        map({Name,PermissionType,IsAdmin})' "$META"

# Endpoint -> which cmdlets call it
jq -c '[.[] | select(.Uri=="/users/{user-id}/memberOf") |
        {Command,Method,ApiVersion}]' "$META"

# Substring match on a URI you only half know — note the null guard
jq -c '[.[] | select((.Uri // "")|test("managedDevices";"i")) | .Command] | unique | .[0:20]' "$META"

# Cmdlet -> the REST reference page for the endpoint behind it
jq -r '.[] | select(.Command=="Get-MgUser") | .ApiReferenceLink' "$META" | sort -u

# Does a v1.0 equivalent exist for a beta cmdlet?
jq -r '[.[] | select(.Command|test("^Get-Mg(Beta)?UserAuthenticationMethod$")) |
        "\(.Command)\t\(.ApiVersion)"] | unique | .[]' "$META"

# Every cmdlet granted by one permission
jq -r '[.[] | select(.Permissions[]?.Name=="DeviceManagementManagedDevices.Read.All") |
        .Command] | unique | length' "$META"

# All cmdlets in one SDK module
jq -r '[.[] | select(.Module=="Users" and .ApiVersion=="v1.0") | .Command] | unique | .[]' "$META"
```

### MgLegacyCommandMapping.json

AzureAD / AzureADPreview / MSOnline → Microsoft Graph. Only ~27 KB — fetch it whole.

```
https://raw.githubusercontent.com/microsoftgraph/msgraph-sdk-powershell/main/src/Authentication/Authentication/custom/common/MgLegacyCommandMapping.json
```

```json
{ "Command": "Add-MgApplicationKey",
  "LegacyMapping": ["New-AzureADApplicationKeyCredential", "New-AzureADMSApplicationKey"] }
```

The mapping is stored **Mg → legacy**, so reverse it to answer the question users
actually ask:

```bash
curl -sL "$LEGACY_URL" |
  jq -r --arg old 'Get-AzureADUser' \
    '.[] | select(.LegacyMapping[]? | ascii_downcase == ($old|ascii_downcase)) | .Command'
```

### permissions.json (devx-content)

The canonical permission definitions behind Graph Explorer and the permissions reference.

```
https://raw.githubusercontent.com/microsoftgraph/microsoft-graph-devx-content/dev/permissions/new/permissions.json
```

~3 MB. Keyed object under `.permissions`, each entry carrying `schemes` (consent-facing
display text per permission type) and `pathSets` (the endpoints the permission unlocks).

```bash
# Consent text and admin requirement
jq -c '.permissions["User.Read.All"].schemes' perms.json

# Which endpoints does this permission actually cover?
jq -r '.permissions["User.Read.All"].pathSets[] |
       "\(.methods|join(","))\t\(.paths|keys|join(", "))"' perms.json

# Reverse: which permissions cover an endpoint?
jq -r '.permissions | to_entries[] |
       select(.value.pathSets[]?.paths | has("/users/{id}")) | .key' perms.json
```

Companion files in the same repo: `permissions/permissions-descriptions.json` (~650 KB,
localized variants available with a locale suffix) and
`permissions/new/provisioningInfo.json`.

### Sample queries

Graph Explorer's curated request corpus — useful for discovering the right endpoint shape
for a scenario.

```
https://raw.githubusercontent.com/microsoftgraph/microsoft-graph-devx-content/dev/sample-queries/sample-queries.json
```

~205 KB.

---

## Tier 1c — GitHub Contents API

Directory discovery only. Returns JSON listings that parse cleanly.

```
https://api.github.com/repos/{owner}/{repo}/contents/{path}
```

```bash
# All v1.0 module folders
gh api "repos/MicrosoftDocs/microsoftgraph-docs-powershell/contents/microsoftgraph/graph-powershell-1.0?per_page=100" \
  --jq '.[] | select(.type=="dir") | .name'

# Every cmdlet documented in one module
gh api "repos/MicrosoftDocs/microsoftgraph-docs-powershell/contents/microsoftgraph/graph-powershell-1.0/Microsoft.Graph.Users?per_page=100" \
  --jq '.[].name | rtrimstr(".md")'
```

`gh api` uses your token (5,000 requests/hour). Plain `curl` against `api.github.com` is
capped at 60/hour per IP. Large folders paginate at 100 entries — `Microsoft.Graph.Users`
alone holds 212 files.

Resolve the folder, then fetch the raw file. Never enumerate a folder when the exact
filename is already known.

---

## Tier 2 — Raw Markdown

**Repository**: `MicrosoftDocs/microsoftgraph-docs-powershell`
**Branch**: `main`

The source behind every `learn.microsoft.com/powershell/module/microsoft.graph.*` page.
Fetch markdown rather than the rendered page — a fraction of the payload, no navigation
chrome, and the syntax blocks and parameter tables survive verbatim.

**URL template**:

```
https://raw.githubusercontent.com/MicrosoftDocs/microsoftgraph-docs-powershell/main/microsoftgraph/{docset}/{Module}/{Cmdlet}.md
```

| Docset | Module prefix | Module count |
|--------|---------------|--------------|
| `graph-powershell-1.0` | `Microsoft.Graph.{Service}` | 39 |
| `graph-powershell-beta` | `Microsoft.Graph.Beta.{Service}` | 43 |

**Examples** (verified):

```
.../main/microsoftgraph/graph-powershell-1.0/Microsoft.Graph.Users/Get-MgUser.md
.../main/microsoftgraph/graph-powershell-beta/Microsoft.Graph.Beta.Users/Get-MgBetaUser.md
.../main/microsoftgraph/graph-powershell-1.0/Microsoft.Graph.Groups/New-MgGroup.md
```

### v1.0 Module Inventory

`Applications`, `Authentication`, `BackupRestore`, `Bookings`, `Calendar`,
`ChangeNotifications`, `CloudCommunications`, `Compliance`, `ConfigurationManagement`,
`CrossDeviceExperiences`, `DeviceManagement`, `DeviceManagement.Administration`,
`DeviceManagement.Enrollment`, `DeviceManagement.Functions`, `Devices.CloudPrint`,
`Devices.CorporateManagement`, `Devices.ServiceAnnouncement`, `DirectoryObjects`,
`Education`, `Files`, `Groups`, `Identity.DirectoryManagement`, `Identity.Governance`,
`Identity.Partner`, `Identity.SignIns`, `Mail`, `Notes`, `People`, `PersonalContacts`,
`Planner`, `Reports`, `SchemaExtensions`, `Search`, `Security`, `Sites`, `Teams`,
`Users`, `Users.Actions`, `Users.Functions`

Each prefixed with `Microsoft.Graph.` (v1.0) or `Microsoft.Graph.Beta.` (beta). The beta
docset adds service modules that have no v1.0 counterpart — `BusinessScenario` among them.

Prefer resolving the module from metadata (`.Module` in `MgCommandMetadata.json`, or
`Find-MgGraphCommand | Select-Object -Expand Module`) over guessing from this list. A
cmdlet's noun rarely names its module: `Get-MgUserMemberOf` lives in
`Microsoft.Graph.Users`, but `Get-MgUserManager` does too, while `Get-MgUserLicenseDetail`
sits in `Microsoft.Graph.Users.Functions`.

### Conceptual Documentation

Narrative guides live outside the docsets:

```
https://raw.githubusercontent.com/MicrosoftDocs/microsoftgraph-docs-powershell/main/microsoftgraph/docs-conceptual/{topic}.md
```

Available topics: `app-only`, `authentication-commands`, `azuread-msoline-cmdlet-map`,
`find-mg-graph-command`, `find-mg-graph-permission`, `get-started`,
`how-to-grant-revoke-api-permissions`, `how-to-assign-microsoft-entra-roles-in-pim`,
`how-to-manage-pim-policies`, `installation`, `migration-steps`, `navigating`,
`overview`, `troubleshooting`, `tutorial-entitlement-management`, `use-query-parameters`

---

## Graph API Metadata (reference only)

Complete API surface descriptions. **Too large for routine lookup** — 40+ MB each, YAML
rather than JSON. Use them only when the command map has no answer and you need the
underlying REST contract.

| Artifact | URL |
|----------|-----|
| CSDL (XML) | `https://graph.microsoft.com/v1.0/$metadata` |
| OpenAPI v1.0 | `https://raw.githubusercontent.com/microsoftgraph/msgraph-metadata/master/openapi/v1.0/openapi.yaml` |
| OpenAPI beta | `https://raw.githubusercontent.com/microsoftgraph/msgraph-metadata/master/openapi/beta/openapi.yaml` |

Variants under `openapi/v1.0/`: `default.yaml`, `graphexplorer.yaml`, `openapi.yaml`,
`powershell_v2.yaml` — the last being the input the PowerShell SDK generator consumes.

---

## Case Sensitivity

`raw.githubusercontent.com` paths are case-sensitive; `learn.microsoft.com` URLs are not.
A lowercased module folder resolves on Learn and 404s on raw:

| Result | URL fragment |
|--------|--------------|
| **404** | `.../graph-powershell-1.0/microsoft.graph.users/Get-MgUser.md` |
| **200** | `.../graph-powershell-1.0/Microsoft.Graph.Users/Get-MgUser.md` |

Preserve the module's own dotted PascalCase and the cmdlet's `Verb-Noun` casing exactly.

---

## URL Conversion

```
https://github.com/{owner}/{repo}/blob/{branch}/{path}
         ↓
https://raw.githubusercontent.com/{owner}/{repo}/{branch}/{path}
```

Drop `/blob/`, swap the host. Fetching a `github.com` URL directly returns the surrounding
HTML page, not the file.

---

## Troubleshooting a 404

| Check | Fix |
|-------|-----|
| URL ends in `/` | Raw serves blobs only — use the [contents API](#tier-1c--github-contents-api) |
| Module folder lowercased | Restore dotted PascalCase — see [Case Sensitivity](#case-sensitivity) |
| Missing `Beta` infix | Beta cmdlets are `Get-MgBetaUser`, in `Microsoft.Graph.Beta.Users` |
| Wrong module folder | Resolve `.Module` from metadata rather than guessing from the noun |
| Wrong branch | `main` for both the docs repo and `msgraph-sdk-powershell`; `dev` for `microsoft-graph-devx-content`; `master` for `msgraph-metadata` |
| `github.com` host | Convert to `raw.githubusercontent.com` |
| Cmdlet genuinely absent | Confirm in metadata before concluding — it may be beta-only, or renamed |

---

## Branch Reference

Each repository settled on a different default. Getting this wrong produces a 404 that
looks exactly like a missing file.

| Repository | Branch |
|------------|--------|
| `MicrosoftDocs/microsoftgraph-docs-powershell` | `main` |
| `microsoftgraph/msgraph-sdk-powershell` | `main` |
| `microsoftgraph/microsoft-graph-devx-content` | `dev` |
| `microsoftgraph/msgraph-metadata` | `master` |

---

## Rendered Documentation

Use only when no raw source exists, or a raw fetch has already failed. These render from
the repositories above, so they are never fresher and always cost more.

| Resource | URL |
|----------|-----|
| Graph PowerShell docs | https://learn.microsoft.com/en-us/powershell/microsoftgraph/ |
| Module browser | https://learn.microsoft.com/en-us/powershell/module/?term=Microsoft.Graph |
| Graph REST reference | https://learn.microsoft.com/en-us/graph/api/overview |
| Permissions reference | https://learn.microsoft.com/en-us/graph/permissions-reference |
| Graph Explorer | https://developer.microsoft.com/en-us/graph/graph-explorer |
| Changelog | https://developer.microsoft.com/en-us/graph/changelog |
