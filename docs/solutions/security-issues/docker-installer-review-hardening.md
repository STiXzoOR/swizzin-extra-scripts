---
title: "Security and correctness fixes for Docker-based Swizzin installer scripts"
date: 2026-03-07
category: security-issues
severity: high
problem_type: "Input validation bypass, unsafe shell patterns, and dead code in Docker installer scripts"
symptoms:
  - "Regex injection in debrid provider validation allows bypass of allowed-provider check"
  - "YAML injection via unsanitized API keys into docker-compose.yml files"
  - "Hard failure when optional prowlarr-utils library is missing during stremthru install"
  - "Scripts crash under set -u due to unguarded positional parameters"
  - "Debrid credentials collected but never injected into mediafusion compose environment"
  - "Systemd resource limits on Type=oneshot service have no effect"
  - "Docker-compose files containing credentials created with world-readable permissions"
  - "Ineffective shred -u on journaling/CoW/SSD filesystems gives false sense of secure deletion"
tags:
  - docker
  - input-validation
  - regex-injection
  - yaml-injection
  - bash
  - set-u
  - debrid
  - swizzin
  - installer
  - security-hardening
  - dead-code
  - file-permissions
  - systemd
affected_files:
  - lib/debrid-utils.sh
  - lib/prowlarr-utils.sh
  - zilean.sh
  - stremthru.sh
  - mediafusion.sh
  - nzbdav.sh
---

# Security and Correctness Fixes for Docker Installer Scripts

## Root Cause Analysis

These 8 issues existed because four Docker installer scripts (zilean, stremthru, mediafusion, nzbdav) plus two shared libraries (debrid-utils, prowlarr-utils) were written as a batch using a shared template. During initial development:

1. **Security patterns were not established yet** -- debrid provider validation used regex matching (`=~`) rather than exact string comparison, and API key character validation was missing entirely.
2. **Optional library sourcing was inconsistent** -- prowlarr-utils was sourced without `|| true`, causing `set -e` scripts to abort if the library was absent.
3. **Credential cleanup habits carried over** -- `shred -u` was used in removal sections, which is inappropriate on modern filesystems where it provides false security assurance.
4. **`set -u` safety for positional parameters** was not uniformly applied.
5. **File permission hardening** for compose files containing credentials was added late in review rather than being part of the initial template.
6. **MediaFusion's debrid prompt** collected credentials that the app manages via its own web UI, not at install time -- an architectural misunderstanding.
7. **Systemd resource limits** were placed on Type=oneshot wrappers where they have no effect.

## Solutions Applied

### P1 -- Security

#### 1. Debrid provider validation: exact match instead of regex

**What**: `_validate_debrid_provider()` used `=~` regex match with unquoted user input.
**Why**: Regex metacharacters could bypass validation (e.g., `realdebrid.*` matching unintentionally).
**How**:

```bash
_validate_debrid_provider() {
    local provider="$1"
    local p
    for p in $_VALID_DEBRID_PROVIDERS; do
        [[ "$p" == "$provider" ]] && return 0
    done
    return 1
}
```

File: `lib/debrid-utils.sh:10-17`

#### 2. API key character validation prevents YAML injection

**What**: No character validation on debrid API keys before interpolation into compose YAML.
**Why**: YAML special characters (`:`, `{`, `}`, `#`, newlines) could inject arbitrary content.
**How**:

```bash
if [[ ! "$debrid_key" =~ ^[A-Za-z0-9_-]+$ ]]; then
    echo_error "API key contains invalid characters (only A-Z, a-z, 0-9, _, - allowed)"
    exit 1
fi
```

File: `lib/debrid-utils.sh:77-80`

#### 3. chmod 600 on compose files containing credentials

**What**: Compose files with database passwords, API keys, and debrid credentials were world-readable.
**Why**: Default umask (022) creates files readable by all local users.
**How** (applied in all 4 installers):

```bash
chmod 600 "${app_dir}/docker-compose.yml"
chown root:root "${app_dir}/docker-compose.yml"
```

Files: `stremthru.sh`, `zilean.sh`, `mediafusion.sh`, `nzbdav.sh`

### P2 -- Correctness

#### 4. Optional library sourcing with fallback

**What**: `source lib/prowlarr-utils.sh` without `|| true` aborts script if file is missing.
**Why**: Prowlarr integration is optional -- the library may not ship with every deployment.
**How**:

```bash
. "$(dirname "${BASH_SOURCE[0]}")/lib/prowlarr-utils.sh" 2>/dev/null || true
```

Plus `command -v` guards around all function calls from the library:

```bash
if command -v _discover_prowlarr >/dev/null 2>&1 && _discover_prowlarr; then
    _add_prowlarr_torznab "StremThru" "$torznab_url" "$api_key" || true
fi
```

