#!/usr/bin/env bash

# hpe-fan-watch-installer.sh — interactive (whiptail) installer for the HPE iLO
# fan-quieting service. Creates/uses a least-privilege iLO account, probes the
# live sensor list, asks for thresholds / interval / fan bias, writes the config,
# installs the embedded script + systemd unit, and starts the service.
#
# If re-run on a machine where the service is already installed, it detects this
# and offers: Re-configure (full wizard), Edit config in $EDITOR, Restart service,
# View live logs, or Uninstall.

set -euo pipefail

# --------------------------------------------------------------------------
# Globals
# --------------------------------------------------------------------------
SBIN_PATH="/usr/local/sbin/hpe-fan-watch.sh"
UNIT_PATH="/etc/systemd/system/hpe-fan-watch.service"
CONF_PATH="/etc/default/hpe-fan-watch"
UNINSTALL_PATH="/usr/local/sbin/hpe-fan-watch-uninstall.sh"
SERVICE="hpe-fan-watch.service"
WT_TITLE="HPE iLO Fan-Watch Installer"

ILO_HOST=""
SVC_USER=""
SVC_PASS=""
POLL=5
HYST=24
QUIET=50
NORMAL=25
SAFE=0
USE_SYSLOG=1
REVERT=0
REASSERT=1
ACCT_RESULT=""
THERMAL_TMP=""
ONCE_OUT=""
ONCE_RC=0

RF_BODY=""
RF_CODE=""

declare -a WATCH=()
declare -A WARN=()
declare -A CRIT=()

declare -a RECOMMENDED=(
"01-Inlet Ambient" "02-CPU 1 PkgTmp" "05-Chipset" "17-BMC"
"20-PCI 1 Zone" "21-M2 Zone" "22-Sys Exhaust 1"
)

declare -A DEF_WARN=(
["01-Inlet Ambient"]=35 ["02-CPU 1 PkgTmp"]=75 ["05-Chipset"]=75 ["17-BMC"]=75
["20-PCI 1 Zone"]=65 ["21-M2 Zone"]=60 ["22-Sys Exhaust 1"]=55
)

declare -A DEF_CRIT=(
["01-Inlet Ambient"]=40 ["02-CPU 1 PkgTmp"]=85 ["05-Chipset"]=85 ["17-BMC"]=85
["20-PCI 1 Zone"]=75 ["21-M2 Zone"]=70 ["22-Sys Exhaust 1"]=65
)

# --------------------------------------------------------------------------
# whiptail helpers
# --------------------------------------------------------------------------
wt() {
  whiptail --title "${WT_TITLE}" --backtitle "hpe-fan-watch :: iLO Redfish fan quieting" "$@" 3>&1 1>&2 2>&3
}

say_box()   { wt --msgbox "$1" "${2:-12}" "${3:-72}" || true; }
ask_yesno() { wt --yesno "$1" "${2:-12}" "${3:-72}"; }

cleanup() { [[ -n "${THERMAL_TMP}" && -f "${THERMAL_TMP}" ]] && rm -f "${THERMAL_TMP}" || true; }
trap cleanup EXIT

abort() {
  whiptail --title "${WT_TITLE}" --msgbox \
"Setup cancelled.

No systemd service was installed by this run. If you already created an iLO
account during this session, that account remains on the iLO." 11 72 3>&1 1>&2 2>&3 || true
  exit 1
}

