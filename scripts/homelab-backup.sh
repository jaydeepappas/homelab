#!/usr/bin/env bash
#
# backup of all /opt/appdata to r2 via restic
#
#   - Postgres (TeslaMate)      -> pg_dump over a live connection, to a plain .sql file
#   - live SQLite DBs           -> sqlite3 .backup (online-backup API, WAL-safe)
#   - everything else           -> restic reads the files directly off disk
#   - Palworld game install     -> EXCLUDED (re-downloadable via SteamCMD)
#   - upload                    -> restic to R2 (encrypted, deduped, versioned)
#
# repo is encrypted with a RESTIC_PASSWORD
#
# Nothing is stopped. Run as root (needs to read container-owned files under /opt).
#
set -euo pipefail

### ----------------------------------------------------------------- config ---
APPDATA="/opt/appdata"
DUMPS="/var/lib/homelab-backup/dumps"     # derived artifacts (pg_dump, sqlite snapshots)
                                          # fixed path, NOT date-stamped: restic dedupes on
                                          # content, and a stable path keeps snapshot
                                          # browsing/restore predictable across runs.
LOG="/var/log/homelab-backup.log"

# --- secrets / env -----------------------------------------------------------
# ENV_FILE holds:
#   AWS_ACCESS_KEY_ID      R2 API token (restic's S3 backend uses the AWS var names)
#   AWS_SECRET_ACCESS_KEY
#   DISCORD_WEBHOOK
#   RESTIC_PASSWORD
#   RESTIC_REPOSITORY      s3:https://<ACCOUNT_ID>.r2.cloudflarestorage.com/homelab-restic
#
# ABSOLUTE PATH ONLY. This script runs as root, whose ~ is /root -- a path written as
# ~/stacks/... silently resolves to /root/stacks/... and sources nothing.
ENV_FILE="/home/jaydee/stacks/scripts/.env"
set -a
[ -f "$ENV_FILE" ] && . "$ENV_FILE"
set +a

DISCORD_WEBHOOK="${DISCORD_WEBHOOK:-}"    # empty = notifications disabled
NOTIFY_ON_SUCCESS=true                    # set false for failures-only

# --- mise-managed tools --------------------------------------------------------
# restic is mise-managed (see mise.toml at the repo root), so it lives under
# jaydee's home dir, not /usr/bin. a bare `restic` on PATH -- even via mise's
# shim -- isn't enough: mise picks the pinned version by walking up from the
# CALLING PROCESS's cwd looking for mise.toml, and root's crontab has no reason
# to be cd'd into ~/stacks, so that lookup would miss the pin entirely.
# `mise exec -C <dir>` points mise straight at the right config regardless of
# cwd. On Linux this is a real exec() -- mise replaces itself with the restic
# process in place, so exit codes, stdio, and signals all pass through exactly
# as if restic had been invoked directly (verified against mise's own source:
# it calls exec::Command::exec(), not spawn-and-wait).
REPO_DIR="/home/jaydee/stacks"
export PATH="/home/jaydee/.local/bin:$PATH"   # so `mise` itself resolves
restic() { mise exec -C "$REPO_DIR" -- restic "$@"; }

# --- retention ---------------------------------------------------------------
# not handled by an R2 lifecycle rule. A lifecycle policy deleting objects
# out of a restic repo corrupts it: packs are content-addressed and shared between
# snapshots, so aging out an "old" pack can break last night's snapshot too.
KEEP_DAILY=7
KEEP_WEEKLY=4
KEEP_MONTHLY=6

# Full data verification is slow but egress from R2 is free. Run on Sundays.
CHECK_DAY=7                               # set to 0 to disable

DATE="$(date +%F_%H%M%S)"
JSONLOG="$(mktemp)"

### ---------------------------------------------------------------- helpers ---
log(){ printf '%s  %s\n' "$(date '+%F %T')" "$*" | tee -a "$LOG" >&2; }
die(){ log "FATAL: $*"; exit 1; }
require(){ command -v "$1" >/dev/null 2>&1 || die "missing required tool: $1"; }
human(){ numfmt --to=iec --suffix=B "${1:-0}" 2>/dev/null || echo "${1:-0}B"; }

