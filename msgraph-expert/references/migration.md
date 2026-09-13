# Migrating to Microsoft Graph PowerShell

Moving scripts off AzureAD, AzureADPreview, and MSOnline.

All three legacy modules are deprecated in favour of the Microsoft Graph PowerShell SDK.
Current retirement guidance lives in the official
[migration steps](https://raw.githubusercontent.com/MicrosoftDocs/microsoftgraph-docs-powershell/main/microsoftgraph/docs-conceptual/migration-steps.md)
— check it rather than quoting a date from memory, since it has moved more than once.

---

## Resolving a Replacement

The SDK ships the mapping as JSON. Resolve, do not guess.

```bash
scripts/graph-meta.sh legacy Get-AzureADUser     # -> Get-MgUser
scripts/graph-meta.sh legacy Set-AzureADUser     # -> Update-MgUser
```

```powershell
.\Find-GraphCommand.ps1 -LegacyCommand Get-MsolUser
```

**Coverage is partial.** `MgLegacyCommandMapping.json` maps 274 legacy cmdlets onto 183
Graph cmdlets — well short of the full AzureAD and MSOnline surface. A cmdlet absent from
the map is not necessarily unsupported; it more often means no single Graph cmdlet is
equivalent. When the lookup comes back empty, search by endpoint instead:

```bash
scripts/graph-meta.sh uri '/policies/authorizationPolicy'
```

---

## Verb Changes

The legacy modules did not follow approved-verb conventions consistently. The Graph SDK
does, so verbs shift even when the noun survives:

| Legacy | Graph | Note |
|--------|-------|------|
| `Set-AzureADUser` | `Update-MgUser` | `Set-` implies replacement; Graph does PATCH |
| `Connect-AzureAD` | `Connect-MgGraph` | Now requires explicit `-Scopes` |
| `Get-AzureADUserMembership` | `Get-MgUserMemberOf` | Noun follows the Graph relationship name |
| `Remove-AzureADUser` | `Remove-MgUser` | Unchanged |

`Set-Mg*` cmdlets do exist, and they are **not** synonyms for `Update-Mg*`: `Set-` targets
`$ref` relationship endpoints (replacing a link), while `Update-` issues a PATCH against
the object. Picking the wrong one produces a confusing `400`.

---

## Behavioural Differences That Break Scripts

### Paging is no longer implicit

`Get-AzureADUser` returned everything by default. `Get-MgUser` returns the first page.

```powershell
$users = Get-AzureADUser                      # every user
$users = Get-MgUser                           # first 100 — silent truncation
$users = Get-MgUser -All                      # every user
```

This is the single most common migration defect, and it fails quietly on small tenants
during testing before breaking in production.

### Properties must be requested

```powershell
Get-AzureADUser -ObjectId $id | Select-Object Department        # populated
Get-MgUser -UserId $id | Select-Object Department              # $null
Get-MgUser -UserId $id -Property Department | Select-Object Department  # populated
```

See [best-practices.md](best-practices.md#property-selection).

### Property names are camelCase in filters

Legacy filters used PascalCase; Graph OData uses the JSON property names.

```powershell
Get-AzureADUser -Filter "DisplayName eq 'Alice'"      # legacy
Get-MgUser -Filter "displayName eq 'Alice'"           # Graph
```

Returned .NET objects still expose PascalCase properties — only the `-Filter` string
changes. Mixing them up yields `Request_UnsupportedQuery`.

### Identifier parameters are renamed

| Legacy | Graph |
|--------|-------|
| `-ObjectId` | `-UserId`, `-GroupId`, `-ApplicationId`, … (resource-specific) |
| `-SearchString` | `-Filter` with `startsWith(...)` |
| `-All $true` | `-All` (a switch, not a boolean) |

`-All $true` is the subtle one: PowerShell binds `$true` as a positional argument to the
next parameter rather than erroring, so the call can succeed while doing something else
entirely.

### Permissions are now explicit

`Connect-AzureAD` granted whatever the admin's roles allowed. `Connect-MgGraph` requires
each scope up front, and a missing scope surfaces as `Authorization_RequestDenied` at
call time — not at connect time.

Enumerate the scopes a migrated script needs before running it:

```bash
for cmd in Get-MgUser Update-MgUser New-MgGroup; do
  echo "== $cmd"; scripts/graph-meta.sh permissions "$cmd"
done
```

---

## Migration Workflow

1. **Inventory** the legacy cmdlets in the script.

   ```powershell
   Select-String -Path .\*.ps1 -Pattern '\b(Get|Set|New|Remove|Add)-(AzureAD|Msol)\w+' -AllMatches |
       ForEach-Object { $_.Matches.Value } | Sort-Object -Unique
   ```

2. **Resolve** each one through the mapping; note the gaps.

   ```bash
   while read -r c; do printf '%-32s %s\n' "$c" "$(scripts/graph-meta.sh legacy "$c")"; done < legacy.txt
   ```

3. **Collect scopes** for the resulting Graph cmdlets, taking the least-privilege row that
   matches the auth flow the script will actually use.

4. **Rewrite**, applying the four behavioural changes above — `-All`, `-Property`,
   camelCase filters, renamed identifier parameters.

5. **Verify counts** against the legacy script's output before decommissioning it. Silent
   truncation from a missing `-All` will otherwise look like a successful run.

---

## Worked Example

```powershell
# Before
Connect-AzureAD
$users = Get-AzureADUser -All $true -Filter "AccountEnabled eq false"
foreach ($u in $users) {
    Set-AzureADUser -ObjectId $u.ObjectId -Department 'Archived'
}
```

```powershell
# After
#Requires -Modules Microsoft.Graph.Authentication, Microsoft.Graph.Users

Connect-MgGraph -Scopes 'User.ReadWrite.All' -NoWelcome

$users = Get-MgUser -All -Filter "accountEnabled eq false" `
                    -Property Id, UserPrincipalName, Department

foreach ($user in $users) {
    Update-MgUser -UserId $user.Id -Department 'Archived'
}
```

Five changes: switch `-All`, camelCase filter property, `-Property` for the fields the
loop touches, `-ObjectId` → `-UserId`, and `Set-` → `Update-`.

---

## When No Equivalent Exists

Some legacy functionality has no generated cmdlet. Confirm against metadata, then call the
endpoint directly:

```powershell
Invoke-MgGraphRequest -Method GET `
    -Uri 'https://graph.microsoft.com/v1.0/policies/authorizationPolicy' `
    -OutputType PSObject
```

A few MSOnline capabilities have no Graph endpoint at all — some legacy licensing and
partner-relationship operations among them. Verify against the
[Graph changelog](https://developer.microsoft.com/en-us/graph/changelog) before concluding
either way, and check `beta` as well as `v1.0`:

```bash
scripts/graph-meta.sh uri '/policies/' | jq -r '.[] | select(.ApiVersion=="beta") | .Command' | sort -u
```
