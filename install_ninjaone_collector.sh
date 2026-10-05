#!/usr/bin/env bash
#
# Installer for the NinjaOne activity log collector.
#
#   sudo ./install_ninjaone_collector.sh            # interactive
#   sudo ./install_ninjaone_collector.sh -y --interval 5min --initial-offset 20
#   sudo ./install_ninjaone_collector.sh --uninstall [--purge]
#
# What it does:
#   - creates a system service account (no home, no login shell)
#   - creates /var/lib/ninjaone (state) and /var/log/ninjaone (logs)
#   - installs the collector to /usr/bin/ninja-collector and makes it immutable (chattr +i)
#   - stores API credentials in /etc/ninjaone/ninjaone.env (root only, 0600)
#   - writes and enables a systemd service + timer (default every 5 minutes)
#   - runs the first collection, starting N activity IDs back from the newest
#
# Safe to re-run: it updates the binary/config/units and keeps existing state.

set -euo pipefail

# ----------------------------------------------------------------------------
# Defaults
# ----------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE="${SCRIPT_DIR}/ninjaone_collector.py"
[[ -f "$SOURCE" ]] || SOURCE="${SCRIPT_DIR}/ninja_collector.py"   # older file name
SRC_ENV="${SCRIPT_DIR}/.env"

SVC_USER="ninjaone"
BIN="/usr/bin/ninja-collector"
CONF_DIR="/etc/ninjaone"
CRED_FILE="${CONF_DIR}/ninjaone.env"
CONF_FILE="${CONF_DIR}/collector.conf"
STATE_DIR="/var/lib/ninjaone"
LOG_DIR="/var/log/ninjaone"
VENV_DIR="/opt/ninjaone/venv"
UNIT_NAME="ninjaone-collector"
UNIT_DIR="/etc/systemd/system"
LOGROTATE_FILE="/etc/logrotate.d/ninjaone-collector"

BASE_URL="https://us2.ninjarmm.com"
INTERVAL="5min"
INITIAL_OFFSET="20"
PAGE_SIZE="500"
ADD_ISO="false"
LOG_NAME="%Y%m%d.log"
RETENTION="14"
START="true"
RESET_STATE="false"
ASSUME_YES="false"
UNINSTALL="false"
PURGE="false"
CLIENT_ID=""
CLIENT_SECRET=""

# ----------------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------------
info()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn()  { printf '\033[1;33mWARN:\033[0m %s\n' "$*" >&2; }
die()   { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
cat <<EOF
Usage: sudo $0 [options]

Credentials (prompted if not given; .env next to this script is used if present):
  --env-file PATH        Read CLIENT_ID / CLIENT_SECRET from this .env file
  --client-id ID         NinjaOne API client ID
  --client-secret SECRET NinjaOne API client secret (prefer the prompt/.env;
                         command-line args are visible in shell history / ps)

Collector settings:
  --source PATH          Collector script to install (default: ${SOURCE})
  --base-url URL         NinjaOne instance URL (default: ${BASE_URL})
  --interval SPAN        How often to run, systemd time span (default: ${INTERVAL})
                         e.g. 60s, 5min, 15min, 1h
  --initial-offset N     First run collects the last N activity IDs (default: ${INITIAL_OFFSET})
  --page-size N          API page size (default: ${PAGE_SIZE})
  --add-iso              Add activityTimeISO (UTC) to each log line
  --user NAME            Service account name (default: ${SVC_USER})
  --reset-state          Delete the saved last activity ID (re-seeds with --initial-offset)

Log files:
  --log-name PATTERN     Daily log file name, strftime codes (default: ${LOG_NAME})
  --retention DAYS       Delete daily log files older than DAYS (default: ${RETENTION}; 0 = keep forever)

Other:
  --no-start             Install and enable, but don't run the first collection now
  -y, --yes              Non-interactive; accept defaults / given options
  --uninstall            Remove service, timer, binary and config (keeps logs + state)
  --purge                With --uninstall: also delete logs, state and the service account
  -h, --help             Show this help
EOF
}

