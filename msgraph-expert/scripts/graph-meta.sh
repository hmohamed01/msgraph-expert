#!/usr/bin/env bash
#
# graph-meta.sh — query the Microsoft Graph PowerShell SDK command map from JSON.
#
# Resolves cmdlet -> URI -> permission -> API version facts without loading PowerShell
# and without pulling megabytes of metadata into an agent's context. Every subcommand
# filters with jq and prints only the matched records.
#
# CACHE POLICY: explicit refresh only. No query subcommand ever downloads. `sync` is
# the only subcommand that touches the network, and only when you run it.
#
# Usage:
#   graph-meta.sh sync [--force] [--remote]   Populate or refresh the cache (only
#                                             subcommand that downloads)
#   graph-meta.sh command <Cmdlet>            Endpoint facts for a cmdlet
#   graph-meta.sh permissions <Cmdlet>        Permissions, least-privilege first
#   graph-meta.sh uri <GraphUri>              Cmdlets that call an endpoint (substring)
#   graph-meta.sh module <Module> [ver]       Cmdlets in an SDK module (e.g. Users)
#   graph-meta.sh legacy <OldCmdlet>          AzureAD/MSOnline cmdlet -> Mg equivalent
#   graph-meta.sh perm <Permission>           Cmdlets a permission unlocks
#   graph-meta.sh status                      Cache location, age, and size
#
# sync flags:
#   (none)      Populate anything missing; leave existing files untouched
#   --force     Re-resolve even if already cached
#   --remote    Ignore the installed SDK and take the copy published on GitHub
#
# Examples:
#   graph-meta.sh sync
#   graph-meta.sh command Get-MgUser
#   graph-meta.sh permissions New-MgGroup
#   graph-meta.sh uri '/deviceManagement/managedDevices'
#   graph-meta.sh legacy Get-AzureADUser
#
# Environment:
#   MSGRAPH_CACHE_DIR   Override the cache directory

set -euo pipefail

CACHE_DIR="${MSGRAPH_CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/msgraph-expert}"
META="$CACHE_DIR/MgCommandMetadata.json"
LEGACY="$CACHE_DIR/MgLegacyCommandMapping.json"

SDK_RAW="https://raw.githubusercontent.com/microsoftgraph/msgraph-sdk-powershell/main/src/Authentication/Authentication/custom/common"

die() { printf 'error: %s\n' "$*" >&2; exit 1; }

command -v jq >/dev/null || die "jq is required (brew install jq)"

# ---------------------------------------------------------------------------
# Cache policy: explicit refresh only.
#
# Nothing here fetches over the network unless the user runs `sync`. Query
# subcommands read whatever is already cached and fail with instructions when
# it is absent, rather than deciding on the user's behalf to pull 21 MB. A
# cache months old is answered from as-is; `status` reports its age so the
# staleness is visible, and refreshing it stays a deliberate act.
#
# Bootstrapping from an installed Microsoft.Graph.Authentication module is
# exempt: copying a file already on disk is not a network action and carries
# none of the risk this policy guards against.
# ---------------------------------------------------------------------------

cache_age_days() {
    local file="$1" mtime now
    [[ -s "$file" ]] || { printf -- '-'; return; }
    mtime=$(stat -f %m "$file" 2>/dev/null || stat -c %Y "$file" 2>/dev/null) ||
        { printf '?'; return; }
    now=$(date +%s)
    printf '%d' $(( (now - mtime) / 86400 ))
}

