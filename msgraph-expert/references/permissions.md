# Microsoft Graph Permissions

Resolving the minimum permission a script actually needs, and granting it correctly.

---

## The Two Models

| | Delegated | Application |
|---|---|---|
| Acts as | Signed-in user | The app itself |
| Effective access | Intersection of app permission **and** user's own rights | Exactly the permission, tenant-wide |
| Requested via | `Connect-MgGraph -Scopes` | Pre-granted on the app registration |
| Consent | User or admin, depending on permission | Always admin |
| Suits | Interactive tooling, self-service | Unattended automation |

The intersection rule is the one most often missed: a delegated `User.ReadWrite.All` does
**not** let a non-admin edit other users. The app is permitted to; the signed-in user is
not; the request fails with `Authorization_RequestDenied`. Reproducing a delegated
permission bug therefore requires the same *user*, not just the same app.

`DelegatedPersonal` is a third type in the metadata — delegated permissions valid for
personal Microsoft accounts rather than work or school accounts.

---

## Finding the Least-Privilege Permission

The SDK command map records, per cmdlet and per permission type, which permissions are
least-privilege. **Resolve it; do not recall it.**

```powershell
# Installed SDK
(Find-MgGraphCommand -Command Get-MgUser).Permissions |
    Where-Object IsLeastPrivilege |
    Select-Object Name, PermissionType, IsAdmin -Unique
```

```bash
# No SDK required
scripts/graph-meta.sh permissions Get-MgUser
```

Least privilege is **per permission type**, not per cmdlet. `New-MgGroup` needs
`Group.Create` under application auth but `Group.ReadWrite.All` under delegated — reading
one row and applying it to both flows over-privileges the app registration.

Working backwards is equally cheap:

```bash
# Everything one permission unlocks — review before granting it
scripts/graph-meta.sh perm 'DeviceManagementManagedDevices.ReadWrite.All'
```

Run that before granting any `.All` permission. The count is frequently an argument for
a narrower one.

---

## Permission Naming

```
{Resource}.{Operation}.{Scope}
```

| Segment | Values |
|---------|--------|
| Operation | `Read`, `ReadWrite`, `Create`, `Manage`, `Send`, `Selected` |
| Scope | *(none)* = own object, `.All` = tenant-wide, `.OwnedBy` = app-owned objects only |

Narrow alternatives worth reaching for before the `.All` variant:

| Instead of | Consider | Grants |
|------------|----------|--------|
| `User.Read.All` | `User.ReadBasic.All` | Name, mail, photo — no job, manager, or directory detail |
| `Application.ReadWrite.All` | `Application.ReadWrite.OwnedBy` | Only apps this app created |
| `Group.ReadWrite.All` | `Group.Create` | Creating groups without editing existing ones |
| `Sites.ReadWrite.All` | `Sites.Selected` | Only sites explicitly assigned to the app |
| `Mail.ReadWrite` | `Mail.Send` | Sending without reading the mailbox |

`Sites.Selected` and application access policies for Exchange are the two mechanisms that
turn tenant-wide application permissions into per-resource ones. For any mailbox or site
automation touching a subset of the tenant, they are the correct answer rather than a
broad `.All`.

---

## Granting Permissions

### Delegated, interactively

```powershell
Connect-MgGraph -Scopes 'User.Read.All', 'Group.ReadWrite.All'
```

Scopes accumulate across calls within a session; the consent prompt appears only for
scopes not yet granted. Clear the cache to force a re-prompt:

```powershell
Disconnect-MgGraph
Connect-MgGraph -Scopes 'User.Read.All' -ContextScope Process
```

### Application, on an app registration

```powershell
Connect-MgGraph -Scopes 'Application.ReadWrite.All', 'AppRoleAssignment.ReadWrite.All'

$graphSp = Get-MgServicePrincipal -Filter "appId eq '00000003-0000-0000-c000-000000000000'"
$targetSp = Get-MgServicePrincipal -Filter "appId eq '$myAppId'"

$appRole = $graphSp.AppRoles | Where-Object {
    $_.Value -eq 'User.ReadBasic.All' -and $_.AllowedMemberTypes -contains 'Application'
}

$assignment = @{
    PrincipalId = $targetSp.Id
    ResourceId  = $graphSp.Id
    AppRoleId   = $appRole.Id
}
New-MgServicePrincipalAppRoleAssignedTo -ServicePrincipalId $targetSp.Id @assignment
```

`00000003-0000-0000-c000-000000000000` is the fixed application ID of Microsoft Graph in
every tenant.

Granting an app role assignment **is** admin consent for that permission — no separate
consent step follows.

### Auditing what is granted

```powershell
# Application permissions on a service principal
Get-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $sp.Id |
    ForEach-Object {
        $role = $graphSp.AppRoles | Where-Object Id -eq $_.AppRoleId
        [PSCustomObject]@{ Permission = $role.Value; Granted = $_.CreatedDateTime }
    }

# Delegated grants
Get-MgOauth2PermissionGrant -Filter "clientId eq '$($sp.Id)'" |
    Select-Object ConsentType, PrincipalId, Scope
```

`ConsentType` of `AllPrincipals` is tenant-wide admin consent; `Principal` is a single
user's consent.

---

## Permission Metadata Sources

| Need | Source |
|------|--------|
| Least privilege for a cmdlet | `MgCommandMetadata.json` → `Permissions[].IsLeastPrivilege` |
| Permission id and consent type | `Find-MgGraphPermission` |
| Consent-screen display text | `permissions.json` → `.schemes` |
| Endpoints a permission covers | `permissions.json` → `.pathSets` |
| Cmdlets a permission unlocks | `MgCommandMetadata.json` |

```powershell
Find-MgGraphPermission -SearchString 'User.Read.All' -PermissionType Application
# -> Id, PermissionType, Consent, Name, Description
```

URL templates and `jq` recipes are in [data-sources.md](data-sources.md).

---

## Troubleshooting

| Symptom | Cause |
|---------|-------|
| `Authorization_RequestDenied` on a permission you granted | Application permission granted but the session is delegated, or vice versa |
| Delegated call fails for one user, works for another | Effective access is the intersection — the user lacks the right |
| Permission granted but still denied | Admin consent pending, or the token predates the grant — reconnect |
| Works in Graph Explorer, fails in a script | Explorer uses its own app registration and consents on the fly |
| `Insufficient privileges to complete the operation` | A directory **role** is needed on top of the Graph permission |

Graph permissions and Entra directory roles are separate systems. Some operations —
privileged role assignment, certain conditional access writes — require the caller to
hold a directory role regardless of which Graph permission is present.

Confirm what the live session actually holds before debugging further:

```powershell
Get-MgContext | Select-Object Account, AppName, AuthType, Scopes
```