# prompt VAR "Question" default
prompt() {
    local __var="$1" __q="$2" __def="${3:-}" __ans
    if [[ "$ASSUME_YES" == "true" ]]; then
        printf -v "$__var" '%s' "$__def"; return
    fi
    read -r -p "$__q [${__def}]: " __ans
    printf -v "$__var" '%s' "${__ans:-$__def}"
}

prompt_yn() {  # prompt_yn "Question" default(y|n) -> returns 0 for yes
    local __q="$1" __def="$2" __ans
    [[ "$ASSUME_YES" == "true" ]] && { [[ "$__def" == "y" ]]; return; }
    read -r -p "$__q [$( [[ $__def == y ]] && echo Y/n || echo y/N )]: " __ans
    __ans="${__ans:-$__def}"
    [[ "${__ans,,}" == y* ]]
}

read_env_value() {  # read_env_value FILE KEY
    local line
    line="$(grep -E "^[[:space:]]*(export[[:space:]]+)?$2[[:space:]]*=" "$1" | tail -n1 || true)"
    line="${line#*=}"
    line="$(sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' <<<"$line")"
    if [[ "$line" =~ ^\"(.*)\"$ || "$line" =~ ^\'(.*)\'$ ]]; then
        line="${BASH_REMATCH[1]}"
    fi
    printf '%s' "$line"
}

unlock_bin() {
    if [[ -e "$BIN" ]] && command -v chattr >/dev/null; then
        chattr -i "$BIN" 2>/dev/null || true
    fi
}

# ----------------------------------------------------------------------------
# Parse args
# ----------------------------------------------------------------------------
ENV_FILE_ARG=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --env-file)       ENV_FILE_ARG="$2"; shift 2 ;;
        --client-id)      CLIENT_ID="$2"; shift 2 ;;
        --client-secret)  CLIENT_SECRET="$2"; shift 2 ;;
        --source)         SOURCE="$2"; shift 2 ;;
        --base-url)       BASE_URL="$2"; shift 2 ;;
        --interval)       INTERVAL="$2"; shift 2 ;;
        --initial-offset) INITIAL_OFFSET="$2"; shift 2 ;;
        --page-size)      PAGE_SIZE="$2"; shift 2 ;;
        --add-iso)        ADD_ISO="true"; shift ;;
        --user)           SVC_USER="$2"; shift 2 ;;
        --reset-state)    RESET_STATE="true"; shift ;;
        --retention)      RETENTION="$2"; shift 2 ;;
        --log-name)       LOG_NAME="$2"; shift 2 ;;
        --no-logrotate)   RETENTION="0"; shift ;;   # backward compatible
        --no-start)       START="false"; shift ;;
        -y|--yes)         ASSUME_YES="true"; shift ;;
        --uninstall)      UNINSTALL="true"; shift ;;
        --purge)          PURGE="true"; shift ;;
        -h|--help)        usage; exit 0 ;;
        *) usage; die "Unknown option: $1" ;;
    esac
done

[[ $EUID -eq 0 ]] || die "Run this installer with sudo."

# systemd must be PID 1 (on WSL this needs [boot] systemd=true in /etc/wsl.conf)
if [[ "$(ps -p 1 -o comm= 2>/dev/null)" != "systemd" ]]; then
    if grep -qi microsoft /proc/version 2>/dev/null; then
        die "systemd is not running in this WSL distro. Add the following to /etc/wsl.conf:

    [boot]
    systemd=true

then run 'wsl --shutdown' from Windows PowerShell, reopen the distro, and re-run this installer."
    fi
    die "systemd is not running (PID 1 is '$(ps -p 1 -o comm=)')."
fi

