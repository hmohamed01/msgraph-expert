<#
.SYNOPSIS
    Resolve Microsoft Graph cmdlet, endpoint, and permission facts from SDK metadata.

.DESCRIPTION
    Queries the Graph PowerShell SDK command map, preferring the copy shipped with an
    installed Microsoft.Graph.Authentication module and falling back to the published
    JSON on GitHub when the module is absent.

    Unlike Find-MgGraphCommand, this runs without the SDK installed and returns a
    flattened projection suitable for piping to ConvertTo-Json or Format-Table.

.PARAMETER Command
    Cmdlet name to resolve. Supports wildcards.

.PARAMETER Uri
    Graph endpoint path to resolve. Matched as a case-insensitive substring, so
    '/users' matches every endpoint beneath it.

.PARAMETER Permission
    Permission name. Returns every cmdlet the permission unlocks.

.PARAMETER LegacyCommand
    AzureAD, AzureADPreview, or MSOnline cmdlet name. Returns its Graph equivalents.

.PARAMETER ApiVersion
    Restrict results to 'v1.0' or 'beta'. Omit to return both.

.PARAMETER LeastPrivilege
    With -Command, return only the least-privilege permissions for that cmdlet.

.PARAMETER Refresh
    Download the metadata cache from GitHub. Required the first time on a machine with
    no installed SDK, and the only way this script ever reaches the network: without it,
    a missing cache is an error rather than a silent 21 MB download.

.EXAMPLE
    .\Find-GraphCommand.ps1 -Command Get-MgUser
    Endpoint, method, API version, and output type for a cmdlet.

.EXAMPLE
    .\Find-GraphCommand.ps1 -Command New-MgGroup -LeastPrivilege
    The minimum permissions that satisfy the cmdlet, per permission type.

.EXAMPLE
    .\Find-GraphCommand.ps1 -Uri '/deviceManagement/managedDevices' -ApiVersion v1.0
    Every v1.0 cmdlet that touches Intune managed devices.

.EXAMPLE
    .\Find-GraphCommand.ps1 -LegacyCommand Get-AzureADUser
    The Graph replacement for a retired AzureAD cmdlet.
#>

