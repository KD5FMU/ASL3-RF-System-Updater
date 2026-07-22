#!/bin/bash
#
# ASL3 RF System Updater Installer
# Debian 12 / Debian 13
#
# Installs three independent RF DTMF commands:
#   *<CHECK>   Check for updates
#   *<APPROVE> Approve and install
#   *<CANCEL>  Cancel pending upgrade
#
# Example:
#   *894 Check
#   *895 Approve
#   *896 Cancel
#

set -Eeuo pipefail

APP_NAME="ASL3 RF System Updater"

INSTALL_DIR="/usr/local/lib/asl3-rf-updater"
WRAPPER_DIR="/usr/local/sbin"
CONFIG_FILE="/etc/asl3-rf-updater.conf"
SUDOERS_FILE="/etc/sudoers.d/asl3-rf-updater"
STATE_DIR="/run/asl3-rf-updater"
LOGFILE="/var/log/asl3-rf-updater.log"
RPT_CONF="/etc/asterisk/rpt.conf"

CHECK_ROOT="${INSTALL_DIR}/check-updates-root"
APPROVE_ROOT="${INSTALL_DIR}/approve-updates-root"
CANCEL_ROOT="${INSTALL_DIR}/cancel-updates-root"

CHECK_WRAPPER="${WRAPPER_DIR}/asl3-rf-update-check"
APPROVE_WRAPPER="${WRAPPER_DIR}/asl3-rf-update-approve"
CANCEL_WRAPPER="${WRAPPER_DIR}/asl3-rf-update-cancel"
UNINSTALLER="${WRAPPER_DIR}/uninstall-asl3-rf-updater"

RPT_BACKUP=""

die() {
    echo
    echo "ERROR: $*" >&2
    exit 1
}

info() {
    echo
    echo "==> $*"
}

require_root() {
    [[ ${EUID} -eq 0 ]] ||
        die "Run this installer with sudo or as root."
}

validate_system() {
    [[ -f /etc/debian_version ]] ||
        die "This installer is intended for Debian-based ASL3 systems."

    command -v apt-get >/dev/null 2>&1 ||
        die "apt-get was not found."

    command -v systemctl >/dev/null 2>&1 ||
        die "systemctl was not found."

    command -v asterisk >/dev/null 2>&1 ||
        die "Asterisk was not found. Is ASL3 installed?"

    id asterisk >/dev/null 2>&1 ||
        die "The asterisk user does not exist."

    [[ -f "$RPT_CONF" ]] ||
        die "$RPT_CONF was not found."
}

install_dependencies() {
    info "Installing required packages"

    export DEBIAN_FRONTEND=noninteractive

    apt-get update
    apt-get install -y asl3-tts util-linux sudo python3

    command -v asl-tts >/dev/null 2>&1 ||
        die "asl-tts was not found after installation."
}

detect_nodes() {
    awk '
        /^\[[0-9]+\][[:space:]]*(\([^)]*\))?[[:space:]]*$/ {
            line=$0
            sub(/^\[/, "", line)
            sub(/\].*$/, "", line)
            print line
        }
    ' "$RPT_CONF" | sort -u | paste -sd' ' -
}