# ----------------------------------------------------------------------------
# Uninstall
# ----------------------------------------------------------------------------
if [[ "$UNINSTALL" == "true" ]]; then
    info "Stopping and disabling ${UNIT_NAME}.timer / .service"
    systemctl disable --now "${UNIT_NAME}.timer" 2>/dev/null || true
    systemctl stop "${UNIT_NAME}.service" 2>/dev/null || true
    rm -f "${UNIT_DIR}/${UNIT_NAME}.service" "${UNIT_DIR}/${UNIT_NAME}.timer"
    rm -rf "${UNIT_DIR}/${UNIT_NAME}.service.d" "${UNIT_DIR}/${UNIT_NAME}.timer.d"
    systemctl daemon-reload
    info "Removing ${BIN}, ${CONF_DIR}, ${LOGROTATE_FILE}"
    unlock_bin
    rm -f "$BIN" "$LOGROTATE_FILE"
    rm -rf "$CONF_DIR" "$(dirname "$VENV_DIR")"
    if [[ "$PURGE" == "true" ]]; then
        info "Purging ${STATE_DIR}, ${LOG_DIR} and user ${SVC_USER}"
        rm -rf "$STATE_DIR" "$LOG_DIR"
        id "$SVC_USER" >/dev/null 2>&1 && userdel "$SVC_USER" || true
    else
        info "Kept ${STATE_DIR}, ${LOG_DIR} and user ${SVC_USER} (use --purge to remove)"
    fi
    info "Uninstall complete."
    exit 0
fi

# ----------------------------------------------------------------------------
# Gather options
# ----------------------------------------------------------------------------
[[ -f "$SOURCE" ]] || die "Collector script not found: $SOURCE (use --source)"

# Credentials: --env-file > .env next to installer > existing install > prompt
CANDIDATE_ENV="${ENV_FILE_ARG:-}"
if [[ -z "$CANDIDATE_ENV" && -z "$CLIENT_ID" && -f "$SRC_ENV" ]]; then
    prompt_yn "Found ${SRC_ENV}. Use its CLIENT_ID / CLIENT_SECRET?" y && CANDIDATE_ENV="$SRC_ENV"
fi
if [[ -z "$CANDIDATE_ENV" && -z "$CLIENT_ID" && -f "$CRED_FILE" ]]; then
    prompt_yn "Keep the credentials already installed in ${CRED_FILE}?" y && CANDIDATE_ENV="$CRED_FILE"
fi
if [[ -n "$CANDIDATE_ENV" ]]; then
    [[ -f "$CANDIDATE_ENV" ]] || die "Env file not found: $CANDIDATE_ENV"
    [[ -z "$CLIENT_ID" ]]     && CLIENT_ID="$(read_env_value "$CANDIDATE_ENV" CLIENT_ID)"
    [[ -z "$CLIENT_SECRET" ]] && CLIENT_SECRET="$(read_env_value "$CANDIDATE_ENV" CLIENT_SECRET)"
fi
if [[ -z "$CLIENT_ID" ]]; then
    [[ "$ASSUME_YES" == "true" ]] && die "No CLIENT_ID provided (use --env-file or --client-id)."
    read -r -p "NinjaOne CLIENT_ID: " CLIENT_ID
fi
if [[ -z "$CLIENT_SECRET" ]]; then
    [[ "$ASSUME_YES" == "true" ]] && die "No CLIENT_SECRET provided (use --env-file)."
    read -r -s -p "NinjaOne CLIENT_SECRET (hidden): " CLIENT_SECRET; echo
fi
[[ -n "$CLIENT_ID" && -n "$CLIENT_SECRET" ]] || die "CLIENT_ID and CLIENT_SECRET are both required."

prompt BASE_URL       "NinjaOne base URL"                         "$BASE_URL"
prompt INTERVAL       "Run interval (e.g. 60s, 5min, 1h)"         "$INTERVAL"
prompt INITIAL_OFFSET "First run: collect this many recent IDs"   "$INITIAL_OFFSET"
prompt SVC_USER       "Service account name"                      "$SVC_USER"