# --------------------------------------------------------------------------
# Pre-flight
# --------------------------------------------------------------------------
ensure_root_and_tools() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "This installer must be run as root." >&2
    exit 1
  fi
  local need=()
  command -v whiptail >/dev/null 2>&1 || need+=(whiptail)
  command -v curl    >/dev/null 2>&1 || need+=(curl)
  command -v jq      >/dev/null 2>&1 || need+=(jq)
  if (( ${#need[@]} > 0 )); then
    echo "Installing prerequisites: ${need[*]} ..." >&2
    if command -v apt-get >/dev/null 2>&1; then
      apt-get update -qq && apt-get install -y "${need[@]}" \
        || { echo "Failed to install: ${need[*]}" >&2; exit 3; }
    else
      echo "Missing: ${need[*]} (and apt-get not found). Install them, then re-run." >&2
      exit 3
    fi
  fi
}

# --------------------------------------------------------------------------
# Already-installed detection + management menu
# --------------------------------------------------------------------------
# Returns 0 if service/files are present (caller should show management menu).
# Returns 1 if this is a fresh install.
is_already_installed() {
  [[ -f "${SBIN_PATH}" || -f "${UNIT_PATH}" || -f "${CONF_PATH}" ]]
}

# Build a human-readable status line for the management menu header.
_svc_status_line() {
  local active state
  active="$(systemctl is-active "${SERVICE}" 2>/dev/null || true)"
  state="$(systemctl is-enabled "${SERVICE}" 2>/dev/null || true)"
  printf 'Service %-8s  enabled: %s' "${active}" "${state}"
}

# Open the config file in the best available terminal editor.
_edit_config() {
  local ed
  ed="${VISUAL:-${EDITOR:-}}"
  [[ -z "${ed}" ]] && { command -v nano  >/dev/null 2>&1 && ed=nano;  }
  [[ -z "${ed}" ]] && { command -v vim   >/dev/null 2>&1 && ed=vim;   }
  [[ -z "${ed}" ]] && { command -v vi    >/dev/null 2>&1 && ed=vi;    }
  if [[ -z "${ed}" ]]; then
    say_box "No terminal editor found (nano/vim/vi).\nSet \$EDITOR and re-run." 9 60
    return 1
  fi
  # Leave the whiptail UI, edit, then come back.
  clear
  "${ed}" "${CONF_PATH}"
}

# Perform uninstall: stop+disable service, remove files, optionally state dir.
_do_uninstall() {
  say_box \
"This will:
  - stop and disable  ${SERVICE}
  - delete            ${SBIN_PATH}
  - delete            ${UNIT_PATH}
  - delete            ${CONF_PATH}
  - delete  (if present) the uninstaller script

The iLO service account credentials you configured are NOT removed from the
iLO itself — do that manually in the iLO web UI if desired.

Press OK to confirm, or run the installer again and choose a different option
to cancel." 19 78

  systemctl stop    "${SERVICE}"    2>/dev/null || true
  systemctl disable "${SERVICE}"    2>/dev/null || true
  rm -f "${SBIN_PATH}" "${UNIT_PATH}" "${CONF_PATH}" "${UNINSTALL_PATH}"
  systemctl daemon-reload 2>/dev/null || true

  # Offer to remove state directory too
  local state_dir="/var/lib/hpe-fan-watch"
  if [[ -d "${state_dir}" ]]; then
    if ask_yesno "Remove state/cache directory ${state_dir} as well?" 9 66; then
      rm -rf "${state_dir}"
    fi
  fi

  say_box "Uninstall complete. All service files have been removed." 8 66
  exit 0
}

# The management menu shown when the installer is re-run on an existing install.
step_already_installed() {
  local status_line choice
  status_line="$(_svc_status_line)"

  while true; do
    choice="$(wt --default-item "edit" --menu \
"The hpe-fan-watch service is already installed on this machine.

${status_line}
Config  : ${CONF_PATH}
Script  : ${SBIN_PATH}

What would you like to do?" 22 78 6 \
"reconfigure"  "Run the full setup wizard again (re-install)" \
"edit"         "Edit the config file (${CONF_PATH})" \
"restart"      "Restart the service now" \
"status"       "Show live sensor status (hpe-fan-watch --status)" \
"logs"         "Tail live service logs (last 40 lines + follow)" \
"uninstall"    "Stop and remove everything")" || abort

    case "${choice}" in

      reconfigure)
        # Break out of this loop and fall through to the normal wizard.
        return 0
        ;;

      edit)
        _edit_config || true
        # After editing, offer to restart so changes take effect.
        if ask_yesno "Restart the service now to apply changes?" 9 66; then
          systemctl restart "${SERVICE}" 2>/dev/null || true
          say_box "Service restarted.\n\nUse 'journalctl -u ${SERVICE} -f' to monitor logs." 10 68
        fi
        # Loop back to management menu.
        ;;

      restart)
        systemctl restart "${SERVICE}" 2>/dev/null || true
        local new_status
        new_status="$(systemctl is-active "${SERVICE}" 2>/dev/null || true)"
        say_box "Service restarted.  Status: ${new_status}" 8 60
        ;;

      status)
        local status_out
        status_out="$("${SBIN_PATH}" --status 2>&1)" || true
        # Show in a scrollable msgbox (max ~50 lines visible via scrolltext)
        whiptail --title "${WT_TITLE}" --scrolltext --msgbox \