# post a Discord embed. No-op if no webhook configured. Never fatal.
# Body is built with jq so quotes/newlines in the description can't break the JSON.
notify(){  # $1=color(int)  $2=title  $3=description
  [ -n "$DISCORD_WEBHOOK" ] || return 0
  jq -n --argjson c "$1" --arg t "$2" --arg d "$3" \
     '{embeds:[{title:$t,description:$d,color:$c}]}' \
  | curl -fsS -m 15 -H 'Content-Type: application/json' -d @- \
      "$DISCORD_WEBHOOK" >/dev/null 2>&1 || log "  WARN: Discord notify failed"
}

# resolve a running container id by name substring (avoids compose project-name coupling)
cid(){ docker ps --filter "name=$1" --format '{{.ID}}' | head -n1; }

# consistent snapshot of a live sqlite db (WAL-safe).
#
# NOTE: no gzip. Compressing before restic destroys dedupe -- a one-row change rewrites
# the whole gzip stream, so restic would see an entirely new blob every night. Plain
# files dedupe well, and restic compresses on its own (repo format v2).
#
# _sqlite_snap does the work; the two wrappers decide whether a problem is fatal.
_sqlite_snap(){  # $1=src  $2=dest(.db)
  [ -f "$1" ] || return 2                       # missing
  if sqlite3 "$1" ".timeout 10000" ".backup '$2'"; then
    log "  sqlite ok: $(basename "$1") ($(du -h "$2" | cut -f1))"
    return 0
  fi
  rm -f "$2"
  return 1                                      # locked / failed
}

# OPTIONAL db: absence is expected (version-dependent files). Warn, continue.
sqlite_optional(){
  local rc=0; _sqlite_snap "$1" "$2" || rc=$?
  case "$rc" in
    0) : ;;
    2) log "  sqlite skip (missing, optional): $1" ;;
    *) log "  WARN: sqlite backup failed (locked?): $1" ;;
  esac
  return 0
}

# REQUIRED db: if it's missing or unreadable the backup isn't trustworthy, so stop.
# This is the guard that would have caught the Jellyfin path being wrong -- a run that
# silently skips its own inputs must not report success.
sqlite_required(){
  local rc=0; _sqlite_snap "$1" "$2" || rc=$?
  case "$rc" in
    0) return 0 ;;
    2) die "required database missing: $1 (path changed? container moved?)" ;;
    *) die "required database could not be snapshotted (locked?): $1" ;;
  esac
}

### -------------------------------------------------------------- preflight ---
require docker; require restic; require sqlite3; require jq; require curl
[ "$(id -u)" -eq 0 ] || die "must run as root (reads container-owned files under /opt)"
[ -f "$ENV_FILE" ]              || die "env file not found: $ENV_FILE"
[ -n "${RESTIC_REPOSITORY:-}" ]    || die "RESTIC_REPOSITORY unset (check $ENV_FILE)"
[ -n "${RESTIC_PASSWORD:-}" ]      || die "RESTIC_PASSWORD unset (check $ENV_FILE)"
[ -n "${AWS_ACCESS_KEY_ID:-}" ]    || die "AWS_ACCESS_KEY_ID unset (check $ENV_FILE)"
[ -n "${AWS_SECRET_ACCESS_KEY:-}" ] || die "AWS_SECRET_ACCESS_KEY unset (check $ENV_FILE)"

rm -rf "$DUMPS"
mkdir -p "$DUMPS" "$(dirname "$LOG")"
chmod 700 "$(dirname "$DUMPS")"

SUMMARY="(no summary)"
DEGRADED=""                               # non-empty -> yellow, not green

# runs on ANY exit: clean dumps, then ping Discord with the outcome.
finish(){
  local rc=$?
  rm -rf "$DUMPS" "$JSONLOG"
  if [ "$rc" -eq 0 ]; then
    if [ "$NOTIFY_ON_SUCCESS" = true ]; then
      notify 3066993 "✅ homelab backup succeeded" \
        "\`$(hostname)\`"$'\n'"$SUMMARY"
    fi
  elif [ "$rc" -eq 10 ]; then
    # degraded: the snapshot IS written and uploaded, but something downstream needs
    # looking at. Yellow, not red -- you still have a restore point.
    notify 16776960 "⚠️ homelab backup degraded" \
      "\`$(hostname)\` — ${DEGRADED}"$'\n'"$SUMMARY"$'\n'"Check \`${LOG}\`."
  else
    notify 15158332 "❌ homelab backup failed" \
      "\`$(hostname)\` — exited $rc. Check \`${LOG}\`."
  fi
}
trap finish EXIT

