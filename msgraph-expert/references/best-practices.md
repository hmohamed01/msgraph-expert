# Microsoft Graph PowerShell Best Practices

Patterns for automation that survives large tenants, throttling, and unattended runs.

---

## Module Installation

Install per-service modules. The `Microsoft.Graph` meta-module pulls 40+ modules,
adds seconds to every session start, and is almost never what a script needs.

```powershell
Install-PSResource Microsoft.Graph.Authentication, Microsoft.Graph.Users,
                   Microsoft.Graph.Groups -Scope CurrentUser -TrustRepository
```

`Microsoft.Graph.Authentication` is a dependency of every other module — it carries
`Connect-MgGraph`, `Invoke-MgGraphRequest`, and the command metadata.

Beta cmdlets live in a **separate module family** with a `Beta` infix in both the module
name and the cmdlet noun:

| API version | Module | Cmdlet |
|-------------|--------|--------|
| v1.0 | `Microsoft.Graph.Users` | `Get-MgUser` |
| beta | `Microsoft.Graph.Beta.Users` | `Get-MgBetaUser` |

Both families can be loaded simultaneously — the names do not collide.

Declare dependencies so failures surface at load rather than mid-run:

```powershell
#Requires -Modules Microsoft.Graph.Authentication, Microsoft.Graph.Users
```

---

## Authentication

### Choosing a flow

| Scenario | Flow |
|----------|------|
| Interactive admin work | `Connect-MgGraph -Scopes ...` |
| Azure Automation, Azure VM, Function App | `Connect-MgGraph -Identity` |
| Unattended outside Azure | Certificate + app registration |
| CI/CD with federated credentials | Workload identity federation |
| Anything at all | **Never a client secret in source** |

```powershell
# Certificate — thumbprint resolves from CurrentUser\My or LocalMachine\My
Connect-MgGraph -ClientId $appId -TenantId $tenantId -CertificateThumbprint $thumbprint

# Managed identity, user-assigned
Connect-MgGraph -Identity -ClientId $userAssignedClientId

# Existing bearer token (e.g. issued by another component)
Connect-MgGraph -AccessToken ($token | ConvertTo-SecureString -AsPlainText -Force)
```

### Verify before assuming

Scopes are **additive across `Connect-MgGraph` calls** in an interactive session, so a
scope present during development may be absent in production.

```powershell
$requiredScopes = @('User.Read.All', 'Group.ReadWrite.All')
$context = Get-MgContext

if (-not $context) {
    Connect-MgGraph -Scopes $requiredScopes -NoWelcome
}
else {
    $missing = $requiredScopes | Where-Object { $_ -notin $context.Scopes }
    if ($missing) {
        throw "Session is missing required scopes: $($missing -join ', ')"
    }
}
```

App-only sessions report their granted application permissions in `$context.Scopes` too,
so the same check works for both flows.

Always pass `-NoWelcome` in scripts — the banner pollutes transcript logs.

### Disconnect

```powershell
try   { # ... work ... }
finally { Disconnect-MgGraph -ErrorAction SilentlyContinue }
```

Long-lived runbooks that skip this can leak a cached token into the next run under a
different identity.

---

## Retrieving Data

### Paging

`-All` follows `@odata.nextLink` internally. Hand-rolling the loop is a recurring source
of silent truncation.

```powershell
# Correct
$users = Get-MgUser -All

# Correct — tune the page, not the total
Get-MgUser -All -PageSize 999

# Wrong — returns 100 and stops, with no indication more exist
$users = Get-MgUser
```

| Parameter | Meaning |
|-----------|---------|
| `-All` | Follow every page until exhausted |
| `-PageSize` | Records per request (max 999 for most directory resources) |
| `-Top` | Maximum **total** records returned, not page size |

`-Top` and `-All` together are contradictory; `-Top` wins and `-All` is ignored.

### Property selection

Graph returns a default property set. Anything outside it comes back `$null` **with no
error** — the quietest failure mode in the SDK.

```powershell
# Department is silently $null: it is not in the default set
Get-MgUser -All | Select-Object DisplayName, Department

# Correct — request it server-side first
Get-MgUser -All -Property Id, DisplayName, Department |
    Select-Object DisplayName, Department
```

`-Property` maps to OData `$select`. It also cuts payload substantially on large
directories, so request the narrowest set that satisfies the script.

Some properties are never returned in a collection and require a per-object GET —
`signInActivity` on `Get-MgUser` among them.

### Filtering

Filter in the tenant, not in the pipeline. `Where-Object` transfers every record first.

```powershell
# Server-side
Get-MgUser -Filter "accountEnabled eq false" -All
Get-MgUser -Filter "startsWith(displayName,'Adm')" -All
Get-MgGroup -Filter "groupTypes/any(c:c eq 'Unified')" -All

# Client-side — transfers the whole directory to discard most of it
Get-MgUser -All | Where-Object { -not $_.AccountEnabled }
```

**Advanced queries** need `-ConsistencyLevel eventual` plus a count variable. Required for
`endsWith`, `not`, `ne`, `$count`, and `OR` across multi-valued properties:

```powershell
Get-MgUser -Filter "endsWith(mail,'@contoso.com')" `
           -ConsistencyLevel eventual -CountVariable total -All
```

Omitting `-ConsistencyLevel` on a query that needs it returns a `400` whose message does
not mention consistency — a common dead end.

### Expanding relationships

```powershell
Get-MgGroup -GroupId $id -ExpandProperty 'members($select=id,displayName)'
```

`$expand` is capped at 20 items per relationship and cannot be combined with `$filter` on
most resources. For anything larger, query the relationship directly:

```powershell
Get-MgGroupMember -GroupId $id -All
```

---

## Writing Data

Update cmdlets take a hashtable body parameter or discrete parameters depending on the
variant. Splat the body for readability:

```powershell
$body = @{
    displayName = 'Contoso Engineering'
    mailNickname = 'contoso-eng'
    mailEnabled = $false
    securityEnabled = $true
    groupTypes = @('Unified')
}

New-MgGroup -BodyParameter $body
```

Guard destructive operations:

```powershell
[CmdletBinding(SupportsShouldProcess)]
param([string]$UserId)

if ($PSCmdlet.ShouldProcess($UserId, 'Remove user')) {
    Remove-MgUser -UserId $UserId
}
```

---

## Throttling

Graph returns `429 Too Many Requests` with a `Retry-After` header. The SDK retries
automatically, but tight loops still exhaust the budget.

Prefer batching over looping:

```powershell
# 20 requests in one round-trip
$batch = @{
    requests = @(
        @{ id = '1'; method = 'GET'; url = '/users/alice@contoso.com' }
        @{ id = '2'; method = 'GET'; url = '/users/bob@contoso.com' }
    )
}
Invoke-MgGraphRequest -Method POST -Uri 'v1.0/$batch' -Body $batch
```

`$batch` accepts at most 20 sub-requests, and each is throttled on its own resource
budget — batching reduces round-trips, not the underlying limits.

When a loop is unavoidable, honour `Retry-After` explicitly:

```powershell
catch {
    if ($_.Exception.Response.StatusCode -eq 429) {
        $wait = [int]($_.Exception.Response.Headers.RetryAfter.Delta.TotalSeconds ?? 10)
        Write-Warning "Throttled; sleeping $wait s"
        Start-Sleep -Seconds $wait
    }
}
```

---

## Error Handling

Graph errors carry a structured body. Parse the code rather than matching on message text,
which is localized and unstable.

```powershell
try {
    Get-MgUser -UserId $upn -ErrorAction Stop
}
catch {
    $detail = $_.ErrorDetails.Message | ConvertFrom-Json -ErrorAction SilentlyContinue

    switch ($detail.error.code) {
        'Request_ResourceNotFound'    { Write-Warning "No such user: $upn"; return }
        'Authorization_RequestDenied' {
            throw "Insufficient permissions. Session holds: $((Get-MgContext).Scopes -join ', ')"
        }
        'Request_BadRequest'          { throw "Malformed request: $($detail.error.message)" }
        default                       { throw }
    }
}
```

| Code | Cause |
|------|-------|
| `Authorization_RequestDenied` | Missing scope, or admin consent not granted |
| `Request_ResourceNotFound` | Object absent, or the caller cannot see it |
| `Request_BadRequest` | Malformed filter, or `$select` on an unknown property |
| `Directory_QuotaExceeded` | Tenant object limit reached |
| `Request_UnsupportedQuery` | Advanced query without `-ConsistencyLevel eventual` |

---

## Escape Hatch: Invoke-MgGraphRequest

Not every endpoint has a generated cmdlet, and beta endpoints often land before the SDK
catches up. `Invoke-MgGraphRequest` reuses the authenticated session:

```powershell
Invoke-MgGraphRequest -Method GET `
    -Uri 'https://graph.microsoft.com/beta/identityGovernance/lifecycleWorkflows/workflows' `
    -OutputType PSObject
```

`-OutputType` accepts `PSObject`, `Hashtable`, `HttpResponseMessage`, or `Json`. The
default is `Hashtable`, which surprises scripts expecting dotted property access.

This bypasses cmdlet-level parameter validation entirely — verify the endpoint against
metadata first.

---

## Output and Logging

```powershell
# Structured, greppable
[PSCustomObject]@{
    Timestamp = [datetime]::UtcNow
    UserPrincipalName = $user.UserPrincipalName
    Action = 'Disabled'
    Result = 'Success'
}
```

Never `Write-Host` results a caller might want to pipe. Reserve it for the progress
narration that must not enter the pipeline.

---

## Performance Checklist

| Practice | Effect |
|----------|--------|
| `-Property` with the minimum set | Cuts payload, avoids `$null` surprises |
| `-Filter` over `Where-Object` | Filters in the tenant |
| `-All` with `-PageSize 999` | Fewest round-trips |
| `$batch` for many small reads | 20 requests per round-trip |
| Per-service modules only | Faster session start |
| Reuse one `Connect-MgGraph` session | Avoids repeated token acquisition |