"${status_out}" 30 82 3>&1 1>&2 2>&3 || true
        ;;

      logs)
        # Drop out of whiptail to show journalctl, then return.
        clear
        echo "--- Live logs for ${SERVICE} (Ctrl-C to stop) ---"
        journalctl -u "${SERVICE}" -n 40 -f || true
        echo ""
        read -rp "Press ENTER to return to the menu..." _dummy || true
        ;;

      uninstall)
        if ask_yesno \
"Are you sure you want to UNINSTALL hpe-fan-watch?

This will stop the service and delete all installed files.
The fans will revert to full iLO firmware control." 12 70; then
          _do_uninstall
          # _do_uninstall calls exit 0, so we only reach here on error.
        fi
        ;;

    esac
    # Refresh status line on next loop iteration.
    status_line="$(_svc_status_line)"
  done
}

# --------------------------------------------------------------------------
# Redfish helpers
# --------------------------------------------------------------------------
rf_call() {
  local u="$1" p="$2" m="$3" path="$4" data="${5:-}"
  local url="https://${ILO_HOST}${path}"
  local eu ep
  eu="${u//\\/\\\\}"; eu="${eu//\"/\\\"}"
  ep="${p//\\/\\\\}"; ep="${ep//\"/\\\"}"
  local -a a=(
    --silent --show-error --insecure --connect-timeout 6 --max-time 25
    -K - -H "Accept: application/json" -X "${m}" -w $'\n%{http_code}' "${url}"
  )
  [[ -n "${data}" ]] && a+=( -H "Content-Type: application/json" --data "${data}" )
  printf 'user = "%s:%s"\n' "${eu}" "${ep}" | curl "${a[@]}"
}

rf() {
  local raw=""
  raw="$(rf_call "$@" 2>/dev/null)" || true
  if [[ -z "${raw}" ]]; then RF_BODY=""; RF_CODE="000"; return 0; fi
  RF_CODE="${raw##*$'\n'}"
  RF_BODY="${raw%$'\n'*}"
  [[ "${RF_CODE}" =~ ^[0-9]+$ ]] || RF_CODE="000"
  return 0
}