log "=== backup start ${DATE} ==="

### -------------------------------------------------- TeslaMate (Postgres) ---
log "TeslaMate: pg_dump + grafana"
mkdir -p "$DUMPS/teslamate"
DB_CID="$(cid teslamate-database)"
[ -n "$DB_CID" ] || die "teslamate database container not running"
# creds pulled from the container's own env -> no secrets in this script
docker exec "$DB_CID" sh -c \
  'PGPASSWORD="$POSTGRES_PASSWORD" pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB"' \
  > "$DUMPS/teslamate/teslamate-db.sql"
log "  postgres dumped ($(du -h "$DUMPS/teslamate/teslamate-db.sql" | cut -f1))"
sqlite_required "$APPDATA/teslamate/grafana/grafana.db" "$DUMPS/teslamate/grafana.db"

### ------------------------------------------------------- Home Assistant ---
log "Home Assistant: recorder snapshot"
mkdir -p "$DUMPS/homeassistant"
sqlite_required "$APPDATA/homeassistant/config/home-assistant_v2.db" \
                "$DUMPS/homeassistant/home-assistant_v2.db"
# the config tree itself (including hidden .storage) is read straight off disk by restic.

### -------------------------------------------------------------- Jellyfin ---
# JF is the host dir mounted to the container's /config. The databases live one level
# further down, at $JF/data -- NOT at $APPDATA/jellyfin/data.
#
# DB version note: pre-10.11 the single database is library.db. 10.11 moved to an
# EF Core split (jellyfin.db + authentication.db) and library.db can linger through
# the migration. jellyfin.db is required; the other two are optional by version.
# Also: Jellyfin has NO downgrade path -- starting a new major applies migrations
# immediately, so a snapshot taken *before* an upgrade is your only way back.
log "Jellyfin: db snapshots"
mkdir -p "$DUMPS/jellyfin"
JF="$APPDATA/jellyfin/config"
sqlite_required "$JF/data/jellyfin.db"       "$DUMPS/jellyfin/jellyfin.db"
sqlite_optional "$JF/data/library.db"        "$DUMPS/jellyfin/library.db"
sqlite_optional "$JF/data/authentication.db" "$DUMPS/jellyfin/authentication.db"

### ------------------------------------------------------------ back it up ---
# Explicit source paths rather than a blanket /opt/appdata sweep. Two reasons:
#   - TeslaMate's live Postgres data dir must NOT be swept in (torn, large, useless --
#     the pg_dump above is the real backup). A wholesale sweep would grab it.
#   - Palworld's game install and live Pal/Saved tree sit under the same parent as the
#     container's own quiesced save tarballs, which are the only part worth keeping.
# Cost: a NEW service under /opt/appdata is not backed up until it's added here.
# Periodically diff this list against `ls /opt/appdata`.
SOURCES=(
  "$DUMPS"
  "$APPDATA/homeassistant"
  "$APPDATA/jellyfin"
  "$APPDATA/caddy"
  "$APPDATA/palworld/palworld/backups"
)

EXCLUDES=(
  # live DBs -- snapshotted above via the online-backup API
  --exclude "$APPDATA/homeassistant/config/home-assistant_v2.db*"
  --exclude "$JF/data/*.db"
  --exclude "$JF/data/*.db-wal"
  --exclude "$JF/data/*.db-shm"
  --exclude "$JF/data/*.db-journal"
  # HA: redundant internal backups, logs, regenerable caches
  --exclude "$APPDATA/homeassistant/config/backups"
  --exclude "$APPDATA/homeassistant/config/home-assistant.log*"
  --exclude "$APPDATA/homeassistant/config/deps"
  --exclude "$APPDATA/homeassistant/config/tts"
  --exclude "__pycache__"
  # Jellyfin: regenerable / bulky (metadata is re-scrapable artwork + NFO).
  # NOTE the cache dir is a SEPARATE bind mount at $APPDATA/jellyfin/cache, a sibling of
  # config/ -- not $JF/cache. It also holds transcodes. --exclude-caches happens to catch
  # it via its CACHEDIR.TAG, but don't rely on Jellyfin continuing to write that file.
  --exclude "$APPDATA/jellyfin/cache"
  --exclude "$JF/log"
  --exclude "$JF/metadata"
  # anything marked with a CACHEDIR.TAG
  --exclude-caches
)