prompt_settings() {
    local detected_nodes
    detected_nodes="$(detect_nodes)"

    echo
    echo "$APP_NAME Installer"
    echo "--------------------------------"

    if [[ -n "$detected_nodes" ]]; then
        echo "Detected node stanza(s): $detected_nodes"
    fi

    read -r -p "Node number for RF announcements: " NODE_NUMBER
    [[ "$NODE_NUMBER" =~ ^[0-9]{3,10}$ ]] ||
        die "The node number must contain digits only."

    read -r -p "DTMF command to CHECK for updates [894]: " CHECK_DTMF
    CHECK_DTMF="${CHECK_DTMF:-894}"

    read -r -p "DTMF command to APPROVE upgrade [895]: " APPROVE_DTMF
    APPROVE_DTMF="${APPROVE_DTMF:-895}"

    read -r -p "DTMF command to CANCEL upgrade [896]: " CANCEL_DTMF
    CANCEL_DTMF="${CANCEL_DTMF:-896}"

    read -r -p "Confirmation timeout in seconds [120]: " CONFIRM_TIMEOUT
    CONFIRM_TIMEOUT="${CONFIRM_TIMEOUT:-120}"

    for value in "$CHECK_DTMF" "$APPROVE_DTMF" "$CANCEL_DTMF"; do
        [[ "$value" =~ ^[0-9]{2,8}$ ]] ||
            die "Each DTMF command must contain 2 to 8 numeric digits."
    done

    [[ "$CHECK_DTMF" != "$APPROVE_DTMF" ]] ||
        die "Check and approve commands must be different."

    [[ "$CHECK_DTMF" != "$CANCEL_DTMF" ]] ||
        die "Check and cancel commands must be different."

    [[ "$APPROVE_DTMF" != "$CANCEL_DTMF" ]] ||
        die "Approve and cancel commands must be different."

    # Prevent one command from being the prefix of another.
    for first in "$CHECK_DTMF" "$APPROVE_DTMF" "$CANCEL_DTMF"; do
        for second in "$CHECK_DTMF" "$APPROVE_DTMF" "$CANCEL_DTMF"; do
            [[ "$first" == "$second" ]] && continue

            if [[ "$second" == "$first"* ]]; then
                die "DTMF command $first is a prefix of $second. Choose independent commands."
            fi
        done
    done

    [[ "$CONFIRM_TIMEOUT" =~ ^[0-9]+$ ]] ||
        die "The timeout must be a whole number."

    (( CONFIRM_TIMEOUT >= 30 && CONFIRM_TIMEOUT <= 900 )) ||
        die "Choose a timeout between 30 and 900 seconds."

    echo
    echo "RF commands:"
    echo "  *${CHECK_DTMF}  Check for updates"
    echo "  *${APPROVE_DTMF}  Approve and install"
    echo "  *${CANCEL_DTMF}  Cancel"
    echo "  Timeout: ${CONFIRM_TIMEOUT} seconds"
    echo

    read -r -p "Continue with these settings? [Y/n]: " ANSWER
    ANSWER="${ANSWER:-Y}"

    [[ "$ANSWER" =~ ^[Yy]$ ]] ||
        die "Installation cancelled."
}

