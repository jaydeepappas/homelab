#!/usr/bin/env bash
#
# homelab-backup.sh
# Consistent, ZERO-DOWNTIME backup of all /opt/appdata service state to R2 (plain, no crypt).
#
#   - Postgres (TeslaMate)      -> pg_dump over a live connection
#   - live SQLite DBs           -> sqlite3 .backup (online-backup API, WAL-safe)
#   - everything else           -> tar (config, certs, tokens, fabric creds, saves)
#   - Palworld game install      -> EXCLUDED (re-downloadable via SteamCMD)
#   - upload                     -> rclone to a plain R2 remote
#
# NOTE: the archive is uploaded UNENCRYPTED. A few files in it are account-level
# credentials (Ring tokens, Tesla Fleet key, HA secrets.yaml). Bucket safety rests
# entirely on your R2 API token + keeping the bucket private. Decided trade-off.
#
# Nothing is stopped. Run as root (needs to read container-owned files under /opt).
#
set -euo pipefail

### ----------------------------------------------------------------- config ---
APPDATA="/opt/appdata"
STAGING_ROOT="/var/tmp/homelab-backup"    # scratch; needs room for one run (< ~2 GB here)
# rclone's config lives under the normal user, but this script runs as root (sudo), whose
# HOME is /root with no config -> point rclone at the user's config explicitly so every
# rclone call below resolves the remote regardless of who runs it.
export RCLONE_CONFIG="/home/jaydee/.config/rclone/rclone.conf"
RCLONE_REMOTE="r2:homelab"                # remote 'r2' + dedicated folder
KEEP_LOCAL=2                             # finished archives to keep on-box
# Remote retention is handled by an R2 bucket lifecycle policy, not this script.
LOG="/var/log/homelab-backup.log"

# --- notifications -----------------------------------------------------------
# Discord webhook is a secret -> keep it OUT of this script (and out of git).
# Put it in a root-only file:  echo 'DISCORD_WEBHOOK="https://..."' > /etc/homelab-backup.env
#                              chmod 600 /etc/homelab-backup.env
[ -f /etc/homelab-backup.env ] && . /etc/homelab-backup.env
DISCORD_WEBHOOK="${DISCORD_WEBHOOK:-}"   # empty = notifications disabled
NOTIFY_ON_SUCCESS=true                    # daily heartbeat; set false for failures-only
ARCHIVE_SIZE="?"                          # filled in once the archive is built

DATE="$(date +%F_%H%M%S)"
STAGE="${STAGING_ROOT}/${DATE}"
ARCHIVE="${STAGING_ROOT}/homelab-${DATE}.tar"   # outer tar is uncompressed:
                                                # members are already individually gzipped,
                                                # so partial restore stays trivial.

### ---------------------------------------------------------------- helpers ---
log(){ printf '%s  %s\n' "$(date '+%F %T')" "$*" | tee -a "$LOG" >&2; }
die(){ log "FATAL: $*"; exit 1; }
require(){ command -v "$1" >/dev/null 2>&1 || die "missing required tool: $1"; }

# post a Discord embed. No-op if no webhook configured. Never fatal.
notify(){  # $1=color(int)  $2=title  $3=description
  [ -n "$DISCORD_WEBHOOK" ] || return 0
  curl -fsS -m 15 -H 'Content-Type: application/json' \
    -d "{\"embeds\":[{\"title\":\"$2\",\"description\":\"$3\",\"color\":$1}]}" \
    "$DISCORD_WEBHOOK" >/dev/null 2>&1 || log "  WARN: Discord notify failed"
}

# resolve a running container id by name substring (avoids compose project-name coupling)
cid(){ docker ps --filter "name=$1" --format '{{.ID}}' | head -n1; }

# consistent snapshot of a live sqlite db (WAL-safe), gzipped. Non-fatal: a single
# locked/missing db warns and continues rather than killing the whole run.
# dest should end in .db.gz -- we snapshot to a temp file then compress.
sqlite_backup(){  # $1=src  $2=dest(.db.gz)
  [ -f "$1" ] || { log "  sqlite skip (missing): $1"; return 0; }
  local tmp="${2%.gz}"
  if sqlite3 "$1" ".timeout 10000" ".backup '$tmp'"; then
    gzip -f "$tmp"                     # -> $2
    log "  sqlite ok: $(basename "$1") ($(du -h "$2" | cut -f1))"
  else
    rm -f "$tmp"
    log "  WARN: sqlite backup failed (locked?): $1"
  fi
  return 0
}

### -------------------------------------------------------------- preflight ---
require docker; require rclone; require sqlite3; require tar; require gzip; require curl
[ "$(id -u)" -eq 0 ] || die "must run as root (reads container-owned files under /opt)"
mkdir -p "$STAGE" "$(dirname "$LOG")"

# runs on ANY exit: clean staging, then ping Discord with the outcome.
finish(){
  local rc=$?
  rm -rf "$STAGE"
  if [ "$rc" -eq 0 ]; then
    if [ "$NOTIFY_ON_SUCCESS" = true ]; then
      notify 3066993 "✅ homelab backup succeeded" \
        "\`$(hostname)\` — ${ARCHIVE_SIZE} uploaded to \`${RCLONE_REMOTE}\`"
    fi
  else
    notify 15158332 "❌ homelab backup failed" \
      "\`$(hostname)\` — exited $rc. Check \`${LOG}\`."
  fi
}
trap finish EXIT

