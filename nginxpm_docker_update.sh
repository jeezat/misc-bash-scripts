#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

# Regelmaessiges Update fuer den Nginx Proxy Manager aus compose.yml.
# Optionale Umgebungsvariablen:
#   BACKUP_DIR=/pfad          Ziel fuer Sicherungen (Standard: ./backups)
#   BACKUP_RETENTION_DAYS=30  Alte Sicherungen loeschen; 0 deaktiviert dies
#   FORCE_UPDATE=1            Neustart/Backup auch ohne neues Image erzwingen
#   WAIT_TIMEOUT=120          Maximale Wartezeit auf den Container in Sekunden

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
COMPOSE_FILE="${COMPOSE_FILE:-${SCRIPT_DIR}/compose.yml}"
BACKUP_DIR="${BACKUP_DIR:-${SCRIPT_DIR}/backups}"
BACKUP_RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-30}"
FORCE_UPDATE="${FORCE_UPDATE:-0}"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-120}"
SERVICE_NAME="${SERVICE_NAME:-app}"

timestamp="$(date '+%Y%m%d_%H%M%S')"
backup_file="${BACKUP_DIR}/nginxpm-backup_${timestamp}.tar.gz"
temporary_backup="${backup_file}.tmp"
service_stopped=0

log() {
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

fail() {
    log "FEHLER: $*" >&2
    exit 1
}

is_non_negative_integer() {
    [[ "$1" =~ ^[0-9]+$ ]]
}

cleanup() {
    local exit_code=$?

    rm -f -- "$temporary_backup"

    # Wurde nur fuer das Backup gestoppt, den unveraenderten Container wieder
    # starten. Nach Beginn der Neuerstellung greift diese Automatik nicht mehr.
    if (( exit_code != 0 && service_stopped == 1 )); then
        log "Update abgebrochen; der bisherige Container wird wieder gestartet."
        "${COMPOSE[@]}" start "$SERVICE_NAME" >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT

[[ -f "$COMPOSE_FILE" ]] || fail "Compose-Datei nicht gefunden: $COMPOSE_FILE"
command -v docker >/dev/null 2>&1 || fail "Docker wurde nicht gefunden."
command -v tar >/dev/null 2>&1 || fail "tar wurde nicht gefunden."
is_non_negative_integer "$BACKUP_RETENTION_DAYS" || \
    fail "BACKUP_RETENTION_DAYS muss eine nicht-negative ganze Zahl sein."
is_non_negative_integer "$WAIT_TIMEOUT" || \
    fail "WAIT_TIMEOUT muss eine nicht-negative ganze Zahl sein."
[[ "$FORCE_UPDATE" == "0" || "$FORCE_UPDATE" == "1" ]] || \
    fail "FORCE_UPDATE muss 0 oder 1 sein."

if docker compose version >/dev/null 2>&1; then
    COMPOSE=(docker compose --file "$COMPOSE_FILE" --project-directory "$SCRIPT_DIR")
elif command -v docker-compose >/dev/null 2>&1; then
    COMPOSE=(docker-compose --file "$COMPOSE_FILE" --project-directory "$SCRIPT_DIR")
else
    fail "Weder 'docker compose' noch 'docker-compose' ist verfuegbar."
fi

docker info >/dev/null 2>&1 || \
    fail "Docker ist nicht erreichbar. Ist der Dienst aktiv und darf der Benutzer Docker verwenden?"

mkdir -p -- "$BACKUP_DIR"
if command -v flock >/dev/null 2>&1; then
    exec 9>"${BACKUP_DIR}/.update.lock"
    flock -n 9 || fail "Ein weiteres Update laeuft bereits."
else
    log "WARNUNG: 'flock' fehlt; parallele Skriptaufrufe werden nicht verhindert."
fi

container_id="$("${COMPOSE[@]}" ps -q "$SERVICE_NAME")"
old_image_id=""
image_reference=""

if [[ -n "$container_id" ]]; then
    old_image_id="$(docker inspect --format '{{.Image}}' "$container_id")"
    image_reference="$(docker inspect --format '{{.Config.Image}}' "$container_id")"
fi

log "Lade das aktuelle Image fuer den Dienst '${SERVICE_NAME}' ..."
"${COMPOSE[@]}" pull "$SERVICE_NAME"

new_image_id=""
if [[ -n "$image_reference" ]]; then
    new_image_id="$(docker image inspect --format '{{.Id}}' "$image_reference" 2>/dev/null || true)"
fi

if [[ "$FORCE_UPDATE" == "0" && -n "$old_image_id" && "$old_image_id" == "$new_image_id" ]]; then
    log "Kein neues Image vorhanden; es ist kein Neustart erforderlich."
    exit 0
fi

backup_sources=()
[[ -e "${SCRIPT_DIR}/data" ]] && backup_sources+=(data)
[[ -e "${SCRIPT_DIR}/letsencrypt" ]] && backup_sources+=(letsencrypt)
compose_basename="$(basename -- "$COMPOSE_FILE")"
if [[ "$(cd -- "$(dirname -- "$COMPOSE_FILE")" && pwd -P)" == "$SCRIPT_DIR" ]]; then
    backup_sources+=("$compose_basename")
fi

if [[ -n "$container_id" ]]; then
    log "Stoppe den Dienst kurz fuer ein konsistentes SQLite-Backup ..."
    "${COMPOSE[@]}" stop "$SERVICE_NAME"
    service_stopped=1
fi

if (( ${#backup_sources[@]} > 0 )); then
    log "Erstelle Backup: $backup_file"
    tar \
        --exclude='data/logs' \
        -czf "$temporary_backup" \
        -C "$SCRIPT_DIR" \
        "${backup_sources[@]}"
    mv -- "$temporary_backup" "$backup_file"
else
    log "WARNUNG: Keine lokalen Datenverzeichnisse zum Sichern gefunden."
fi

# Ab jetzt koennte Compose den alten Container ersetzen. Die Cleanup-Funktion
# darf ihn deshalb nicht mehr blind mit 'start' reaktivieren.
service_stopped=0

log "Starte Nginx Proxy Manager mit dem neuen Image ..."
"${COMPOSE[@]}" up -d --remove-orphans "$SERVICE_NAME"

log "Pruefe den Containerstatus (Timeout: ${WAIT_TIMEOUT}s) ..."
deadline=$((SECONDS + WAIT_TIMEOUT))
while :; do
    container_id="$("${COMPOSE[@]}" ps -q "$SERVICE_NAME")"
    state=""
    health="none"

    if [[ -n "$container_id" ]]; then
        state="$(docker inspect --format '{{.State.Status}}' "$container_id")"
        health="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$container_id")"
    fi

    if [[ "$state" == "running" && ( "$health" == "healthy" || "$health" == "none" ) ]]; then
        break
    fi
    if [[ "$state" == "exited" || "$state" == "dead" || "$health" == "unhealthy" ]]; then
        "${COMPOSE[@]}" logs --tail 80 "$SERVICE_NAME" >&2 || true
        fail "Der aktualisierte Container ist nicht funktionsfaehig (Status: ${state:-unbekannt}, Health: $health)."
    fi
    if (( SECONDS >= deadline )); then
        "${COMPOSE[@]}" logs --tail 80 "$SERVICE_NAME" >&2 || true
        fail "Der Container wurde nicht rechtzeitig bereit (Status: ${state:-unbekannt}, Health: $health)."
    fi
    sleep 2
done

if (( BACKUP_RETENTION_DAYS > 0 )); then
    find "$BACKUP_DIR" \
        -maxdepth 1 \
        -type f \
        -name 'nginxpm-backup_*.tar.gz' \
        -mtime "+${BACKUP_RETENTION_DAYS}" \
        -delete
fi

log "Update erfolgreich. Containerstatus: $state, Health: $health"
[[ -f "$backup_file" ]] && log "Backup: $backup_file"