[CmdletBinding(DefaultParameterSetName = 'ByCommand')]
param(
    [Parameter(ParameterSetName = 'ByCommand', Mandatory, Position = 0)]
    [ValidateNotNullOrEmpty()]
    [string]$Command,

    [Parameter(ParameterSetName = 'ByUri', Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$Uri,

    [Parameter(ParameterSetName = 'ByPermission', Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$Permission,

    [Parameter(ParameterSetName = 'ByLegacy', Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$LegacyCommand,

    [Parameter(ParameterSetName = 'ByCommand')]
    [Parameter(ParameterSetName = 'ByUri')]
    [Parameter(ParameterSetName = 'ByPermission')]
    [ValidateSet('v1.0', 'beta')]
    [string]$ApiVersion,

    [Parameter(ParameterSetName = 'ByCommand')]
    [switch]$LeastPrivilege,

    [switch]$Refresh
)

$ErrorActionPreference = 'Stop'

$cacheDir = if ($env:MSGRAPH_CACHE_DIR) {
    $env:MSGRAPH_CACHE_DIR
} else {
    Join-Path ([Environment]::GetFolderPath('UserProfile')) '.cache/msgraph-expert'
}

$sdkRaw = 'https://raw.githubusercontent.com/microsoftgraph/msgraph-sdk-powershell/main/src/Authentication/Authentication/custom/common'

function Resolve-MetadataFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$FileName,

        [switch]$ForceRefresh
    )

    $cached = Join-Path $cacheDir $FileName

    # -Refresh means "take the copy published on GitHub", so it bypasses both local
    # sources deliberately. It is also the only path here that touches the network.
    if ($ForceRefresh) {
        if (-not (Test-Path $cacheDir)) {
            New-Item -Path $cacheDir -ItemType Directory -Force | Out-Null
        }

        Write-Verbose "Downloading $FileName"
        $downloadParams = @{
            Uri             = "$sdkRaw/$FileName"
            OutFile         = $cached
            UseBasicParsing = $true
        }
        Invoke-WebRequest @downloadParams

        return $cached
    }

    # The installed SDK ships the same file; use it and skip the 21 MB download.
    $installed = Get-Module Microsoft.Graph.Authentication -ListAvailable |
        Sort-Object Version -Descending |
        Select-Object -First 1

    if ($installed) {
        $shipped = Join-Path $installed.ModuleBase "custom/common/$FileName"
        if (Test-Path $shipped) {
            Write-Verbose "Using metadata from installed SDK $($installed.Version)"
            return $shipped
        }
    }

    if (Test-Path $cached) {
        Write-Verbose "Using cached metadata: $cached"
        return $cached
    }

    # Explicit refresh only: never reach the network unless asked.
    throw "$FileName is not cached, and no installed SDK was found to copy it from. " +
          "Re-run with -Refresh to download it (~21 MB from GitHub)."
}

function Get-CommandMap {
    $path = Resolve-MetadataFile -FileName 'MgCommandMetadata.json' -ForceRefresh:$Refresh
    Get-Content -Path $path -Raw | ConvertFrom-Json
}

switch ($PSCmdlet.ParameterSetName) {
    'ByLegacy' {
        $path = Resolve-MetadataFile -FileName 'MgLegacyCommandMapping.json' -ForceRefresh:$Refresh
        $mapping = Get-Content -Path $path -Raw | ConvertFrom-Json

        $matched = $mapping | Where-Object {
            $_.LegacyMapping -contains $LegacyCommand
        }

        if (-not $matched) {
            Write-Warning "No Graph equivalent mapped for '$LegacyCommand'."
            Write-Host "Search the full mapping with: -LegacyCommand '<exact cmdlet name>'" -ForegroundColor DarkGray
            return
        }

        $matched | ForEach-Object {
            [PSCustomObject]@{
                LegacyCommand = $LegacyCommand
                GraphCommand  = $_.Command
                AllLegacy     = $_.LegacyMapping -join ', '
            }
        }
        return
    }

    'ByPermission' {
        $metadata = Get-CommandMap

        $matched = $metadata | Where-Object {
            $_.Permissions.Name -contains $Permission -and
            (-not $ApiVersion -or $_.ApiVersion -eq $ApiVersion)
        }

        if (-not $matched) {
            Write-Warning "No cmdlets found for permission '$Permission'."
            return
        }

        $matched |
            Select-Object -ExpandProperty Command -Unique |
            Sort-Object
        return
    }

    'ByUri' {
        $metadata = Get-CommandMap

        # Uri is null on the handful of auth cmdlets bound to no endpoint.
        $matched = $metadata | Where-Object {
            $_.Uri -and
            $_.Uri -like "*$Uri*" -and
            (-not $ApiVersion -or $_.ApiVersion -eq $ApiVersion)
        }

        if (-not $matched) {
            Write-Warning "No cmdlets found for URI containing '$Uri'."
            return
        }

        $matched |
            Select-Object Command, Uri, Method, ApiVersion, Module -Unique |
            Sort-Object Command
        return
    }

    'ByCommand' {
        $metadata = Get-CommandMap

        $matched = $metadata | Where-Object {
            $_.Command -like $Command -and
            (-not $ApiVersion -or $_.ApiVersion -eq $ApiVersion)
        }

        if (-not $matched) {
            Write-Warning "Cmdlet '$Command' not found in the SDK command map."
            Write-Host "Check spelling, or try a wildcard: -Command '$Command*'" -ForegroundColor DarkGray
            return
        }

        if ($LeastPrivilege) {
            $matched.Permissions |
                Where-Object IsLeastPrivilege |
                Select-Object Name, PermissionType, IsAdmin -Unique |
                Sort-Object PermissionType, Name
            return
        }

        $matched |
            Select-Object Command, Uri, Method, ApiVersion, Module, OutputType,
                          @{ Name = 'Variants'; Expression = { $_.Variants -join ', ' } },
                          ApiReferenceLink -Unique |
            Sort-Object Command, ApiVersion
        return
    }
}