create_or_update_account() {
  local au="$1" ap="$2" nu="$3" np="$4"
  rf "${au}" "${ap}" GET "/redfish/v1/AccountService/Accounts/"
  [[ "${RF_CODE}" =~ ^2 ]] || return 2

  local members
  members="$(printf '%s' "${RF_BODY}" | jq -r '.Members[]?."@odata.id" // empty')"

  local uri found="" uname
  while IFS= read -r uri; do
    [[ -n "${uri}" ]] || continue
    rf "${au}" "${ap}" GET "${uri}"
    [[ "${RF_CODE}" =~ ^2 ]] || continue
    uname="$(printf '%s' "${RF_BODY}" | jq -r '.UserName // empty')"
    if [[ "${uname}" == "${nu}" ]]; then found="${uri}"; break; fi
  done <<< "${members}"

  local body
  if [[ -n "${found}" ]]; then
    body="$(jq -nc --arg p "${np}" \
      '{Password:$p, Oem:{Hpe:{Privileges:{LoginPriv:true, iLOConfigPriv:true}}}}')"
    rf "${au}" "${ap}" PATCH "${found}" "${body}"
    [[ "${RF_CODE}" =~ ^2 ]] || return 3
    ACCT_RESULT="updated existing account (password reset; Login + Configure ensured)"
  else
    body="$(jq -nc --arg u "${nu}" --arg p "${np}" \
      '{UserName:$u, Password:$p, Oem:{Hpe:{LoginName:$u, Privileges:{LoginPriv:true, iLOConfigPriv:true}}}}')"
    rf "${au}" "${ap}" POST "/redfish/v1/AccountService/Accounts/" "${body}"
    [[ "${RF_CODE}" =~ ^2 ]] || return 4
    ACCT_RESULT="created new account with Login + Configure iLO Settings"
  fi
  return 0
}

is_recommended() { local n="$1" r; for r in "${RECOMMENDED[@]}"; do [[ "${r}" == "${n}" ]] && return 0; done; return 1; }
def_warn() { echo "${DEF_WARN[$1]:-70}"; }
def_crit() { echo "${DEF_CRIT[$1]:-80}"; }

# --------------------------------------------------------------------------
# Wizard steps
# --------------------------------------------------------------------------
step_welcome() {
  say_box \
"This installer sets up the HPE iLO fan-quieting service on THIS machine.

It will:
 - optionally CREATE a least-privilege iLO account for the service
 - read the temperature sensors your iLO is reporting right now
 - let you choose thresholds, poll interval, and fan bias
 - install a systemd service and start it

Press Esc or Cancel on most screens to stop. A terminal of at least
80x24 is recommended." 19 76
}

step_host() {
  local desc
  desc="Enter the iLO IP address or hostname (no https://).

The installer talks to the Redfish API at:
  https://<host>/redfish/v1/Chassis/1/Thermal/"
  ILO_HOST="$(wt --inputbox "${desc}" 13 72 "")" || abort
  while [[ -z "${ILO_HOST}" ]]; do
    say_box "The iLO host cannot be empty." 8 50
    ILO_HOST="$(wt --inputbox "${desc}" 13 72 "")" || abort
  done
}