log "restic backup -> ${RESTIC_REPOSITORY}"
set +e
restic backup "${SOURCES[@]}" "${EXCLUDES[@]}" \
  --tag homelab --host "$(hostname)" --json >"$JSONLOG" 2>>"$LOG"
RC=$?
set -e

# restic exit codes: 0 = clean, 3 = snapshot written but some files were unreadable.
# Treat 3 as a distinct outcome, NOT as success -- the old script had no way to tell.
if [ "$RC" -ne 0 ] && [ "$RC" -ne 3 ]; then
  die "restic backup failed (exit $RC)"
fi

# last summary line carries the run stats
if S="$(jq -c 'select(.message_type=="summary")' "$JSONLOG" | tail -n1)" && [ -n "$S" ]; then
  SNAP="$(jq -r '.snapshot_id[0:8]'          <<<"$S")"
  ADDED="$(jq -r '.data_added'               <<<"$S")"
  PROC="$(jq -r '.total_bytes_processed'     <<<"$S")"
  NEW="$(jq -r '.files_new'                  <<<"$S")"
  CHG="$(jq -r '.files_changed'              <<<"$S")"
  DUR="$(jq -r '.total_duration | floor'     <<<"$S")"
  SUMMARY="snapshot \`${SNAP}\` — $(human "$ADDED") added of $(human "$PROC") processed, ${NEW} new / ${CHG} changed files, ${DUR}s"
  log "  $SUMMARY"
fi

if [ "$RC" -eq 3 ]; then
  DEGRADED="snapshot written, some files unreadable."
  log "WARN: some files were unreadable; snapshot is incomplete"
fi

### ----------------------------------------------------------- retention ---
# --host matches the backup above: without it, retention would pool this box's snapshots
# with any other host that ever writes to this repo under the same tag.
#
# A prune failure is NOT a backup failure -- the snapshot is already written and uploaded
# by this point. Stale locks make prune fail often enough that reporting it red would cry
# wolf about data that is in fact safe, so it degrades the run to yellow instead.
log "forget/prune (d=${KEEP_DAILY} w=${KEEP_WEEKLY} m=${KEEP_MONTHLY})"
set +e
restic forget \
  --tag homelab \
  --host "$(hostname)" \
  --keep-daily "$KEEP_DAILY" \
  --keep-weekly "$KEEP_WEEKLY" \
  --keep-monthly "$KEEP_MONTHLY" \
  --prune >>"$LOG" 2>&1
PRUNE_RC=$?
set -e

if [ "$PRUNE_RC" -ne 0 ]; then
  DEGRADED="${DEGRADED:+${DEGRADED} }forget/prune failed (exit ${PRUNE_RC}); snapshot is safe but retention was not applied."
  log "WARN: forget/prune failed (exit $PRUNE_RC); snapshot is safe, retention not applied"
fi

### -------------------------------------------------------- verification ---
# `restic check` validates repo structure (cheap). --read-data re-downloads and
# re-hashes every pack, which is the only way to actually prove the remote copy is
# intact. Free on R2 (no egress charges), so run the full version weekly.
if [ "$CHECK_DAY" -ne 0 ] && [ "$(date +%u)" -eq "$CHECK_DAY" ]; then
  log "weekly restic check --read-data"
  if ! restic check --read-data >>"$LOG" 2>&1; then
    notify 15158332 "❌ restic check FAILED" \
      "\`$(hostname)\` — repo integrity check failed. Check \`${LOG}\`."
    die "restic check failed"
  fi
  log "  repo verified"
fi

log "=== backup done ${DATE} ==="

# exit 10 (not 3) on a degraded run, so the trap can tell it apart from restic's own codes
[ -n "$DEGRADED" ] && exit 10
exit 0