log "=== backup start ${DATE} ==="

### -------------------------------------------------- TeslaMate (Postgres) ---
log "TeslaMate: pg_dump + grafana"
mkdir -p "$STAGE/teslamate"
DB_CID="$(cid teslamate-database)"
[ -n "$DB_CID" ] || die "teslamate database container not running"
# creds pulled from the container's own env -> no secrets in this script
docker exec "$DB_CID" sh -c \
  'PGPASSWORD="$POSTGRES_PASSWORD" pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB"' \
  | gzip > "$STAGE/teslamate/teslamate-db.sql.gz"
log "  postgres dumped ($(du -h "$STAGE/teslamate/teslamate-db.sql.gz" | cut -f1))"
sqlite_backup "$APPDATA/teslamate/grafana/grafana.db" "$STAGE/teslamate/grafana.db"

### ------------------------------------------------------- Home Assistant ---
log "Home Assistant: recorder snapshot + config + ring + matter + mosquitto"
mkdir -p "$STAGE/homeassistant"
# recorder db: consistent live snapshot (we exclude the raw file from the config tar below)
sqlite_backup "$APPDATA/homeassistant/config/home-assistant_v2.db" \
              "$STAGE/homeassistant/home-assistant_v2.db"
# config tree (INCLUDING hidden .storage -- the entity/device/auth registry) minus:
#   live db, HA's own redundant backups, logs, regenerable caches
tar czf "$STAGE/homeassistant/config.tar.gz" \
  --exclude='config/home-assistant_v2.db' \
  --exclude='config/home-assistant_v2.db-wal' \
  --exclude='config/home-assistant_v2.db-shm' \
  --exclude='config/backups' \
  --exclude='config/home-assistant.log*' \
  --exclude='config/deps' \
  --exclude='config/tts' \
  --exclude='*/__pycache__' \
  -C "$APPDATA/homeassistant" config
# small, precious, copy-whole:
tar czf "$STAGE/homeassistant/ring.tar.gz"          -C "$APPDATA/homeassistant" ring
tar czf "$STAGE/homeassistant/matter-server.tar.gz" -C "$APPDATA/homeassistant" matter-server
tar czf "$STAGE/homeassistant/mosquitto.tar.gz"     -C "$APPDATA/homeassistant" mosquitto

### --------------------------------------------------------------- Pi-hole ---
log "Pi-hole: sqlite snapshots + config"
mkdir -p "$STAGE/pihole"
sqlite_backup "$APPDATA/pihole/etc-pihole/gravity.db"    "$STAGE/pihole/gravity.db"
sqlite_backup "$APPDATA/pihole/etc-pihole/pihole-FTL.db" "$STAGE/pihole/pihole-FTL.db"
# config files (toml, custom lists, tls, password) minus the live dbs + rotating dupes
tar czf "$STAGE/pihole/etc-pihole.tar.gz" \
  --exclude='etc-pihole/*.db' \
  --exclude='etc-pihole/*.db-wal' \
  --exclude='etc-pihole/*.db-shm' \
  --exclude='etc-pihole/gravity_backups' \
  --exclude='etc-pihole/config_backups' \
  -C "$APPDATA/pihole" etc-pihole

### ----------------------------------------------------------------- Caddy ---
log "Caddy: certs + config"
mkdir -p "$STAGE/caddy"
tar czf "$STAGE/caddy/caddy.tar.gz" -C "$APPDATA" caddy

### -------------------------------------------------------------- Palworld ---
# Ship the container's OWN save tarballs, not the live Pal/Saved tree: the image makes
# those at a quiesced save point (consistent), whereas tarring the live tree races the
# server's rolling writes. Game install is re-downloadable -> skipped either way.
log "Palworld: container save tarballs (live tree + game binaries excluded)"
mkdir -p "$STAGE/palworld"
PW="$APPDATA/palworld/palworld"
if [ -d "$PW/backups" ] && [ -n "$(ls -A "$PW/backups" 2>/dev/null)" ]; then
  tar czf "$STAGE/palworld/save-tarballs.tar.gz" -C "$PW" backups
  log "  shipped $(ls -1 "$PW/backups" | wc -l) save tarball(s)"
else
  log "  WARN: no Palworld save tarballs found in $PW/backups"
fi

### ------------------------------------------------------------ pack + ship ---
log "packing archive"
tar cf "$ARCHIVE" -C "$STAGE" .
ARCHIVE_SIZE="$(du -h "$ARCHIVE" | cut -f1)"
log "archive ${ARCHIVE} (${ARCHIVE_SIZE})"

log "uploading to ${RCLONE_REMOTE}"
rclone copy "$ARCHIVE" "$RCLONE_REMOTE"

### ----------------------------------------------------- local retention ---
log "pruning local archives (keep ${KEEP_LOCAL})"
# shellcheck disable=SC2012
ls -1t "${STAGING_ROOT}"/homelab-*.tar 2>/dev/null | tail -n +$((KEEP_LOCAL+1)) | xargs -r rm -f

log "=== backup done ${DATE} ==="