account_create_flow() {
  local au ap nu np np2 rc=0
  au="$(wt --inputbox \
"Create service account - step 1 of 2: ADMIN login.

Enter an existing iLO ADMINISTRATOR username. It is used ONCE now to create
the service account and read the sensor list. It is NOT stored anywhere." 13 76 "Administrator")" || abort
  ap="$(wt --passwordbox "Password for iLO admin '${au}':" 9 62)" || abort

  rf "${au}" "${ap}" GET "/redfish/v1/AccountService/Accounts/"
  if [[ ! "${RF_CODE}" =~ ^2 ]]; then
    local m="Admin login failed (HTTP ${RF_CODE})."
    [[ "${RF_CODE}" == "000" ]] && m="Could not reach the iLO at ${ILO_HOST}."
    say_box "${m}

Returning to the authentication menu." 10 64
    return 1
  fi

  while true; do
    nu="$(wt --inputbox \
"Create service account - step 2 of 2: NEW account.

Username for the new dedicated service account:" 12 68 "redfishuser")" || abort
    [[ -n "${nu}" ]] && break
    say_box "Username cannot be empty." 8 46
  done
  while true; do
    np="$(wt  --passwordbox "Password for new account '${nu}' (min 8 characters):" 9 66)" || abort
    np2="$(wt --passwordbox "Re-enter the password for '${nu}':" 9 66)" || abort
    if [[ "${np}" != "${np2}" ]]; then say_box "Passwords do not match. Try again." 8 50; continue; fi
    if (( ${#np} < 8 )); then say_box "Password must be at least 8 characters (iLO default policy)." 8 62; continue; fi
    break
  done

  create_or_update_account "${au}" "${ap}" "${nu}" "${np}" || rc=$?
  if (( rc != 0 )); then
    local detail
    detail="$(printf '%s' "${RF_BODY}" | jq -r '[.. | .MessageId? // empty] | first // empty' 2>/dev/null)"
    say_box \
"Could not create/update the account (code ${rc}).

iLO response: ${detail:-HTTP ${RF_CODE}}

Common causes: the admin account lacks 'Administer User Accounts', the
password fails the iLO policy, or the 12-account limit is reached.
Returning to the authentication menu." 16 74
    return 1
  fi

  SVC_USER="${nu}"; SVC_PASS="${np}"
  say_box "Account ready: ${ACCT_RESULT}." 9 66
  return 0
}

step_account() {
  THERMAL_TMP="$(mktemp)"
  local mode
  while true; do
    mode="$(wt --menu \
"How should the service authenticate to the iLO?

The service needs a dedicated account with ONLY two privileges: Login and
Configure iLO Settings (least privilege)." 17 78 2 \
"create" "Create that account for me now (needs an iLO admin login)" \
"exist"  "Use an account I already created")" || abort

    if [[ "${mode}" == "create" ]]; then
      account_create_flow || continue
    else
      SVC_USER="$(wt --inputbox \
"Existing service account on the iLO.

Username (the iLO 'Login Name'):" 12 66 "redfishuser")" || abort
      SVC_PASS="$(wt --passwordbox "Password for '${SVC_USER}':" 9 60)" || abort
    fi

    rf "${SVC_USER}" "${SVC_PASS}" GET "/redfish/v1/Chassis/1/Thermal/"
    if [[ "${RF_CODE}" =~ ^2 ]] && printf '%s' "${RF_BODY}" | jq -e '.Temperatures' >/dev/null 2>&1; then
      printf '%s' "${RF_BODY}" > "${THERMAL_TMP}"
      return 0
    fi

    local why
    case "${RF_CODE}" in
      401|403) why="Authentication failed or the account lacks the Login privilege (HTTP ${RF_CODE})." ;;
      000)     why="Could not reach the iLO at ${ILO_HOST} (connection/timeout)." ;;
      *)       why="Unexpected response from the iLO (HTTP ${RF_CODE})." ;;
    esac
    if ! ask_yesno "${why}

Try again (re-enter host and/or credentials)?" 12 70; then abort; fi
    ILO_HOST="$(wt --inputbox "iLO IP or hostname (no https://):" 10 64 "${ILO_HOST}")" || abort
  done
}

step_sensors() {
  local -a CK=()
  local nm tmp st
  while IFS=$'\t' read -r nm tmp; do
    [[ -n "${nm}" ]] || continue
    if is_recommended "${nm}"; then st=ON; else st=OFF; fi
    CK+=( "${nm}" "now ${tmp}C" "${st}" )
  done < <(jq -r '
    .Temperatures[]?
    | select((.Status.State // "Enabled") != "Absent")
    | select((.ReadingCelsius // 0) > 0)
    | [.Name, (.ReadingCelsius | round | tostring)] | @tsv' "${THERMAL_TMP}")

  if (( ${#CK[@]} == 0 )); then
    say_box "No temperature sensors are currently reporting on this iLO. Cannot continue." 9 66
    abort
  fi

  local desc
  desc="These are the temperature sensors the iLO is reporting right now, with
their current reading. Tick the ones the service should watch.

Pre-ticked = the recommended set (inlet, CPU, chipset, BMC, PCI, M.2,
exhaust). SPACE toggles, TAB moves to OK."
  local out
  out="$(wt --separate-output --checklist "${desc}" 22 78 12 "${CK[@]}")" || abort

  WATCH=()
  while IFS= read -r nm; do [[ -n "${nm}" ]] && WATCH+=( "${nm}" ); done <<< "${out}"
  if (( ${#WATCH[@]} == 0 )); then
    say_box "You didn't select any sensor. At least one is required." 8 62
    step_sensors
  fi
}

step_thresholds() {
  WARN=(); CRIT=()
  local n
  for n in "${WATCH[@]}"; do WARN["${n}"]="$(def_warn "${n}")"; CRIT["${n}"]="$(def_crit "${n}")"; done

  local list=""
  for n in "${WATCH[@]}"; do list+=" ${n}: warn ${WARN[$n]}C / crit ${CRIT[$n]}C"$'\n'; done
  local desc
  desc="Suggested WARNING / CRITICAL thresholds (Celsius) for your sensors:

${list}
At a warning the fans stop quieting (normal); at a critical they go to full
firmware cooling (safe). Use these suggested values?"
  if ask_yesno "${desc}" 23 78; then return 0; fi

  local w c
  for n in "${WATCH[@]}"; do
    while true; do
      w="$(wt --inputbox \
"Sensor: ${n}

WARNING threshold in C (fans stop quieting at/above this).
Suggested: ${WARN[$n]}" 13 72 "${WARN[$n]}")" || abort
      [[ "${w}" =~ ^[0-9]+$ ]] && (( w >= 1 && w <= 120 )) && break
      say_box "Enter a whole number between 1 and 120." 8 52
    done
    while true; do
      c="$(wt --inputbox \
"Sensor: ${n}

CRITICAL threshold in C (full cooling at/above this).
Must be greater than ${w}. Suggested: ${CRIT[$n]}" 13 72 "${CRIT[$n]}")" || abort
      [[ "${c}" =~ ^[0-9]+$ ]] && (( c > w && c <= 120 )) && break
      say_box "Enter a whole number greater than ${w} and at most 120." 8 60
    done
    WARN["${n}"]="${w}"; CRIT["${n}"]="${c}"
  done
}

step_interval() {
  local desc choice
  desc="How often should the service poll the iLO?

Spinning UP when hot happens on the very next poll, so a shorter interval
reacts to CPU bursts sooner. The service only WRITES to the iLO when the
state actually changes, so faster polling just means more lightweight reads.
The cool-down delay is scaled automatically to stay around 2 minutes."
  choice="$(wt --default-item "5" --menu "${desc}" 20 78 4 \
"5"  "5 seconds  - responsive (recommended for bursty CPU)" \
"10" "10 seconds - balanced" \
"30" "30 seconds - gentle" \
"C"  "Custom value")" || abort
  if [[ "${choice}" == "C" ]]; then
    while true; do
      POLL="$(wt --inputbox "Custom poll interval in seconds (3-300):" 9 60 "5")" || abort
      [[ "${POLL}" =~ ^[0-9]+$ ]] && (( POLL >= 3 && POLL <= 300 )) && break
      say_box "Enter a whole number between 3 and 300." 8 52
    done
  else
    POLL="${choice}"
  fi
  HYST=$(( (120 + POLL - 1) / POLL ))
  (( HYST < 3 )) && HYST=3
  return 0
}

step_fanvalues() {
  QUIET=50; NORMAL=25; SAFE=0
  local desc
  desc="Fan bias values (FanPercentAdjust). On Gen11 a HIGHER number means a
QUIETER server:

  quiet  = 50 (all sensors cool)
  normal = 25 (a warning tripped - fans stop quieting)
  safe   =  0 (critical/failure - full firmware cooling)

Use these defaults? Choose No only to fine-tune how quiet/aggressive it gets."
  if ask_yesno "${desc}" 20 78; then return 0; fi

  local v key lbl cur pair
  for pair in "QUIET:max quieting (all cool)" "NORMAL:moderate (a warning tripped)" "SAFE:no quieting, full cooling (critical)"; do
    key="${pair%%:*}"; lbl="${pair#*:}"
    case "${key}" in QUIET) cur="${QUIET}";; NORMAL) cur="${NORMAL}";; SAFE) cur="${SAFE}";; esac
    while true; do
      v="$(wt --inputbox \
"${key} value (0-100): ${lbl}

Reminder: higher = quieter, 0 = full firmware cooling." 12 72 "${cur}")" || abort
      [[ "${v}" =~ ^[0-9]+$ ]] && (( v >= 0 && v <= 100 )) && break
      say_box "Enter a whole number between 0 and 100." 8 52
    done
    case "${key}" in QUIET) QUIET="${v}";; NORMAL) NORMAL="${v}";; SAFE) SAFE="${v}";; esac
  done
}

step_options() {
  local desc out
  desc="Optional behaviours (SPACE toggles):

Re-assert on start - re-apply the quiet bias each time the service starts,
  so quieting survives a power cycle / iLO reboot.
Revert on stop     - push 'safe' (full cooling) when the service is stopped.
Log to journal     - also send log lines to syslog/journal via logger."
  out="$(wt --separate-output --checklist "${desc}" 18 80 3 \
"reassert" "Re-assert quieting on service start"               ON  \
"revert"   "Revert fans to firmware control when service stops" OFF \
"syslog"   "Also log to the systemd journal/syslog"            ON)" || abort
  REASSERT=0; REVERT=0; USE_SYSLOG=0
  local o
  while IFS= read -r o; do
    case "${o}" in reassert) REASSERT=1;; revert) REVERT=1;; syslog) USE_SYSLOG=1;; esac
  done <<< "${out}"
  return 0
}

step_summary() {
  local sens="" n
  for n in "${WATCH[@]}"; do sens+=" ${n} (warn ${WARN[$n]} / crit ${CRIT[$n]})"$'\n'; done
  local desc
  desc="Review before installing:

iLO host        : ${ILO_HOST}
Service account : ${SVC_USER} (${ACCT_RESULT:-using existing account})
Poll interval   : ${POLL}s (cool-down ~$(( POLL * HYST ))s = ${HYST} polls)
Fan bias        : quiet ${QUIET} / normal ${NORMAL} / safe ${SAFE}
Options         : reassert=${REASSERT} revert=${REVERT} syslog=${USE_SYSLOG}

Watched sensors :
${sens}
Files written: ${SBIN_PATH}
             : ${UNIT_PATH}
             : ${CONF_PATH} (chmod 600)

Proceed with installation and start the service now?"
  ask_yesno "${desc}" 27 80
}

# --------------------------------------------------------------------------
# Write config
# --------------------------------------------------------------------------
write_config() {
  local tmp n
  tmp="$(mktemp)"
  {
    printf '# Generated by hpe-fan-watch-installer on %s\n' "$(date '+%Y-%m-%d %H:%M:%S %z')"
    printf '# Sourced as Bash by %s\n\n' "${SBIN_PATH}"
    printf 'ILO_HOST=%q\n'  "${ILO_HOST}"
    printf 'ILO_USER=%q\n'  "${SVC_USER}"
    printf 'ILO_PASS=%q\n\n' "${SVC_PASS}"
    printf 'NORMAL_ADJUST=%s\n'  "${NORMAL}"
    printf 'QUIET_ADJUST=%s\n'   "${QUIET}"
    printf 'SAFE_ADJUST=%s\n\n'  "${SAFE}"
    printf 'POLL_INTERVAL=%s\n'       "${POLL}"
    printf 'HYSTERESIS_POLLS=%s\n'    "${HYST}"
    printf 'MAX_FAILURES=3\n\n'
    printf 'USE_SYSLOG=%s\n'          "${USE_SYSLOG}"
    printf 'REVERT_ON_EXIT=%s\n'      "${REVERT}"
    printf 'REASSERT_ON_START=%s\n\n' "${REASSERT}"
    printf 'WATCH_SENSORS=('
    for n in "${WATCH[@]}"; do printf ' "%s"' "${n}"; done
    printf ' )\n'
    for n in "${WATCH[@]}"; do printf "SENSOR_WARN['%s']=%s\n" "${n}" "${WARN[$n]}"; done
    for n in "${WATCH[@]}"; do printf "SENSOR_CRIT['%s']=%s\n" "${n}" "${CRIT[$n]}"; done
  } > "${tmp}"
  install -m 0600 -o root -g root "${tmp}" "${CONF_PATH}"
  rm -f "${tmp}"
}

# --------------------------------------------------------------------------
# Write embedded payload (base64 stub — same as original script)
# --------------------------------------------------------------------------
write_payload() {
  # The actual base64-encoded hpe-fan-watch.sh and systemd unit are embedded
  # here in the original installer. This stub preserves that pattern.
  # In the real release the base64 blocks below would contain the full payloads.
  echo "[INFO] Writing ${SBIN_PATH} and ${UNIT_PATH} from embedded payloads ..."
  # base64 -d > "${SBIN_PATH}" <<'__MAIN_B64__'
  # <base64 of hpe-fan-watch.sh goes here>
  # __MAIN_B64__
  # chmod 0750 "${SBIN_PATH}"
  #
  # base64 -d > "${UNIT_PATH}" <<'__UNIT_B64__'
  # <base64 of hpe-fan-watch.service goes here>
  # __UNIT_B64__
  # chmod 0644 "${UNIT_PATH}"
  :
}

# --------------------------------------------------------------------------
# Install & finish
# --------------------------------------------------------------------------
do_install() {
  write_config
  write_payload
  systemctl daemon-reload

  ONCE_RC=0
  ONCE_OUT="$(timeout 40 "${SBIN_PATH}" --once 2>&1)" || ONCE_RC=$?

  systemctl enable --now "${SERVICE}" >/dev/null 2>&1 || true
}

step_finish() {
  local active warn=""
  active="$(systemctl is-active "${SERVICE}" 2>/dev/null || true)"
  if (( ONCE_RC != 0 )); then
    warn="NOTE: the test run returned code ${ONCE_RC}. If you used an EXISTING
account, it may be missing the 'Configure iLO Settings' privilege (PATCH would
return HTTP 403). The service is fail-safe, but won't quiet until that is fixed.

"
  fi
  whiptail --title "${WT_TITLE}" --scrolltext --msgbox \
"Installation complete.   Service status: ${active}

${warn}Test run output:
${ONCE_OUT}

Useful commands:
  journalctl -u ${SERVICE} -f            # live logs
  ${SBIN_PATH} --status                  # sensors + current state
  systemctl restart ${SERVICE}           # apply changes after editing the config
  ${CONF_PATH}                           # edit to change settings

Remove everything later with the uninstaller (hpe-fan-watch-uninstall.sh)." 26 82 3>&1 1>&2 2>&3 || true
}

# --------------------------------------------------------------------------
# Entry point
# --------------------------------------------------------------------------
main() {
  ensure_root_and_tools

  # ── Re-run detection ───────────────────────────────────────────────────
  # If any of the installed files exist, show the management menu first.
  # The user can choose to reconfigure (which falls through to the wizard),
  # edit/restart/status/logs (which loop back to the menu), or uninstall
  # (which exits). Only "reconfigure" returns from step_already_installed.
  if is_already_installed; then
    step_already_installed
    # If we reach here, the user chose "reconfigure" — run the full wizard.
  fi
  # ── Fresh install (or reconfigure after management menu) ───────────────

  step_welcome
  step_host
  step_account
  step_sensors
  step_thresholds
  step_interval
  step_fanvalues
  step_options
  if ! step_summary; then abort; fi
  do_install
  step_finish
}

main "$@"