# Validate
[[ "$INITIAL_OFFSET" =~ ^[0-9]+$ ]] || die "--initial-offset must be a whole number"
[[ "$PAGE_SIZE" =~ ^[0-9]+$ ]]      || die "--page-size must be a whole number"
[[ "$RETENTION" =~ ^[0-9]+$ ]]      || die "--retention must be a whole number"
[[ "$SVC_USER" =~ ^[a-z_][a-z0-9_-]*$ ]] || die "Invalid user name: $SVC_USER"
[[ "$BASE_URL" =~ ^https:// ]]      || die "--base-url must start with https://"
[[ "$LOG_NAME" =~ ^[A-Za-z0-9._%-]+$ && "$LOG_NAME" == *.log ]] \
    || die "--log-name must be a plain file name ending in .log (strftime codes allowed)"
if command -v systemd-analyze >/dev/null; then
    systemd-analyze timespan "$INTERVAL" >/dev/null 2>&1 || die "Invalid interval: $INTERVAL"
fi

echo
info "Install summary"
cat <<EOF
    Collector    : ${BIN}  (from ${SOURCE})
    Service user : ${SVC_USER}
    Credentials  : ${CRED_FILE}  (CLIENT_ID=${CLIENT_ID:0:6}...)
    Base URL     : ${BASE_URL}
    Interval     : every ${INTERVAL}
    First run    : last ${INITIAL_OFFSET} activity IDs (only if no saved state)
    Logs         : ${LOG_DIR}/${LOG_NAME}  (today: $(date +"${LOG_NAME}"))
    State        : ${STATE_DIR}/last_activity_id
    Retention    : $( (( RETENTION > 0 )) && echo "delete logs older than ${RETENTION} days" || echo "keep forever")
EOF
echo
prompt_yn "Proceed?" y || die "Aborted."

# ----------------------------------------------------------------------------
# Python dependency (requests)
# ----------------------------------------------------------------------------
PYTHON="/usr/bin/python3"
[[ -x "$PYTHON" ]] || die "/usr/bin/python3 not found"
if ! "$PYTHON" -c 'import requests' 2>/dev/null; then
    if command -v apt-get >/dev/null; then
        info "Installing python3-requests via apt"
        DEBIAN_FRONTEND=noninteractive apt-get install -y -q python3-requests >/dev/null \
            || warn "apt install of python3-requests failed"
    fi
fi
if ! "$PYTHON" -c 'import requests' 2>/dev/null; then
    info "Creating dedicated virtualenv at ${VENV_DIR}"
    "$PYTHON" -m venv "$VENV_DIR" || die "python3 -m venv failed (install python3-venv)"
    "${VENV_DIR}/bin/python" -m pip install -q --upgrade pip requests
    PYTHON="${VENV_DIR}/bin/python"
fi
info "Using Python interpreter: ${PYTHON}"

# ----------------------------------------------------------------------------
# Service account
# ----------------------------------------------------------------------------
NOLOGIN="$(command -v nologin || echo /usr/sbin/nologin)"
if id "$SVC_USER" >/dev/null 2>&1; then
    info "Service account ${SVC_USER} already exists"
else
    info "Creating system account ${SVC_USER} (no home, no login)"
    useradd --system --no-create-home --home-dir /nonexistent \
            --shell "$NOLOGIN" --user-group "$SVC_USER"
fi
passwd -l "$SVC_USER" >/dev/null 2>&1 || true

# ----------------------------------------------------------------------------
# Directories
# ----------------------------------------------------------------------------
info "Creating ${STATE_DIR} and ${LOG_DIR}"
install -d -m 0750 -o "$SVC_USER" -g "$SVC_USER" "$STATE_DIR" "$LOG_DIR"
chown -R "$SVC_USER:$SVC_USER" "$STATE_DIR" "$LOG_DIR"
install -d -m 0755 -o root -g root "$CONF_DIR"

if [[ "$RESET_STATE" == "true" ]]; then
    info "Resetting saved state"
    rm -f "${STATE_DIR}/last_activity_id"
fi

# ----------------------------------------------------------------------------
# Credentials + config
# ----------------------------------------------------------------------------
# Use systemd LoadCredential (v248+) so the service account never reads the
# file directly; otherwise fall back to a group-readable file.
SYSTEMD_VER="$(systemctl --version | awk 'NR==1{print $2}')"
if [[ "${SYSTEMD_VER%%.*}" -ge 248 ]]; then
    USE_CREDS="true"; CRED_MODE="0600"; CRED_GROUP="root"
else
    USE_CREDS="false"; CRED_MODE="0640"; CRED_GROUP="$SVC_USER"
fi

info "Writing credentials to ${CRED_FILE} (mode ${CRED_MODE})"
TMP_CRED="$(mktemp "${CONF_DIR}/.env.XXXXXX")"
( umask 077; printf 'CLIENT_ID=%s\nCLIENT_SECRET=%s\n' "$CLIENT_ID" "$CLIENT_SECRET" > "$TMP_CRED" )
chown "root:${CRED_GROUP}" "$TMP_CRED"; chmod "$CRED_MODE" "$TMP_CRED"
mv -f "$TMP_CRED" "$CRED_FILE"
unset CLIENT_SECRET

info "Writing settings to ${CONF_FILE}"
cat > "$CONF_FILE" <<EOF
# NinjaOne collector settings (read by ${UNIT_NAME}.service).
# After editing: sudo systemctl restart ${UNIT_NAME}.timer
# NOTE: the service can only write inside ${STATE_DIR} and ${LOG_DIR}.
NINJA_BASE_URL=${BASE_URL}
# Daily file; strftime codes (%Y%m%d) are expanded by the collector at write time
NINJA_LOG_FILE=${LOG_DIR}/${LOG_NAME}
NINJA_STATE_FILE=${STATE_DIR}/last_activity_id
NINJA_PAGE_SIZE=${PAGE_SIZE}
NINJA_MAX_PAGES=200
NINJA_INITIAL_OFFSET=${INITIAL_OFFSET}
NINJA_ADD_ISO=${ADD_ISO}
EOF
chmod 0644 "$CONF_FILE"

# ----------------------------------------------------------------------------
# Collector binary (immutable)
# ----------------------------------------------------------------------------
info "Installing collector to ${BIN}"
unlock_bin
TMP_BIN="$(mktemp /usr/bin/.ninja-collector.XXXXXX)"
{ echo "#!${PYTHON}"; sed '1{/^#!/d}' "$SOURCE"; } > "$TMP_BIN"
"$PYTHON" -c 'import ast,sys; ast.parse(open(sys.argv[1]).read())' "$TMP_BIN" \
    || { rm -f "$TMP_BIN"; die "Collector has syntax errors"; }
chown root:root "$TMP_BIN"; chmod 0755 "$TMP_BIN"
mv -f "$TMP_BIN" "$BIN"
if command -v chattr >/dev/null && chattr +i "$BIN" 2>/dev/null; then
    info "Set immutable flag on ${BIN} ($(lsattr "$BIN" 2>/dev/null | awk '{print $1}'))"
else
    warn "Could not set immutable flag on ${BIN} (chattr missing or filesystem unsupported)"
fi

# ----------------------------------------------------------------------------
# systemd units
# ----------------------------------------------------------------------------
if [[ "$USE_CREDS" == "true" ]]; then
    CRED_LINES="LoadCredential=ninjaone.env:${CRED_FILE}"
    ENV_ARG="%d/ninjaone.env"
else
    CRED_LINES=""
    ENV_ARG="${CRED_FILE}"
fi

# Daily files are never rotated/renamed (the SIEM agent tails them by name);
# old ones are simply deleted after each successful run.
CLEANUP_LINE=""
if (( RETENTION > 0 )); then
    CLEANUP_LINE="ExecStartPost=/usr/bin/find ${LOG_DIR} -maxdepth 1 -type f -name '*.log' -mtime +${RETENTION} -delete"
fi

info "Writing ${UNIT_DIR}/${UNIT_NAME}.service"
cat > "${UNIT_DIR}/${UNIT_NAME}.service" <<EOF
[Unit]
Description=NinjaOne activity log collector
Documentation=file://${BIN}
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
User=${SVC_USER}
Group=${SVC_USER}
EnvironmentFile=${CONF_FILE}
${CRED_LINES}
ExecStart=${BIN} --env-file ${ENV_ARG}
${CLEANUP_LINE}
TimeoutStartSec=15min
UMask=0027

# Hardening
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
ReadWritePaths=${STATE_DIR} ${LOG_DIR}
PrivateTmp=yes
PrivateDevices=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectKernelLogs=yes
ProtectControlGroups=yes
ProtectClock=yes
ProtectHostname=yes
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
RestrictNamespaces=yes
RestrictRealtime=yes
RestrictSUIDSGID=yes
LockPersonality=yes
MemoryDenyWriteExecute=yes
SystemCallArchitectures=native
CapabilityBoundingSet=
EOF

info "Writing ${UNIT_DIR}/${UNIT_NAME}.timer (every ${INTERVAL})"
cat > "${UNIT_DIR}/${UNIT_NAME}.timer" <<EOF
[Unit]
Description=Run the NinjaOne activity log collector every ${INTERVAL}

[Timer]
OnBootSec=1min
OnActiveSec=1min
OnUnitActiveSec=${INTERVAL}
AccuracySec=10s
Unit=${UNIT_NAME}.service

[Install]
WantedBy=timers.target
EOF
chmod 0644 "${UNIT_DIR}/${UNIT_NAME}.service" "${UNIT_DIR}/${UNIT_NAME}.timer"

if command -v systemd-analyze >/dev/null; then
    systemd-analyze verify "${UNIT_DIR}/${UNIT_NAME}.service" "${UNIT_DIR}/${UNIT_NAME}.timer" 2>&1 \
        | grep -v -e 'Documentation=' || true
fi

# ----------------------------------------------------------------------------
# Remove logrotate config from older installs (it would rename the daily files)
# ----------------------------------------------------------------------------
if [[ -f "$LOGROTATE_FILE" ]]; then
    info "Removing old ${LOGROTATE_FILE} (daily files are cleaned up by the service instead)"
    rm -f "$LOGROTATE_FILE"
fi

# ----------------------------------------------------------------------------
# Register + start
# ----------------------------------------------------------------------------
info "Reloading systemd and enabling ${UNIT_NAME}.timer"
systemctl daemon-reload
systemctl enable "${UNIT_NAME}.timer" >/dev/null 2>&1
systemctl restart "${UNIT_NAME}.timer"

if [[ "$START" == "true" ]]; then
    if [[ -s "${STATE_DIR}/last_activity_id" ]]; then
        info "Existing state found (last id $(cat "${STATE_DIR}/last_activity_id")); collecting new activities"
    else
        info "Running first collection (last ${INITIAL_OFFSET} activity IDs)"
    fi
    if systemctl start "${UNIT_NAME}.service"; then
        info "First run succeeded"
    else
        warn "First run failed. Check: journalctl -u ${UNIT_NAME}.service -n 50"
    fi
    journalctl -u "${UNIT_NAME}.service" -n 5 --no-pager -o cat 2>/dev/null || true
fi

echo
info "Installed. Useful commands:"
cat <<EOF
    systemctl list-timers ${UNIT_NAME}.timer      # next/last run
    journalctl -u ${UNIT_NAME}.service -f         # collector output
    tail -f ${LOG_DIR}/\$(date +${LOG_NAME})        # today's collected activities
    sudo systemctl start ${UNIT_NAME}.service     # run now
    sudo $0 --interval 15min -y                   # change interval (re-run installer)
EOF