find_functions_stanza() {
    local stanza

    stanza="$(
        awk -v node="$NODE_NUMBER" '
            BEGIN { in_node=0 }

            /^\[/ {
                in_node=($0 ~ "^\\[" node "\\]")
            }

            in_node && /^[[:space:]]*functions[[:space:]]*=/ {
                line=$0
                sub(/^[[:space:]]*functions[[:space:]]*=[[:space:]]*/, "", line)
                sub(/[[:space:];#].*$/, "", line)
                print line
                exit
            }
        ' "$RPT_CONF"
    )"

    [[ -n "$stanza" ]] || stanza="functions"

    printf '%s' "$stanza"
}

check_dtmf_conflicts() {
    local stanza="$1"
    local code

    for code in "$CHECK_DTMF" "$APPROVE_DTMF" "$CANCEL_DTMF"; do
        if awk -v target="$stanza" -v code="$code" '
            BEGIN { in_target=0; found=0 }

            /^\[/ {
                section=$0
                sub(/^\[/, "", section)
                sub(/\].*$/, "", section)
                in_target=(section==target)
                next
            }

            in_target {
                line=$0
                sub(/^[[:space:]]*/, "", line)
                if (line ~ "^" code "[[:space:]]*=") {
                    found=1
                    exit
                }
            }

            END { exit found ? 0 : 1 }
        ' "$RPT_CONF"; then
            die "DTMF command $code is already assigned in [$stanza]."
        fi
    done
}

write_config() {
    info "Writing configuration"

    cat > "$CONFIG_FILE" <<EOF
NODE_NUMBER="$NODE_NUMBER"
CHECK_DTMF="$CHECK_DTMF"
APPROVE_DTMF="$APPROVE_DTMF"
CANCEL_DTMF="$CANCEL_DTMF"
CONFIRM_TIMEOUT="$CONFIRM_TIMEOUT"
STATE_DIR="$STATE_DIR"
LOGFILE="$LOGFILE"
EOF

    chown root:root "$CONFIG_FILE"
    chmod 0644 "$CONFIG_FILE"

    touch "$LOGFILE"
    chown root:asterisk "$LOGFILE"
    chmod 0664 "$LOGFILE"
}

write_update_scripts() {
    info "Installing updater programs"

    install -d -o root -g root -m 0755 "$INSTALL_DIR"

    cat > "$CHECK_ROOT" <<'CHECKSCRIPT'
#!/bin/bash
set -Eeuo pipefail

source /etc/asl3-rf-updater.conf

PENDING_FILE="${STATE_DIR}/pending"
LOCKFILE="${STATE_DIR}/apt.lock"
APT_GET="/usr/bin/apt-get"
ASL_TTS="$(command -v asl-tts)"

mkdir -p "$STATE_DIR"
chmod 0755 "$STATE_DIR"

exec >>"$LOGFILE" 2>&1

echo "------------------------------------------------------------"
echo "Update check started: $(date --iso-8601=seconds)"

speak() {
    local text="$1"

    if ! runuser -u asterisk -- "$ASL_TTS" -n "$NODE_NUMBER" -t "$text"; then
        echo "WARNING: TTS failed: $text"
    fi
}

exec 9>"$LOCKFILE"

if ! flock -n 9; then
    speak "Another system update process is already running."
    echo "Update check rejected because the lock is held."
    exit 1
fi

rm -f "$PENDING_FILE"

speak "Updating the system information now."

export DEBIAN_FRONTEND=noninteractive

if ! "$APT_GET" update; then
    speak "The system update check failed. Please examine the update log."
    echo "apt-get update failed."
    exit 1
fi

UPDATE_COUNT="$(
    "$APT_GET" --simulate upgrade 2>/dev/null |
        awk '/^Inst / {count++} END {print count+0}'
)"

if ! [[ "$UPDATE_COUNT" =~ ^[0-9]+$ ]]; then
    speak "I could not determine the number of available updates."
    echo "Invalid update count: $UPDATE_COUNT"
    exit 1
fi

echo "Available upgrades: $UPDATE_COUNT"

if (( UPDATE_COUNT == 0 )); then
    speak "The system is already up to date. No upgrades are available."
    echo "No upgrades are available."
    exit 0
fi

REQUEST_TIME="$(date +%s)"

cat > "$PENDING_FILE" <<EOF
REQUEST_TIME=$REQUEST_TIME
UPDATE_COUNT=$UPDATE_COUNT
EOF

chown root:root "$PENDING_FILE"
chmod 0600 "$PENDING_FILE"

if (( UPDATE_COUNT == 1 )); then
    COUNT_WORDING="There is 1 update available."
else
    COUNT_WORDING="There are $UPDATE_COUNT updates available."
fi

speak "$COUNT_WORDING To proceed, enter D T M F star ${APPROVE_DTMF}. To cancel, enter D T M F star ${CANCEL_DTMF}. You have ${CONFIRM_TIMEOUT} seconds to respond."

echo "Pending request created at $REQUEST_TIME."
echo "Update check finished: $(date --iso-8601=seconds)"
CHECKSCRIPT

    cat > "$APPROVE_ROOT" <<'APPROVESCRIPT'
#!/bin/bash
set -Eeuo pipefail

source /etc/asl3-rf-updater.conf

PENDING_FILE="${STATE_DIR}/pending"
LOCKFILE="${STATE_DIR}/apt.lock"
APT_GET="/usr/bin/apt-get"
ASL_TTS="$(command -v asl-tts)"

mkdir -p "$STATE_DIR"
chmod 0755 "$STATE_DIR"

exec >>"$LOGFILE" 2>&1

echo "------------------------------------------------------------"
echo "Upgrade approval received: $(date --iso-8601=seconds)"

speak() {
    local text="$1"

    if ! runuser -u asterisk -- "$ASL_TTS" -n "$NODE_NUMBER" -t "$text"; then
        echo "WARNING: TTS failed: $text"
    fi
}

if [[ ! -f "$PENDING_FILE" ]]; then
    speak "There is no pending system upgrade request."
    echo "Approval rejected because no request is pending."
    exit 1
fi

REQUEST_TIME="$(
    awk -F= '$1=="REQUEST_TIME" {print $2}' "$PENDING_FILE"
)"

UPDATE_COUNT="$(
    awk -F= '$1=="UPDATE_COUNT" {print $2}' "$PENDING_FILE"
)"

if ! [[ "$REQUEST_TIME" =~ ^[0-9]+$ && "$UPDATE_COUNT" =~ ^[0-9]+$ ]]; then
    rm -f "$PENDING_FILE"
    speak "The pending upgrade request was invalid and has been cancelled."
    echo "Invalid pending request."
    exit 1
fi

CURRENT_TIME="$(date +%s)"
REQUEST_AGE=$((CURRENT_TIME - REQUEST_TIME))

if (( REQUEST_AGE < 0 || REQUEST_AGE > CONFIRM_TIMEOUT )); then
    rm -f "$PENDING_FILE"
    speak "The upgrade confirmation time has expired. Please check for updates again."
    echo "Approval expired after ${REQUEST_AGE} seconds."
    exit 1
fi

exec 9>"$LOCKFILE"

if ! flock -n 9; then
    speak "Another system update process is already running."
    echo "Upgrade rejected because the lock is held."
    exit 1
fi

# Consume the request before installing so it cannot be approved twice.
rm -f "$PENDING_FILE"

if (( UPDATE_COUNT == 1 )); then
    speak "Approval received. Installing 1 available update now."
else
    speak "Approval received. Installing $UPDATE_COUNT available updates now."
fi

export DEBIAN_FRONTEND=noninteractive

if "$APT_GET" upgrade -y; then
    if [[ -f /var/run/reboot-required ]]; then
        speak "The system upgrade completed successfully. A reboot is required."
        echo "Upgrade completed successfully. Reboot required."
    else
        speak "The system upgrade completed successfully. No reboot is currently required."
        echo "Upgrade completed successfully. No reboot required."
    fi
else
    RESULT=$?
    speak "The system upgrade encountered an error. Please examine the update log."
    echo "apt-get upgrade failed with exit status $RESULT."
    exit "$RESULT"
fi

echo "Upgrade process finished: $(date --iso-8601=seconds)"
APPROVESCRIPT

    cat > "$CANCEL_ROOT" <<'CANCELSCRIPT'
#!/bin/bash
set -Eeuo pipefail

source /etc/asl3-rf-updater.conf

PENDING_FILE="${STATE_DIR}/pending"
ASL_TTS="$(command -v asl-tts)"

mkdir -p "$STATE_DIR"
chmod 0755 "$STATE_DIR"

exec >>"$LOGFILE" 2>&1

echo "------------------------------------------------------------"
echo "Upgrade cancellation received: $(date --iso-8601=seconds)"

speak() {
    local text="$1"

    if ! runuser -u asterisk -- "$ASL_TTS" -n "$NODE_NUMBER" -t "$text"; then
        echo "WARNING: TTS failed: $text"
    fi
}

if [[ -f "$PENDING_FILE" ]]; then
    rm -f "$PENDING_FILE"
    speak "Upgrade halted. No updates were installed."
    echo "Pending request cancelled."
else
    speak "There is no pending system upgrade request to cancel."
    echo "Cancellation received with no pending request."
fi
CANCELSCRIPT

    chown root:root "$CHECK_ROOT" "$APPROVE_ROOT" "$CANCEL_ROOT"
    chmod 0750 "$CHECK_ROOT" "$APPROVE_ROOT" "$CANCEL_ROOT"
}