Files: `stremthru.sh`, `zilean.sh`, `mediafusion.sh`

#### 5. Positional parameter defaults for set -u

**What**: `local force="$1"` crashes under `set -u` when no argument is passed.
**How**:

```bash
_remove_zilean() {
    local force="${1:-}"
    ...
}
```

Also in entry-point case statements: `case "${1:-}" in`

Files: `zilean.sh`, `stremthru.sh`, `mediafusion.sh`, `nzbdav.sh`

#### 6. Removed ineffective shred -u

**What**: `shred -u` provides no guarantees on ext4 (journaling), btrfs/ZFS (CoW), or SSDs (TRIM).
**How**: Replaced with plain `rm -rf` during purge.

File: `stremthru.sh`

#### 7. Removed unused debrid prompt from MediaFusion

**What**: Collected debrid credentials via `_prompt_debrid_provider()` but only wrote a YAML comment.
**Why**: MediaFusion manages debrid configuration through its web UI after installation.
**How**: Removed the entire debrid prompt/comment block from the install function.

File: `mediafusion.sh`

#### 8. Removed ineffective systemd resource limits

**What**: `MemoryMax`, `CPUQuota`, `TasksMax` on a `Type=oneshot` service have no effect.
**Why**: Oneshot services exit immediately; `RemainAfterExit=yes` only keeps the unit active, not a process.
**How**: Removed the resource limit directives. Docker Compose `deploy.resources.limits` handles container-level constraints.

File: `mediafusion.sh`

## Prevention Checklist

Use this when writing or reviewing new installer scripts:

- [ ] Every `=~` test uses a literal pattern, never an unquoted user-supplied variable on the RHS
- [ ] User input written into YAML/conf files is validated against `^[A-Za-z0-9_-]+$` first
- [ ] Optional library sources use `|| true` or `[[ -f "$path" ]] && source "$path"`
- [ ] Functions from optional libraries are guarded with `command -v func >/dev/null 2>&1`
- [ ] All positional parameters use `${1:-}` / `${2:-}` form
- [ ] No `shred -u` in removal paths (rely on `rm` + full-disk encryption)
- [ ] Every `read -rp` prompt has its variable referenced downstream (no dead input)
- [ ] No resource limits on `Type=oneshot` systemd units
- [ ] `chmod 600` applied to every file containing secrets immediately after creation

## Audit Commands

```bash
# Regex injection: =~ with variable on RHS
rg '=~\s+\$' --glob '*.sh' -n

# Hard source of optional library (source without || true)
rg '^\s*(source|\.) ' --glob '*.sh' -n | grep -vE '\|\| true|\|\| :|&& (source|\.)'

# Bare $1/$2 instead of ${1:-}
rg 'local\s+\w+="?\$[12]"?' --glob '*.sh' -n

# shred usage
rg '\bshred\b' --glob '*.sh' -n

# Resource limits on Type=oneshot
rg -U 'Type=oneshot[\s\S]{0,200}(MemoryMax|MemoryHigh|CPUQuota)' --glob '*.sh' --multiline -n

# Missing chmod 600 on credential files
rg 'chmod 600' --glob '*.sh' -n
```

## Key Patterns Established

1. **Exact string matching for enums**: Use `[[ "$p" == "$value" ]]` in a loop, never `=~` regex.
2. **Allowlist validation before config interpolation**: Validate with `^[A-Za-z0-9_-]+$` before writing to YAML.
3. **chmod 600 on compose files with credentials**: Lock down permissions immediately after writing.
4. **Optional library sourcing**: `source ... 2>/dev/null || true` + `command -v` before each call.
5. **`${1:-}` for all positional parameters**: Required under `set -u` strict mode.
6. **No `shred` for secret deletion**: Use `rm` and full-disk encryption instead.
7. **App-specific credential management**: Determine if the app manages credentials via env vars (stremthru) or web UI (mediafusion) before adding prompts.
8. **Resource limits in Docker Compose, not systemd oneshot**: Oneshot wrappers just call `docker compose up/down`.

## Related Documentation

- [Coding Standards](../coding-standards.md) -- covers `set -u`, `${1:-}`, `chmod 600`, `curl --config`; does NOT yet cover YAML injection prevention or `shred` guidance
- [Architecture](../architecture.md) -- needs update to add `lib/debrid-utils.sh` and `lib/prowlarr-utils.sh` to shared libraries table
- [System Audit](../system-audit-2026-02-11.md) -- original audit that identified YAML injection, file permissions, `set -u` patterns
- [Hardening Plan](../plans/2026-02-11-refactor-system-audit-hardening-plan.md) -- master plan covering all four topics