# Prefer the copy the installed SDK already ships over a download.
copy_from_installed_module() {
    local target="$1" filename="$2"
    command -v pwsh >/dev/null || return 1

    local module_base
    module_base=$(pwsh -NoProfile -NonInteractive -c '
        (Get-Module Microsoft.Graph.Authentication -ListAvailable |
            Sort-Object Version -Descending |
            Select-Object -First 1).ModuleBase' 2>/dev/null | tr -d '\r')

    [[ -n "$module_base" && -f "$module_base/custom/common/$filename" ]] || return 1

    cp "$module_base/custom/common/$filename" "$target"
    printf 'cached %s from installed SDK (%s)\n' "$filename" "$module_base" >&2
}

download() {
    local target="$1" filename="$2"

    printf 'downloading %s ...\n' "$filename" >&2
    curl -fsSL "$SDK_RAW/$filename" -o "$target.tmp" ||
        die "download failed: $SDK_RAW/$filename"

    jq -e 'type == "array"' "$target.tmp" >/dev/null ||
        { rm -f "$target.tmp"; die "$filename is not a JSON array - refusing to cache"; }

    mv "$target.tmp" "$target"
}

# Read-only guard for query subcommands. Never downloads.
require_cache() {
    local target="$1" filename="$2"

    [[ -s "$target" ]] && return 0

    mkdir -p "$CACHE_DIR"
    copy_from_installed_module "$target" "$filename" && return 0

    die "$filename is not cached, and no installed SDK was found to copy it from.
  Run '$(basename "$0") sync' to download it (~21 MB from GitHub).
  Queries never download on their own."
}

require_meta()   { require_cache "$META"   MgCommandMetadata.json; }
require_legacy() { require_cache "$LEGACY" MgLegacyCommandMapping.json; }

# ---------------------------------------------------------------------------
# Subcommands
# ---------------------------------------------------------------------------

cmd_sync() {
    local force="" remote=""
    while (( $# )); do
        case "$1" in
            --force)  force=1 ;;
            --remote) remote=1 ;;
            *)        die "unknown sync flag: $1" ;;
        esac
        shift
    done

    mkdir -p "$CACHE_DIR"

    local pair target filename
    for pair in "$META:MgCommandMetadata.json" "$LEGACY:MgLegacyCommandMapping.json"; do
        target="${pair%%:*}"
        filename="${pair##*:}"

        if [[ -s "$target" && -z "$force" ]]; then
            printf '%s already cached (%s days old) - use --force to refresh\n' \
                "$filename" "$(cache_age_days "$target")" >&2
            continue
        fi

        if [[ -n "$remote" ]]; then
            download "$target" "$filename"
        else
            copy_from_installed_module "$target" "$filename" ||
                download "$target" "$filename"
        fi
    done

    cmd_status
}

cmd_status() {
    printf 'cache:  %s\n' "$CACHE_DIR"
    printf 'policy: explicit refresh only (run "sync --force" to update)\n'

    local f
    for f in "$META" "$LEGACY"; do
        if [[ -s "$f" ]]; then
            printf '  %-32s %6s  %s days old\n' "$(basename "$f")" \
                "$(du -h "$f" | cut -f1)" "$(cache_age_days "$f")"
        else
            printf '  %-32s %6s\n' "$(basename "$f")" "absent"
        fi
    done
}

cmd_command() {
    local name="${1:?cmdlet name required}"
    require_meta
    jq -c --arg c "$name" '
        [ .[] | select(.Command | ascii_downcase == ($c | ascii_downcase))
              | {Command, Uri, Method, ApiVersion, Module, OutputType, Variants, ApiReferenceLink} ]
        | unique' "$META"
}

cmd_permissions() {
    local name="${1:?cmdlet name required}"
    require_meta
    jq -c --arg c "$name" '
        [ .[] | select(.Command | ascii_downcase == ($c | ascii_downcase))
              | .Permissions[]? ]
        | unique_by(.Name + .PermissionType)
        | sort_by(.IsLeastPrivilege | not)
        | map({Name, PermissionType, IsAdmin, IsLeastPrivilege})' "$META"
}

cmd_uri() {
    local path="${1:?graph uri required}"
    require_meta
    jq -c --arg u "$path" '
        [ .[] | select((.Uri // "") | ascii_downcase | contains($u | ascii_downcase))
              | {Command, Uri, Method, ApiVersion} ]
        | unique' "$META"
}

cmd_module() {
    local module="${1:?module name required}"
    local version="${2:-v1.0}"
    require_meta
    jq -r --arg m "$module" --arg v "$version" '
        [ .[] | select((.Module // "") | ascii_downcase == ($m | ascii_downcase))
              | select(.ApiVersion == $v)
              | .Command ]
        | unique | .[]' "$META"
}

cmd_legacy() {
    local old="${1:?legacy cmdlet name required}"
    require_legacy
    jq -r --arg o "$old" '
        .[] | select(.LegacyMapping[]? | ascii_downcase == ($o | ascii_downcase))
            | .Command' "$LEGACY" | sort -u
}

cmd_perm() {
    local permission="${1:?permission name required}"
    require_meta
    jq -r --arg p "$permission" '
        [ .[] | select(.Permissions[]?.Name | ascii_downcase == ($p | ascii_downcase))
              | .Command ]
        | unique | .[]' "$META"
}

case "${1:-}" in
    sync)        shift; cmd_sync "$@" ;;
    status)      shift; cmd_status ;;
    command)     shift; cmd_command "$@" ;;
    permissions) shift; cmd_permissions "$@" ;;
    uri)         shift; cmd_uri "$@" ;;
    module)      shift; cmd_module "$@" ;;
    legacy)      shift; cmd_legacy "$@" ;;
    perm)        shift; cmd_perm "$@" ;;
    ""|-h|--help)
        sed -n '3,36p' "$0" | sed 's/^# \{0,1\}//'
        ;;
    *) die "unknown subcommand: $1 (try --help)" ;;
esac