write_wrappers() {
    info "Installing Asterisk wrappers"

    cat > "$CHECK_WRAPPER" <<EOF
#!/bin/bash
exec /usr/bin/sudo -n "$CHECK_ROOT"
EOF

    cat > "$APPROVE_WRAPPER" <<EOF
#!/bin/bash
exec /usr/bin/sudo -n "$APPROVE_ROOT"
EOF

    cat > "$CANCEL_WRAPPER" <<EOF
#!/bin/bash
exec /usr/bin/sudo -n "$CANCEL_ROOT"
EOF

    chown root:asterisk "$CHECK_WRAPPER" "$APPROVE_WRAPPER" "$CANCEL_WRAPPER"
    chmod 0750 "$CHECK_WRAPPER" "$APPROVE_WRAPPER" "$CANCEL_WRAPPER"
}

write_sudoers() {
    info "Adding restricted sudo permissions"

    cat > "$SUDOERS_FILE" <<EOF
asterisk ALL=(root) NOPASSWD: $CHECK_ROOT
asterisk ALL=(root) NOPASSWD: $APPROVE_ROOT
asterisk ALL=(root) NOPASSWD: $CANCEL_ROOT
EOF

    chown root:root "$SUDOERS_FILE"
    chmod 0440 "$SUDOERS_FILE"

    visudo -cf "$SUDOERS_FILE" >/dev/null ||
        die "The generated sudoers file failed validation."
}

add_dtmf_commands() {
    local stanza
    local temp

    stanza="$(find_functions_stanza)"

    info "Adding commands to [$stanza]"

    grep -qE "^[[:space:]]*\[$stanza\]" "$RPT_CONF" ||
        die "The functions stanza [$stanza] was not found."

    check_dtmf_conflicts "$stanza"

    RPT_BACKUP="${RPT_CONF}.asl3-rf-updater.$(date +%Y%m%d-%H%M%S)"
    cp -a "$RPT_CONF" "$RPT_BACKUP"

    temp="$(mktemp)"

    awk \
        -v target="$stanza" \
        -v check_code="$CHECK_DTMF" \
        -v approve_code="$APPROVE_DTMF" \
        -v cancel_code="$CANCEL_DTMF" \
        -v check_script="$CHECK_WRAPPER" \
        -v approve_script="$APPROVE_WRAPPER" \
        -v cancel_script="$CANCEL_WRAPPER" '
        BEGIN {
            inserted=0
            in_target=0
        }

        /^\[/ {
            section=$0
            sub(/^\[/, "", section)
            sub(/\].*$/, "", section)

            if (in_target && !inserted) {
                print ""
                print "; ASL3 RF system updater"
                print check_code "=cmd," check_script
                print approve_code "=cmd," approve_script
                print cancel_code "=cmd," cancel_script
                inserted=1
            }

            in_target=(section==target)
        }

        { print }

        END {
            if (in_target && !inserted) {
                print ""
                print "; ASL3 RF system updater"
                print check_code "=cmd," check_script
                print approve_code "=cmd," approve_script
                print cancel_code "=cmd," cancel_script
            }
        }
    ' "$RPT_CONF" > "$temp"

    cat "$temp" > "$RPT_CONF"
    rm -f "$temp"

    chown --reference="$RPT_BACKUP" "$RPT_CONF"
    chmod --reference="$RPT_BACKUP" "$RPT_CONF"

    echo "rpt.conf backup: $RPT_BACKUP"
}

write_uninstaller() {
    info "Installing uninstaller"

    cat > "$UNINSTALLER" <<'UNINSTALL'
#!/bin/bash
set -Eeuo pipefail

[[ ${EUID} -eq 0 ]] || {
    echo "Run this uninstaller with sudo or as root." >&2
    exit 1
}

CONFIG_FILE="/etc/asl3-rf-updater.conf"
RPT_CONF="/etc/asterisk/rpt.conf"

if [[ -f "$CONFIG_FILE" ]]; then
    source "$CONFIG_FILE"

    if [[ -f "$RPT_CONF" ]]; then
        sed -i \
            -e "/^[[:space:]]*${CHECK_DTMF}[[:space:]]*=cmd,\/usr\/local\/sbin\/asl3-rf-update-check[[:space:]]*$/d" \
            -e "/^[[:space:]]*${APPROVE_DTMF}[[:space:]]*=cmd,\/usr\/local\/sbin\/asl3-rf-update-approve[[:space:]]*$/d" \
            -e "/^[[:space:]]*${CANCEL_DTMF}[[:space:]]*=cmd,\/usr\/local\/sbin\/asl3-rf-update-cancel[[:space:]]*$/d" \
            -e "/^[[:space:]]*; ASL3 RF system updater[[:space:]]*$/d" \
            "$RPT_CONF"
    fi
fi

rm -f \
    /usr/local/sbin/asl3-rf-update-check \
    /usr/local/sbin/asl3-rf-update-approve \
    /usr/local/sbin/asl3-rf-update-cancel \
    /etc/sudoers.d/asl3-rf-updater \
    /etc/asl3-rf-updater.conf

rm -rf \
    /usr/local/lib/asl3-rf-updater \
    /run/asl3-rf-updater

systemctl restart asterisk

echo "ASL3 RF System Updater was removed."
echo "The log was retained at /var/log/asl3-rf-updater.log."

rm -f -- "$0"
UNINSTALL

    chown root:root "$UNINSTALLER"
    chmod 0750 "$UNINSTALLER"
}

validate_installation() {
    info "Validating installation"

    visudo -cf "$SUDOERS_FILE" >/dev/null ||
        die "Sudoers validation failed."

    grep -qE "^[[:space:]]*${CHECK_DTMF}[[:space:]]*=cmd,${CHECK_WRAPPER}[[:space:]]*$" "$RPT_CONF" ||
        die "The check command was not added correctly."

    grep -qE "^[[:space:]]*${APPROVE_DTMF}[[:space:]]*=cmd,${APPROVE_WRAPPER}[[:space:]]*$" "$RPT_CONF" ||
        die "The approve command was not added correctly."

    grep -qE "^[[:space:]]*${CANCEL_DTMF}[[:space:]]*=cmd,${CANCEL_WRAPPER}[[:space:]]*$" "$RPT_CONF" ||
        die "The cancel command was not added correctly."

    sudo -u asterisk sudo -n "$CHECK_ROOT" --help >/dev/null 2>&1 || true
}

restart_asterisk() {
    info "Restarting Asterisk"

    if ! systemctl restart asterisk; then
        if [[ -n "$RPT_BACKUP" && -f "$RPT_BACKUP" ]]; then
            cp -a "$RPT_BACKUP" "$RPT_CONF"
            systemctl restart asterisk || true
        fi

        die "Asterisk failed to restart. rpt.conf was restored."
    fi

    systemctl is-active --quiet asterisk ||
        die "Asterisk is not active after restart."
}

rollback() {
    local status=$?

    echo
    echo "Installation failed with status $status." >&2

    if [[ -n "$RPT_BACKUP" && -f "$RPT_BACKUP" ]]; then
        echo "Restoring $RPT_CONF from backup." >&2
        cp -a "$RPT_BACKUP" "$RPT_CONF"
        systemctl restart asterisk >/dev/null 2>&1 || true
    fi

    exit "$status"
}

show_summary() {
    echo
    echo "============================================================"
    echo " $APP_NAME installed successfully"
    echo "============================================================"
    echo
    echo "Node:              $NODE_NUMBER"
    echo "Check updates:     *${CHECK_DTMF}"
    echo "Approve upgrade:   *${APPROVE_DTMF}"
    echo "Cancel upgrade:    *${CANCEL_DTMF}"
    echo "Response timeout:  ${CONFIRM_TIMEOUT} seconds"
    echo
    echo "Log file:"
    echo "  $LOGFILE"
    echo
    echo "Watch the log:"
    echo "  sudo tail -f $LOGFILE"
    echo
    echo "Uninstall:"
    echo "  sudo $UNINSTALLER"
    echo
}

main() {
    require_root
    validate_system
    prompt_settings

    trap rollback ERR

    install_dependencies
    write_config
    write_update_scripts
    write_wrappers
    write_sudoers
    add_dtmf_commands
    write_uninstaller
    validate_installation
    restart_asterisk

    trap - ERR

    show_summary
}

main "$@"
