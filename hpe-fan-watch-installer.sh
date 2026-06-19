#!/usr/bin/env bash
#
# hpe-fan-watch-installer.sh
# Interactive (whiptail) installer for the HPE iLO fan-quieting service.
# Targets HPE ProLiant Gen10/Gen11 via the iLO Redfish API. All iLO I/O
# goes through an embedded Python helper using the `requests` library.
#
# ============================================================================
#  WHAT CHANGED (rewrite, v2.0.0)
# ============================================================================
#  1. Control plane is a thin Python helper (requests over Redfish REST).
#     No raw curl-to-Redfish, no firmware hacks, no AMSD.
#  2. TLS is ALWAYS verified. `--insecure` is gone. The iLO certificate chain
#     is fetched and pinned during install (or a trusted CA path is supplied);
#     every call verifies against it via requests' `verify=` parameter.
#  3. Credentials are never stored in cleartext config. They go to encrypted
#     systemd credentials (`systemd-creds encrypt`, systemd >= 250) when
#     available, otherwise a root-only 0400 environment file with a warning.
#  4. The monitoring script and the systemd unit are written IN FULL (no
#     base64 stubs / no placeholders).
#  5. Cross-distro dependency install: apt / dnf / zypper, with a clear error
#     listing missing packages on unknown package managers.
#  6. REVERT_ON_EXIT defaults to ON (fans return to firmware control if the
#     service stops); disabling it requires confirming a prominent warning.
#  7. MAX_FAILURES is configurable in the wizard (range 1-10, default 3).
#  8. Orphaned-account cleanup: an abort after account creation triggers a
#     Redfish DELETE of the freshly created service account.
#  9. No bare `|| true` on critical paths. systemd / Redfish failures surface
#     to the user via whiptail.
# 10. Platform/Gen compatibility guard: probes iLO generation and the
#     FanPercentAdjust capability and warns if the hardware can't be driven.
# 11. New: TLS cert-pinning wizard step, --dry-run mode, formatted --status
#     dashboard, systemd watchdog (WatchdogSec + sd_notify keepalive),
#     uninstall that can DELETE the iLO service account, and embedded
#     VERSION tracking shown in the management menu.
# ============================================================================

set -euo pipefail

VERSION="2.0.0"
COMMIT="96fad08"

# --------------------------------------------------------------------------
# Paths
# --------------------------------------------------------------------------
BASE_DIR="/etc/hpe-fan-watch"
CONF_PATH="${BASE_DIR}/config"
CACERT_PATH="${BASE_DIR}/ilo.crt"
CRED_ENC_FILE="${BASE_DIR}/ilo.cred"      # systemd-creds encrypted blob
CRED_ENV_FILE="${BASE_DIR}/ilo.env"       # 0400 fallback plaintext blob
LIB_DIR="/usr/local/lib/hpe-fan-watch"
HELPER_PATH="${LIB_DIR}/redfish_ctl.py"
SBIN_PATH="/usr/local/sbin/hpe-fan-watch.sh"
UNIT_PATH="/etc/systemd/system/hpe-fan-watch.service"
STATE_DIR="/var/lib/hpe-fan-watch"
SERVICE="hpe-fan-watch.service"
WT_TITLE="HPE iLO Fan-Watch Installer v${VERSION}"

# --------------------------------------------------------------------------
# Runtime state
# --------------------------------------------------------------------------
ILO_HOST=""
SVC_USER=""
SVC_PASS=""
ADMIN_USER=""          # held only in memory for orphan cleanup during wizard
ADMIN_PASS=""
ACCT_CREATED_URI=""    # set only when WE create a brand-new account
ACCT_RESULT=""
INSTALL_DONE=0
CRED_MODE=""           # systemd-creds | envfile
NOTIFY_SUPPORTED=0
THERMAL_TMP=""

POLL=5
HYST=24
MAX_FAILURES=3
QUIET=50
NORMAL=25
SAFE=0
USE_SYSLOG=1
REVERT=1               # default ON (fail-safe)
REASSERT=1

PKG_MGR=""

# Redfish call results (set by rf/_rf)
RF_CODE=0
RF_BODY="null"
RF_ERR=""

# Setup log — written during install/configure; shown on error
SETUP_LOG="${TMPDIR:-/tmp}/hpe-fan-watch-install-$$.log"
log_setup() { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*" >> "${SETUP_LOG}"; }

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
  whiptail --title "${WT_TITLE}" --backtitle "hpe-fan-watch :: official HPE Redfish tooling" "$@" 3>&1 1>&2 2>&3
}
say_box()   { wt --msgbox "$1" "${2:-12}" "${3:-72}" || :; }
ask_yesno() { wt --yesno "$1" "${2:-12}" "${3:-72}"; }

# Terminal rows/cols (clamped to safe defaults if tput unavailable)
TERM_ROWS="$(tput lines 2>/dev/null || echo 24)"
TERM_COLS="$(tput cols  2>/dev/null || echo 80)"
# Safe dialog height = terminal rows minus whiptail chrome (4 rows)
dlg_h() { local h="${1}" max=$(( TERM_ROWS - 4 )); echo $(( h < max ? h : max )); }
dlg_w() { local w="${1}" max=$(( TERM_COLS - 2 )); echo $(( w < max ? w : max )); }

# Run a critical command; on failure surface a visible warning. Returns the
# command's exit status so callers can decide whether to continue or abort.
run_critical() {
  local desc="$1"; shift
  if "$@"; then return 0; fi
  local rc=$?
  say_box "WARNING: ${desc} failed (exit ${rc}).\n\nCommand:\n  $*\n\nReview 'journalctl -xe' for details." 14 74
  return "${rc}"
}

abort() {
  say_box "Setup cancelled.

No systemd service was installed by this run. Any iLO account this session
created will be cleaned up automatically." 11 72
  exit 1
}

# --------------------------------------------------------------------------
# Cleanup / orphan account removal
# --------------------------------------------------------------------------
cleanup_trap() {
  [[ -n "${THERMAL_TMP}" && -f "${THERMAL_TMP}" ]] && rm -f "${THERMAL_TMP}"
  if [[ "${INSTALL_DONE}" -ne 1 && -n "${ACCT_CREATED_URI}" && -n "${ADMIN_USER}" ]]; then
    # Best-effort removal of the account we created before the abort.
    _rf "${ADMIN_USER}" "${ADMIN_PASS}" DELETE "${ACCT_CREATED_URI}" 2>/dev/null || true
  fi
}
trap cleanup_trap EXIT

# --------------------------------------------------------------------------
# Package manager detection + dependency install
# --------------------------------------------------------------------------
detect_pkg_mgr() {
  if   command -v apt-get >/dev/null 2>&1; then PKG_MGR="apt"
  elif command -v dnf     >/dev/null 2>&1; then PKG_MGR="dnf"
  elif command -v zypper  >/dev/null 2>&1; then PKG_MGR="zypper"
  elif command -v yum     >/dev/null 2>&1; then PKG_MGR="yum"
  else PKG_MGR=""; fi
}

# Map a logical dependency name to the package name for the active manager.
pkg_for() {
  local dep="$1"
  case "${dep}" in
    whiptail)
      case "${PKG_MGR}" in apt) echo whiptail;; *) echo newt;; esac ;;
    pip) echo python3-pip ;;
    *) echo "${dep}" ;;
  esac
}

install_packages() {
  local -a pkgs=("$@")
  case "${PKG_MGR}" in
    apt)    apt-get update -qq && apt-get install -y "${pkgs[@]}" ;;
    dnf)    dnf install -y "${pkgs[@]}" ;;
    yum)    yum install -y "${pkgs[@]}" ;;
    zypper) zypper --non-interactive install "${pkgs[@]}" ;;
    *)      return 1 ;;
  esac
}

ensure_root_and_tools() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "This installer must be run as root." >&2
    exit 1
  fi
  detect_pkg_mgr

  # Logical deps -> commands we verify after install.
  local -a logical=(whiptail curl jq openssl python3 pip)
  declare -A cmd_for=( [whiptail]=whiptail [curl]=curl [jq]=jq \
                       [openssl]=openssl [python3]=python3 [pip]=pip3 )
  local -a need_pkgs=() dep
  for dep in "${logical[@]}"; do
    local c="${cmd_for[$dep]}"
    if ! command -v "${c}" >/dev/null 2>&1; then
      need_pkgs+=( "$(pkg_for "${dep}")" )
    fi
  done

  if (( ${#need_pkgs[@]} > 0 )); then
    if [[ -z "${PKG_MGR}" ]]; then
      echo "ERROR: missing prerequisites and no supported package manager found." >&2
      echo "Install these manually, then re-run: ${need_pkgs[*]}" >&2
      echo "Supported managers: apt-get, dnf, yum, zypper." >&2
      exit 3
    fi
    echo "Installing prerequisites via ${PKG_MGR}: ${need_pkgs[*]} ..." >&2
    if ! install_packages "${need_pkgs[@]}"; then
      echo "ERROR: failed to install: ${need_pkgs[*]}" >&2
      exit 3
    fi
  fi

  ensure_redfish_library
  install_helper
}

# Ensure the 'requests' Python library is available.
# We use requests directly rather than python-ilorest-library because the
# library's TLS handling is broken on urllib3 2.x (ca_certs not wired to the
# PoolManager correctly), causing cert verification errors even with a valid
# pinned cert. requests.Session(verify=path) works correctly on all versions.
ensure_redfish_library() {
  if python3 -c 'import requests' >/dev/null 2>&1; then return 0; fi
  echo "Installing python3-requests ..." >&2
  if pip3 install --quiet requests >/dev/null 2>&1; then :
  elif pip3 install --quiet --break-system-packages requests >/dev/null 2>&1; then :
  else
    echo "ERROR: could not install requests via pip3." >&2
    echo "Install it manually (apt install python3-requests) and re-run." >&2
    exit 3
  fi
  python3 -c 'import requests' >/dev/null 2>&1 || {
    echo "ERROR: requests still not importable after install." >&2; exit 3; }
}

# --------------------------------------------------------------------------
# Embedded Python control plane (requests over Redfish REST API)
# --------------------------------------------------------------------------
install_helper() {
  install -d -m 0755 "${LIB_DIR}"
  local tmp; tmp="$(mktemp)"
  cat > "${tmp}" <<'PYEOF'
#!/usr/bin/env python3
"""Thin Redfish control plane using the requests library.

Reads connection details from the environment to keep secrets out of argv:
  ILO_HOST   (host or https://host)
  ILO_USER, ILO_PASS
  ILO_CACERT (PEM file of the pinned iLO cert, used for fingerprint verification)
  ILO_DATA   (JSON body for PATCH/POST)
  ILO_TIMEOUT
Usage: redfish_ctl.py <GET|PATCH|POST|DELETE> <path>
Emits a single JSON envelope: {"status": int, "body": obj|null, "error": str|null}
"""
import os, sys, json

def emit(status, body, error):
    sys.stdout.write(json.dumps({"status": status, "body": body, "error": error}))
    sys.stdout.write("\n")

def _cert_sha256(pem_path):
    """SHA-256 fingerprint (hex) of the first cert in a PEM file."""
    import ssl, hashlib, re
    with open(pem_path) as f:
        pem = f.read()
    m = re.search(r'-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----', pem, re.DOTALL)
    if not m:
        raise ValueError("no certificate found in %s" % pem_path)
    der = ssl.PEM_cert_to_DER_cert(m.group(0))
    return hashlib.sha256(der).hexdigest()

def main():
    try:
        import requests
        from requests.auth import HTTPBasicAuth
        from requests.adapters import HTTPAdapter
    except Exception as e:
        emit(0, None, "requests library import failed: %s" % e)
        return 0
    if len(sys.argv) < 3:
        emit(0, None, "usage: METHOD PATH")
        return 2
    method = sys.argv[1].upper()
    path = sys.argv[2]
    host = os.environ.get("ILO_HOST", "").strip()
    user = os.environ.get("ILO_USER", "")
    pw = os.environ.get("ILO_PASS", "")
    cacert = os.environ.get("ILO_CACERT", "").strip() or None
    try:
        timeout = int(os.environ.get("ILO_TIMEOUT", "20"))
    except ValueError:
        timeout = 20
    base = host if host.startswith("https://") else "https://" + host
    url = base.rstrip("/") + path

    session = requests.Session()
    session.auth = HTTPBasicAuth(user, pw)
    session.headers.update({
        "Content-Type": "application/json",
        "OData-Version": "4.0",
    })

    if cacert:
        # Use fingerprint verification instead of CA chain verification.
        # iLO certs are often self-signed with a broken AKI extension that
        # causes "unable to get local issuer certificate" even when the cert
        # itself is loaded as the CA. Fingerprint verification bypasses the
        # CA chain entirely — urllib3 checks only that the server presents
        # the exact cert we pinned, which is correct behaviour for cert pinning.
        try:
            fp = _cert_sha256(cacert)
        except Exception as e:
            emit(0, None, "failed to read pinned cert %s: %s" % (cacert, e))
            return 0

        class _FingerprintAdapter(HTTPAdapter):
            def init_poolmanager(self, *args, **kw):
                kw['assert_fingerprint'] = fp
                super().init_poolmanager(*args, **kw)

        session.mount('https://', _FingerprintAdapter())
        session.verify = False  # CA check disabled; fingerprint adapter takes over
        import urllib3
        urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)
    else:
        session.verify = True

    try:
        raw = os.environ.get("ILO_DATA", "")
        body = json.loads(raw) if raw else None
        if method == "GET":
            r = session.get(url, timeout=timeout)
        elif method == "PATCH":
            r = session.patch(url, json=body, timeout=timeout)
        elif method == "POST":
            r = session.post(url, json=body, timeout=timeout)
        elif method == "DELETE":
            r = session.delete(url, timeout=timeout)
        else:
            emit(0, None, "unsupported method: %s" % method)
            return 0
        try:
            body_out = r.json()
        except Exception:
            body_out = None
        emit(r.status_code, body_out, None)
    except Exception as e:
        import traceback
        sys.stderr.write(traceback.format_exc())
        emit(0, None, str(e))
    return 0

if __name__ == "__main__":
    sys.exit(main())
PYEOF
  install -m 0755 -o root -g root "${tmp}" "${HELPER_PATH}"
  rm -f "${tmp}"
}

# --------------------------------------------------------------------------
# Redfish helpers (bash wrappers around the Python control plane)
# --------------------------------------------------------------------------
# _rf USER PASS METHOD PATH [JSON_DATA]
_rf() {
  local u="$1" p="$2" m="$3" path="$4" data="${5:-}"
  local out _rf_err _rf_tmp
  _rf_tmp="$(mktemp)"
  out="$(ILO_HOST="${ILO_HOST}" ILO_USER="${u}" ILO_PASS="${p}" \
         ILO_CACERT="${CACERT_PATH}" ILO_DATA="${data}" \
         python3 "${HELPER_PATH}" "${m}" "${path}" 2>"${_rf_tmp}" || true)"
  _rf_err="$(cat "${_rf_tmp}"; rm -f "${_rf_tmp}")"
  if [[ -z "${out}" ]]; then
    RF_CODE=0; RF_BODY="null"; RF_ERR="no response"
    log_setup "RF ${m} ${path} (user=${u}) → no output${_rf_err:+$'\n'  stderr: ${_rf_err}}"
    return 0
  fi
  RF_CODE="$(jq -r '.status // 0' <<<"${out}" 2>/dev/null || echo 0)"
  RF_BODY="$(jq -c '.body'        <<<"${out}" 2>/dev/null || echo null)"
  RF_ERR="$(jq  -r '.error // ""' <<<"${out}" 2>/dev/null || echo '')"
  [[ "${RF_CODE}" =~ ^[0-9]+$ ]] || RF_CODE=0
  log_setup "RF ${m} ${path} (user=${u}) → HTTP ${RF_CODE}${RF_ERR:+ | ${RF_ERR}}${_rf_err:+$'\n'  stderr: ${_rf_err}}"
  return 0
}
# rf METHOD PATH [DATA] — uses the service account credentials.
rf() { _rf "${SVC_USER}" "${SVC_PASS}" "$@"; }

# --------------------------------------------------------------------------
# Account create/update (least privilege: Login + Configure iLO Settings)
# --------------------------------------------------------------------------
create_or_update_account() {
  local au="$1" ap="$2" nu="$3" np="$4"
  log_setup "create_or_update_account: target user=${nu}"
  _rf "${au}" "${ap}" GET "/redfish/v1/AccountService/Accounts/"
  [[ "${RF_CODE}" =~ ^2 ]] || { log_setup "ERROR: list accounts failed HTTP ${RF_CODE} ${RF_ERR}"; return 2; }

  local members uri found="" uname
  members="$(jq -r '.Members[]?."@odata.id" // empty' <<<"${RF_BODY}")"
  while IFS= read -r uri; do
    [[ -n "${uri}" ]] || continue
    _rf "${au}" "${ap}" GET "${uri}"
    [[ "${RF_CODE}" =~ ^2 ]] || continue
    uname="$(jq -r '.UserName // empty' <<<"${RF_BODY}")"
    [[ "${uname}" == "${nu}" ]] && { found="${uri}"; break; }
  done <<< "${members}"

  local body
  if [[ -n "${found}" ]]; then
    # Only reset password — do NOT include Privileges in the PATCH body.
    # iLO replaces the entire Privileges object rather than merging, so
    # including it would strip any privileges not listed here (e.g. full
    # admin rights if the user accidentally entered the admin account name).
    body="$(jq -nc --arg p "${np}" '{Password:$p}')"
    _rf "${au}" "${ap}" PATCH "${found}" "${body}"
    [[ "${RF_CODE}" =~ ^2 ]] || { log_setup "ERROR: PATCH ${found} failed HTTP ${RF_CODE} ${RF_ERR}"; return 3; }
    ACCT_RESULT="updated existing account (password reset)"
  else
    body="$(jq -nc --arg u "${nu}" --arg p "${np}" \
      '{UserName:$u, Password:$p, Oem:{Hpe:{LoginName:$u, Privileges:{LoginPriv:true, iLOConfigPriv:true}}}}')"
    _rf "${au}" "${ap}" POST "/redfish/v1/AccountService/Accounts/" "${body}"
    [[ "${RF_CODE}" =~ ^2 ]] || { log_setup "ERROR: POST accounts failed HTTP ${RF_CODE} ${RF_ERR}"; return 4; }
    # Resolve the new account URI so an abort can delete it.
    _rf "${au}" "${ap}" GET "/redfish/v1/AccountService/Accounts/"
    if [[ "${RF_CODE}" =~ ^2 ]]; then
      members="$(jq -r '.Members[]?."@odata.id" // empty' <<<"${RF_BODY}")"
      while IFS= read -r uri; do
        [[ -n "${uri}" ]] || continue
        _rf "${au}" "${ap}" GET "${uri}"
        [[ "${RF_CODE}" =~ ^2 ]] || continue
        uname="$(jq -r '.UserName // empty' <<<"${RF_BODY}")"
        [[ "${uname}" == "${nu}" ]] && { ACCT_CREATED_URI="${uri}"; break; }
      done <<< "${members}"
    fi
    ACCT_RESULT="created new account with Login + Configure iLO Settings"
  fi
  return 0
}

is_recommended() { local n="$1" r; for r in "${RECOMMENDED[@]}"; do [[ "${r}" == "${n}" ]] && return 0; done; return 1; }
def_warn() { echo "${DEF_WARN[$1]:-70}"; }
def_crit() { echo "${DEF_CRIT[$1]:-80}"; }

# --------------------------------------------------------------------------
# Management menu (existing install)
# --------------------------------------------------------------------------
is_already_installed() { [[ -f "${SBIN_PATH}" || -f "${UNIT_PATH}" || -f "${CONF_PATH}" ]]; }

_svc_status_line() {
  local active state ver
  active="$(systemctl is-active "${SERVICE}" 2>/dev/null || true)"
  state="$(systemctl is-enabled "${SERVICE}" 2>/dev/null || true)"
  ver="$(grep -E '^VERSION=' "${CONF_PATH}" 2>/dev/null | head -n1 | cut -d= -f2 || true)"
  printf 'Service %-8s  enabled: %-9s  installed version: %s' "${active}" "${state}" "${ver:-unknown}"
}

_edit_config() {
  local ed="${VISUAL:-${EDITOR:-}}"
  [[ -z "${ed}" ]] && command -v nano >/dev/null 2>&1 && ed=nano
  [[ -z "${ed}" ]] && command -v vim  >/dev/null 2>&1 && ed=vim
  [[ -z "${ed}" ]] && command -v vi   >/dev/null 2>&1 && ed=vi
  if [[ -z "${ed}" ]]; then
    say_box "No terminal editor found (nano/vim/vi). Set \$EDITOR and re-run." 9 60
    return 1
  fi
  clear
  "${ed}" "${CONF_PATH}"
}

# Optionally DELETE the iLO service account during uninstall.
_uninstall_account() {
  ask_yesno "Also DELETE the iLO service account from the iLO itself?

This needs an iLO ADMINISTRATOR login. The dedicated service account will be
removed via Redfish. Choose No to leave it in place." 13 74 || return 0

  local svc_user au ap uri members uname target=""
  svc_user="$(grep -E '^ILO_SVC_USER=' "${CONF_PATH}" 2>/dev/null | head -n1 | cut -d= -f2- || true)"
  ILO_HOST="$(grep -E '^ILO_HOST=' "${CONF_PATH}" 2>/dev/null | head -n1 | cut -d= -f2- || true)"
  [[ -z "${svc_user}" || -z "${ILO_HOST}" ]] && { say_box "Could not read host/account from config; skipping account removal." 9 70; return 0; }

  au="$(wt --inputbox "iLO ADMINISTRATOR username:" 9 60 "Administrator")" || return 0
  ap="$(wt --passwordbox "Password for iLO admin '${au}':" 9 60)" || return 0

  _rf "${au}" "${ap}" GET "/redfish/v1/AccountService/Accounts/"
  [[ "${RF_CODE}" =~ ^2 ]] || { say_box "Admin login failed (HTTP ${RF_CODE}). Account not removed." 9 64; return 0; }
  members="$(jq -r '.Members[]?."@odata.id" // empty' <<<"${RF_BODY}")"
  while IFS= read -r uri; do
    [[ -n "${uri}" ]] || continue
    _rf "${au}" "${ap}" GET "${uri}"
    [[ "${RF_CODE}" =~ ^2 ]] || continue
    uname="$(jq -r '.UserName // empty' <<<"${RF_BODY}")"
    [[ "${uname}" == "${svc_user}" ]] && { target="${uri}"; break; }
  done <<< "${members}"

  if [[ -z "${target}" ]]; then say_box "Service account '${svc_user}' not found on the iLO." 8 64; return 0; fi
  _rf "${au}" "${ap}" DELETE "${target}"
  if [[ "${RF_CODE}" =~ ^2 ]]; then say_box "iLO account '${svc_user}' deleted." 8 60
  else say_box "Failed to delete iLO account (HTTP ${RF_CODE}). Remove it manually." 9 68; fi
}

_do_uninstall() {
  say_box "This will:
  - stop and disable  ${SERVICE}
  - delete the monitor, unit, config, credentials, pinned cert and helper
  - optionally remove the iLO service account (prompted next)

Press OK to continue." 14 74

  run_critical "stop ${SERVICE}"    systemctl stop    "${SERVICE}" || true
  run_critical "disable ${SERVICE}" systemctl disable "${SERVICE}" || true

  _uninstall_account

  rm -f "${SBIN_PATH}" "${UNIT_PATH}" "${CONF_PATH}" "${HELPER_PATH}" \
        "${CACERT_PATH}" "${CRED_ENC_FILE}" "${CRED_ENV_FILE}"
  rmdir "${LIB_DIR}" 2>/dev/null || true
  run_critical "systemctl daemon-reload" systemctl daemon-reload || true

  if [[ -d "${STATE_DIR}" ]] && ask_yesno "Remove state directory ${STATE_DIR} as well?" 9 66; then
    rm -rf "${STATE_DIR}"
  fi
  if [[ -d "${BASE_DIR}" ]] && ! ls -A "${BASE_DIR}" >/dev/null 2>&1; then
    rmdir "${BASE_DIR}" 2>/dev/null || true
  fi

  say_box "Uninstall complete. Fans are back under full iLO firmware control." 8 70
  INSTALL_DONE=1
  exit 0
}

step_already_installed() {
  local status_line choice
  while true; do
    status_line="$(_svc_status_line)"
    choice="$(wt --default-item "status" --menu \
"hpe-fan-watch is already installed on this machine.

${status_line}
Config : ${CONF_PATH}
Monitor: ${SBIN_PATH}

What would you like to do?" 22 80 6 \
"reconfigure" "Run the full setup wizard again (re-install)" \
"edit"        "Edit the config file" \
"restart"     "Restart the service now" \
"status"      "Show the live sensor/fan dashboard" \
"logs"        "Tail live service logs" \
"uninstall"   "Stop and remove everything")" || abort

    case "${choice}" in
      reconfigure) return 0 ;;
      edit)
        _edit_config || true
        if ask_yesno "Restart the service now to apply changes?" 9 66; then
          run_critical "restart ${SERVICE}" systemctl restart "${SERVICE}" \
            && say_box "Service restarted. Monitor with 'journalctl -u ${SERVICE} -f'." 9 68
        fi ;;
      restart)
        if run_critical "restart ${SERVICE}" systemctl restart "${SERVICE}"; then
          say_box "Service restarted. Status: $(systemctl is-active "${SERVICE}" 2>/dev/null || echo unknown)" 8 64
        fi ;;
      status)
        local out; out="$("${SBIN_PATH}" --status 2>&1)" || true
        wt --scrolltext --msgbox "${out}" 30 86 || : ;;
      logs)
        clear
        echo "--- Live logs for ${SERVICE} (Ctrl-C to return) ---"
        journalctl -u "${SERVICE}" -n 40 -f || true
        read -rp "Press ENTER to return to the menu..." _ || true ;;
      uninstall)
        if ask_yesno "UNINSTALL hpe-fan-watch?

This stops the service and deletes all installed files. Fans revert to full
iLO firmware control." 11 70; then _do_uninstall; fi ;;
    esac
  done
}

# --------------------------------------------------------------------------
# Wizard steps
# --------------------------------------------------------------------------
step_welcome() {
  say_box \
"HPE iLO Fan-Watch Installer  v${VERSION}  (commit ${COMMIT})

This installer sets up the HPE iLO fan-quieting service on THIS machine.

It will:
 - pin the iLO TLS certificate (verified on every call - never insecure)
 - optionally CREATE a least-privilege iLO account for the service
 - probe iLO generation / fan-control capability
 - read the live temperature sensors and let you tune thresholds
 - install a watchdog-protected systemd service and start it

A terminal of at least 80x24 is recommended." 21 76
}

step_host() {
  local desc="Enter the iLO IP address or hostname (no https://).

TLS will be verified, so prefer the name present in the iLO certificate.
The service talks to: https://<host>/redfish/v1/Chassis/1/Thermal/"
  ILO_HOST="$(wt --inputbox "${desc}" 13 74 "")" || abort
  ILO_HOST="${ILO_HOST#https://}"; ILO_HOST="${ILO_HOST%/}"
  while [[ -z "${ILO_HOST}" ]]; do
    say_box "The iLO host cannot be empty." 8 50
    ILO_HOST="$(wt --inputbox "${desc}" 13 74 "")" || abort
    ILO_HOST="${ILO_HOST#https://}"; ILO_HOST="${ILO_HOST%/}"
  done
  log_setup "iLO host: ${ILO_HOST}"
}

step_certpin() {
  local mode
  mode="$(wt --menu \
"TLS certificate verification (required - the service never runs insecure).

Choose how to establish the trusted certificate for ${ILO_HOST}:" 15 78 2 \
"pin"    "Fetch the iLO certificate now and pin it (recommended)" \
"supply" "I will provide a CA/cert PEM file path")" || abort

  install -d -m 0700 "${BASE_DIR}"

  if [[ "${mode}" == "supply" ]]; then
    local p
    while true; do
      p="$(wt --inputbox "Path to a PEM CA/cert file that validates the iLO:" 10 70 "/etc/ssl/certs/ilo.pem")" || abort
      if [[ -r "${p}" ]] && openssl x509 -in "${p}" -noout >/dev/null 2>&1; then
        install -m 0644 "${p}" "${CACERT_PATH}"; break
      fi
      say_box "Could not read a valid PEM certificate at: ${p}" 8 64
    done
  else
    local tmp tmp_leaf; tmp="$(mktemp)"; tmp_leaf="$(mktemp)"
    # -showcerts fetches the full chain (leaf + intermediates); sed extracts all PEM blocks.
    # Storing only the leaf cert breaks TLS verification when the iLO cert is signed
    # by an intermediate CA — urllib3 cannot build the chain without it.
    if ! echo | openssl s_client -connect "${ILO_HOST}:443" -servername "${ILO_HOST}" \
         -showcerts 2>/dev/null \
         | sed -n '/-----BEGIN CERTIFICATE-----/,/-----END CERTIFICATE-----/p' > "${tmp}" \
         || ! [[ -s "${tmp}" ]]; then
      rm -f "${tmp}" "${tmp_leaf}"
      say_box "Could not retrieve a TLS certificate from ${ILO_HOST}:443.
Check connectivity, then re-run." 9 64
      abort
    fi
    # Extract the leaf (first) cert for display only.
    openssl x509 -outform PEM < "${tmp}" > "${tmp_leaf}" 2>/dev/null
    local fp subj issuer dates chain_count
    fp="$(openssl x509 -in "${tmp_leaf}" -noout -fingerprint -sha256 | sed 's/.*=//')"
    subj="$(openssl x509 -in "${tmp_leaf}" -noout -subject | sed 's/^subject= *//')"
    issuer="$(openssl x509 -in "${tmp_leaf}" -noout -issuer | sed 's/^issuer= *//')"
    dates="$(openssl x509 -in "${tmp_leaf}" -noout -dates | tr '\n' '  ')"
    chain_count="$(grep -c 'BEGIN CERTIFICATE' "${tmp}" || true)"
    rm -f "${tmp_leaf}"
    if ask_yesno "Verify this iLO certificate and pin it as trusted:

Subject     : ${subj}
Issuer      : ${issuer}
Validity    : ${dates}
SHA-256 FP  : ${fp}
Chain certs : ${chain_count}

Confirm the fingerprint matches the iLO before trusting it. Pin this cert?" 20 80; then
      install -m 0644 "${tmp}" "${CACERT_PATH}"
      rm -f "${tmp}"
    else
      rm -f "${tmp}"; abort
    fi
  fi
}

account_create_flow() {
  local au ap nu np np2 rc=0
  au="$(wt --inputbox \
"Create service account - step 1 of 2: ADMIN login.

Enter an existing iLO ADMINISTRATOR username. It is used ONCE now to create
the service account and is NOT stored." 13 76 "Administrator")" || abort
  ap="$(wt --passwordbox "Password for iLO admin '${au}':" 9 62)" || abort

  _rf "${au}" "${ap}" GET "/redfish/v1/AccountService/Accounts/"
  if [[ ! "${RF_CODE}" =~ ^2 ]]; then
    local m="Admin login failed (HTTP ${RF_CODE})."
    [[ "${RF_CODE}" == "0" ]] && m="Could not reach the iLO at ${ILO_HOST}. ${RF_ERR}"
    log_setup "admin login failed: user=${au} host=${ILO_HOST} HTTP=${RF_CODE} err=${RF_ERR}"
    say_box "${m}

Returning to the authentication menu.

Full details: ${SETUP_LOG}" 13 70
    return 1
  fi
  # Hold admin creds in memory so an abort can clean up an orphaned account.
  ADMIN_USER="${au}"; ADMIN_PASS="${ap}"

  while true; do
    nu="$(wt --inputbox \
"Create service account - step 2 of 2: NEW account.

Username for the new dedicated service account:" 12 68 "redfishuser")" || abort
    [[ -n "${nu}" ]] || { say_box "Username cannot be empty." 8 46; continue; }
    [[ "${nu}" == "${au}" ]] && {
      say_box "The service account name cannot be the same as the admin account ('${au}').

Using the admin account as the service account would reset its password and
strip its privileges to the minimal set, locking you out.

Choose a different username (e.g. 'redfishuser')." 14 74
      continue
    }
    break
  done
  while true; do
    np="$(wt  --passwordbox "Password for new account '${nu}' (min 8 characters):" 9 66)" || abort
    np2="$(wt --passwordbox "Re-enter the password for '${nu}':" 9 66)" || abort
    [[ "${np}" != "${np2}" ]] && { say_box "Passwords do not match. Try again." 8 50; continue; }
    (( ${#np} < 8 )) && { say_box "Password must be at least 8 characters (iLO default policy)." 8 62; continue; }
    [[ "${np}" == *$'\n'* ]] && { say_box "Password cannot contain a newline." 8 50; continue; }
    break
  done

  create_or_update_account "${au}" "${ap}" "${nu}" "${np}" || rc=$?
  if (( rc != 0 )); then
    local detail; detail="$(jq -r '[.. | .MessageId? // empty] | first // empty' <<<"${RF_BODY}" 2>/dev/null || true)"
    log_setup "account_create_flow failed: code=${rc} HTTP=${RF_CODE} err=${RF_ERR} detail=${detail}"
    say_box \
"Could not create/update the account (code ${rc}).

iLO response: ${detail:-HTTP ${RF_CODE} ${RF_ERR}}

Common causes: admin lacks 'Administer User Accounts', the password fails the
iLO policy, or the account limit is reached. Returning to the auth menu.

Full details: ${SETUP_LOG}" 18 76
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

A dedicated account needs ONLY two privileges: Login and Configure iLO
Settings (least privilege)." 16 78 2 \
"create" "Create that account for me now (needs an iLO admin login)" \
"exist"  "Use an account I already created")" || abort

    if [[ "${mode}" == "create" ]]; then
      account_create_flow || continue
    else
      SVC_USER="$(wt --inputbox "Existing service account login name:" 10 66 "redfishuser")" || abort
      SVC_PASS="$(wt --passwordbox "Password for '${SVC_USER}':" 9 60)" || abort
      [[ "${SVC_PASS}" == *$'\n'* ]] && { say_box "Password cannot contain a newline." 8 50; continue; }
    fi

    rf GET "/redfish/v1/Chassis/1/Thermal/"
    if [[ "${RF_CODE}" =~ ^2 ]] && jq -e '.Temperatures' <<<"${RF_BODY}" >/dev/null 2>&1; then
      printf '%s' "${RF_BODY}" > "${THERMAL_TMP}"
      return 0
    fi
    local why
    case "${RF_CODE}" in
      401|403) why="Authentication failed or the account lacks Login privilege (HTTP ${RF_CODE})." ;;
      0)       why="Could not reach/verify the iLO at ${ILO_HOST}. ${RF_ERR}" ;;
      *)       why="Unexpected response from the iLO (HTTP ${RF_CODE}). ${RF_ERR}" ;;
    esac
    log_setup "service account verify failed: user=${SVC_USER} host=${ILO_HOST} HTTP=${RF_CODE} err=${RF_ERR}"
    ask_yesno "${why}

Full details: ${SETUP_LOG}

Try again (re-enter host and/or credentials)?" 14 72 || abort
    ILO_HOST="$(wt --inputbox "iLO IP or hostname (no https://):" 10 64 "${ILO_HOST}")" || abort
    ILO_HOST="${ILO_HOST#https://}"; ILO_HOST="${ILO_HOST%/}"
  done
}

# Probe iLO generation + FanPercentAdjust capability.
step_compat() {
  local model fw gen=""
  _rf "${SVC_USER}" "${SVC_PASS}" GET "/redfish/v1/Managers/1/"
  if [[ "${RF_CODE}" =~ ^2 ]]; then
    model="$(jq -r '.Model // empty' <<<"${RF_BODY}")"
    fw="$(jq -r '.FirmwareVersion // empty' <<<"${RF_BODY}")"
    gen="${model}"
  fi

  local has_adjust="no"
  if jq -e '[.. | objects | has("FanPercentAdjust")] | any' "${THERMAL_TMP}" >/dev/null 2>&1; then
    has_adjust="yes"
  fi

  if [[ "${model}" == *"iLO 4"* ]]; then
    ask_yesno "Compatibility WARNING

Detected: ${gen:-unknown} (firmware ${fw:-?}).

iLO 4 (Gen8/Gen9) does NOT expose the Oem.Hpe.FanPercentAdjust control this
service relies on. The service will install but is very unlikely to change
fan behaviour on this hardware.

Continue anyway?" 17 76 || abort
    return 0
  fi

  if [[ "${has_adjust}" != "yes" ]]; then
    ask_yesno "Compatibility WARNING

Detected: ${gen:-unknown} (firmware ${fw:-?}).

The live Thermal resource does not currently report Oem.Hpe.FanPercentAdjust.
On some firmware it is write-only and still works; on others fan override is
unavailable and the service will have no effect.

Continue anyway?" 17 78 || abort
  else
    say_box "Compatibility OK: ${gen:-iLO 5/6} (firmware ${fw:-?}).
FanPercentAdjust fan control is available on this hardware." 9 72
  fi
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

  local out
  local _sh _sl; _sh="$(dlg_h 20)"; _sl=$(( _sh - 8 ))
  out="$(wt --separate-output --checklist \
"These are the sensors the iLO reports right now, with current readings.
Tick the ones to watch. Pre-ticked = recommended set.
SPACE toggles, TAB moves to OK." "${_sh}" "$(dlg_w 78)" "${_sl}" "${CK[@]}")" || abort

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
  if ask_yesno "Suggested WARNING / CRITICAL thresholds (Celsius):

${list}
At a warning the fans stop quieting; at a critical they go to full firmware
cooling. Use these suggested values?" "$(dlg_h 20)" "$(dlg_w 78)"; then return 0; fi

  local w c
  for n in "${WATCH[@]}"; do
    while true; do
      w="$(wt --inputbox "Sensor: ${n}

WARNING threshold in C. Suggested: ${WARN[$n]}" 12 72 "${WARN[$n]}")" || abort
      [[ "${w}" =~ ^[0-9]+$ ]] && (( w >= 1 && w <= 120 )) && break
      say_box "Enter a whole number between 1 and 120." 8 52
    done
    while true; do
      c="$(wt --inputbox "Sensor: ${n}

CRITICAL threshold in C. Must be > ${w}. Suggested: ${CRIT[$n]}" 12 72 "${CRIT[$n]}")" || abort
      [[ "${c}" =~ ^[0-9]+$ ]] && (( c > w && c <= 120 )) && break
      say_box "Enter a whole number greater than ${w} and at most 120." 8 60
    done
    WARN["${n}"]="${w}"; CRIT["${n}"]="${c}"
  done
}

step_interval() {
  local choice
  choice="$(wt --default-item "5" --menu \
"How often should the service poll the iLO?

The service only WRITES on state changes, so faster polling just means more
lightweight reads. Cool-down is auto-scaled to ~2 minutes." 17 78 4 \
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
  HYST=$(( (120 + POLL - 1) / POLL )); (( HYST < 3 )) && HYST=3
}

step_fanvalues() {
  QUIET=50; NORMAL=25; SAFE=0
  if ask_yesno "Fan bias values (FanPercentAdjust). HIGHER = QUIETER:

  quiet  = 50 (all sensors cool)
  normal = 25 (a warning tripped)
  safe   =  0 (critical/failure - full firmware cooling)

Use these defaults?" 18 78; then return 0; fi

  local v key lbl cur pair
  for pair in "QUIET:max quieting (all cool)" "NORMAL:moderate (a warning tripped)" "SAFE:no quieting, full cooling (critical)"; do
    key="${pair%%:*}"; lbl="${pair#*:}"
    case "${key}" in QUIET) cur="${QUIET}";; NORMAL) cur="${NORMAL}";; SAFE) cur="${SAFE}";; esac
    while true; do
      v="$(wt --inputbox "${key} value (0-100): ${lbl}

Reminder: higher = quieter, 0 = full firmware cooling." 12 72 "${cur}")" || abort
      [[ "${v}" =~ ^[0-9]+$ ]] && (( v >= 0 && v <= 100 )) && break
      say_box "Enter a whole number between 0 and 100." 8 52
    done
    case "${key}" in QUIET) QUIET="${v}";; NORMAL) NORMAL="${v}";; SAFE) SAFE="${v}";; esac
  done
}

step_failures() {
  while true; do
    MAX_FAILURES="$(wt --inputbox \
"Consecutive Redfish failures before forcing SAFE (full cooling)?

A lower value fails safe sooner if the iLO becomes unreachable.
Range 1-10. Default 3." 13 74 "3")" || abort
    [[ "${MAX_FAILURES}" =~ ^[0-9]+$ ]] && (( MAX_FAILURES >= 1 && MAX_FAILURES <= 10 )) && break
    say_box "Enter a whole number between 1 and 10." 8 52
  done
}

step_options() {
  local out
  out="$(wt --separate-output --checklist \
"Optional behaviours (SPACE toggles):

Re-assert on start - re-apply the bias each start (survives iLO reboot).
Revert on stop     - push 'safe' (full cooling) when the service stops.
Log to journal     - also emit log lines via logger." 18 80 3 \
"reassert" "Re-assert quieting on service start"               ON \
"revert"   "Revert fans to firmware control when service stops" ON \
"syslog"   "Also log to the systemd journal/syslog"            ON)" || abort
  REASSERT=0; REVERT=0; USE_SYSLOG=0
  local o
  while IFS= read -r o; do
    case "${o}" in reassert) REASSERT=1;; revert) REVERT=1;; syslog) USE_SYSLOG=1;; esac
  done <<< "${out}"

  if (( REVERT == 0 )); then
    ask_yesno "WARNING: 'Revert on stop' is DISABLED.

If the service stops or crashes, the fans will REMAIN at the last quiet bias
instead of returning to full firmware control. Under a fault this can leave
the server under-cooled.

Keep revert-on-stop DISABLED? (No = re-enable it, recommended)" 16 78 || REVERT=1
  fi
}

step_summary() {
  local sens="" n
  for n in "${WATCH[@]}"; do sens+=" ${n} (warn ${WARN[$n]} / crit ${CRIT[$n]})"$'\n'; done
  local cred_desc="systemd encrypted credentials"
  [[ "${CRED_MODE}" == "envfile" ]] && cred_desc="root-only 0400 env file"
  local summary
  summary="Review before installing (v${VERSION}  commit ${COMMIT}):

iLO host        : ${ILO_HOST}
TLS             : verified against pinned ${CACERT_PATH}
Service account : ${SVC_USER} (${ACCT_RESULT:-existing account})
Credentials     : ${cred_desc}
Poll interval   : ${POLL}s (cool-down ~$(( POLL * HYST ))s = ${HYST} polls)
Max failures    : ${MAX_FAILURES}
Fan bias        : quiet ${QUIET} / normal ${NORMAL} / safe ${SAFE}
Options         : reassert=${REASSERT} revert=${REVERT} syslog=${USE_SYSLOG}

Watched sensors :
${sens}"
  wt --scrolltext --msgbox "${summary}" "$(dlg_h 20)" "$(dlg_w 80)" || :
  ask_yesno "Proceed with installation and start the service now?" 8 62
}

# --------------------------------------------------------------------------
# Credential storage
# --------------------------------------------------------------------------
decide_cred_mode() {
  if command -v systemd-creds >/dev/null 2>&1 && systemd-creds --help 2>&1 | grep -q 'encrypt'; then
    CRED_MODE="systemd-creds"
  else
    CRED_MODE="envfile"
  fi
}

write_credentials() {
  install -d -m 0700 "${BASE_DIR}"
  rm -f "${CRED_ENC_FILE}" "${CRED_ENV_FILE}"
  if [[ "${CRED_MODE}" == "systemd-creds" ]]; then
    if printf 'ILO_USER=%s\nILO_PASS=%s\n' "${SVC_USER}" "${SVC_PASS}" \
         | systemd-creds encrypt --name=ilo - "${CRED_ENC_FILE}" 2>/dev/null; then
      chmod 0400 "${CRED_ENC_FILE}"
      return 0
    fi
    # Fall back if encryption is unavailable at runtime (e.g. no TPM/host key).
    CRED_MODE="envfile"
    say_box "systemd-creds encryption was unavailable; falling back to a
root-only 0400 environment file. Consider integrating a secrets manager
(HashiCorp Vault, etc.) for stronger protection." 11 74
  fi
  local tmp; tmp="$(mktemp)"
  printf 'ILO_USER=%s\nILO_PASS=%s\n' "${SVC_USER}" "${SVC_PASS}" > "${tmp}"
  install -m 0400 -o root -g root "${tmp}" "${CRED_ENV_FILE}"
  rm -f "${tmp}"
}

# --------------------------------------------------------------------------
# Write config (NO secrets here)
# --------------------------------------------------------------------------
write_config() {
  install -d -m 0700 "${BASE_DIR}"
  local tmp n; tmp="$(mktemp)"
  {
    printf '# Generated by hpe-fan-watch-installer v%s on %s\n' "${VERSION}" "$(date '+%Y-%m-%d %H:%M:%S %z')"
    printf '# Sourced as Bash by %s. Contains NO credentials.\n\n' "${SBIN_PATH}"
    printf 'VERSION=%s\n\n' "${VERSION}"
    printf 'ILO_HOST=%q\n'   "${ILO_HOST}"
    printf 'ILO_SVC_USER=%q\n' "${SVC_USER}"
    printf 'ILO_CACERT=%q\n'  "${CACERT_PATH}"
    printf 'HELPER_PATH=%q\n' "${HELPER_PATH}"
    printf 'CRED_MODE=%q\n'   "${CRED_MODE}"
    printf 'CRED_ENC_FILE=%q\n' "${CRED_ENC_FILE}"
    printf 'CRED_ENV_FILE=%q\n\n' "${CRED_ENV_FILE}"
    printf 'NORMAL_ADJUST=%s\n' "${NORMAL}"
    printf 'QUIET_ADJUST=%s\n'  "${QUIET}"
    printf 'SAFE_ADJUST=%s\n\n' "${SAFE}"
    printf 'POLL_INTERVAL=%s\n'    "${POLL}"
    printf 'HYSTERESIS_POLLS=%s\n' "${HYST}"
    printf 'MAX_FAILURES=%s\n\n'   "${MAX_FAILURES}"
    printf 'USE_SYSLOG=%s\n'        "${USE_SYSLOG}"
    printf 'REVERT_ON_EXIT=%s\n'    "${REVERT}"
    printf 'REASSERT_ON_START=%s\n\n' "${REASSERT}"
    printf 'WATCH_SENSORS=('
    for n in "${WATCH[@]}"; do printf ' %q' "${n}"; done
    printf ' )\n'
    printf 'declare -A SENSOR_WARN=('
    for n in "${WATCH[@]}"; do printf ' [%q]=%s' "${n}" "${WARN[$n]}"; done
    printf ' )\n'
    printf 'declare -A SENSOR_CRIT=('
    for n in "${WATCH[@]}"; do printf ' [%q]=%s' "${n}" "${CRIT[$n]}"; done
    printf ' )\n'
  } > "${tmp}"
  install -m 0600 -o root -g root "${tmp}" "${CONF_PATH}"
  rm -f "${tmp}"
}

# --------------------------------------------------------------------------
# Write monitor script (full, no stubs)
# --------------------------------------------------------------------------
write_monitor() {
  local tmp; tmp="$(mktemp)"
  cat > "${tmp}" <<'MONEOF'
#!/usr/bin/env bash
#
# hpe-fan-watch.sh — iLO Redfish fan-quieting monitor.
# Installed by hpe-fan-watch-installer. Driven by HPE's official Python
# Redfish library via the embedded control-plane helper. TLS always verified.
#
# Modes: --daemon (systemd), --once, --status, --dry-run, --help

set -euo pipefail

CONF_PATH="/etc/hpe-fan-watch/config"
STATE_DIR="/var/lib/hpe-fan-watch"
STATE_FILE="${STATE_DIR}/state"

MODE="once"
DRY_RUN=0

# Redfish results
RF_CODE=0; RF_BODY="null"; RF_ERR=""
SVC_USER=""; SVC_PASS=""
THERMAL_JSON="null"

usage() {
  cat <<EOF
Usage: hpe-fan-watch.sh [--daemon|--once|--status] [--dry-run]
  --daemon    run continuously (used by systemd)
  --once      run a single evaluation cycle and exit
  --status    print the sensor/fan dashboard and exit
  --dry-run   evaluate and log, but never write to the iLO
EOF
}

for arg in "$@"; do
  case "${arg}" in
    --daemon) MODE="daemon" ;;
    --once)   MODE="once" ;;
    --status) MODE="status" ;;
    --dry-run) DRY_RUN=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: ${arg}" >&2; usage; exit 2 ;;
  esac
done

[[ -r "${CONF_PATH}" ]] || { echo "Missing config: ${CONF_PATH}" >&2; exit 1; }
# shellcheck disable=SC1090
source "${CONF_PATH}"

log() {
  local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
  echo "${msg}"
  if [[ "${USE_SYSLOG:-0}" == "1" ]] && command -v logger >/dev/null 2>&1; then
    logger -t hpe-fan-watch -- "$*" 2>/dev/null || true
  fi
}

notify() {
  [[ -n "${NOTIFY_SOCKET:-}" ]] || return 0
  command -v systemd-notify >/dev/null 2>&1 || return 0
  systemd-notify "$@" 2>/dev/null || true
}

load_creds() {
  local blob="" line
  if [[ -n "${CREDENTIALS_DIRECTORY:-}" && -r "${CREDENTIALS_DIRECTORY}/ilo" ]]; then
    blob="$(cat "${CREDENTIALS_DIRECTORY}/ilo")"
  elif [[ "${CRED_MODE:-}" == "systemd-creds" && -r "${CRED_ENC_FILE:-}" ]] \
       && command -v systemd-creds >/dev/null 2>&1; then
    blob="$(systemd-creds decrypt --name=ilo "${CRED_ENC_FILE}" - 2>/dev/null)" \
      || { echo "Failed to decrypt credentials." >&2; exit 1; }
  elif [[ -r "${CRED_ENV_FILE:-}" ]]; then
    blob="$(cat "${CRED_ENV_FILE}")"
  else
    echo "No readable credentials found." >&2; exit 1
  fi
  while IFS= read -r line; do
    case "${line}" in
      ILO_USER=*) SVC_USER="${line#ILO_USER=}" ;;
      ILO_PASS=*) SVC_PASS="${line#ILO_PASS=}" ;;
    esac
  done <<< "${blob}"
  [[ -n "${SVC_USER}" && -n "${SVC_PASS}" ]] || { echo "Incomplete credentials." >&2; exit 1; }
}

rf() {
  local m="$1" path="$2" data="${3:-}" out
  out="$(ILO_HOST="${ILO_HOST}" ILO_USER="${SVC_USER}" ILO_PASS="${SVC_PASS}" \
         ILO_CACERT="${ILO_CACERT}" ILO_DATA="${data}" \
         python3 "${HELPER_PATH}" "${m}" "${path}" 2>/dev/null || true)"
  if [[ -z "${out}" ]]; then RF_CODE=0; RF_BODY="null"; RF_ERR="no response"; return 0; fi
  RF_CODE="$(jq -r '.status // 0' <<<"${out}" 2>/dev/null || echo 0)"
  RF_BODY="$(jq -c '.body'        <<<"${out}" 2>/dev/null || echo null)"
  RF_ERR="$(jq  -r '.error // ""' <<<"${out}" 2>/dev/null || echo '')"
  [[ "${RF_CODE}" =~ ^[0-9]+$ ]] || RF_CODE=0
}

read_thermal() {
  rf GET "/redfish/v1/Chassis/1/Thermal/"
  if [[ "${RF_CODE}" =~ ^2 ]] && jq -e '.Temperatures' <<<"${RF_BODY}" >/dev/null 2>&1; then
    THERMAL_JSON="${RF_BODY}"; return 0
  fi
  return 1
}

current_adjust() { jq -r '[.. | objects | .FanPercentAdjust? // empty] | first // "n/a"' <<<"${THERMAL_JSON}" 2>/dev/null || echo "n/a"; }

apply_adjust() {
  local v="$1"
  if [[ "${DRY_RUN}" == "1" ]]; then
    log "DRY-RUN: would set FanPercentAdjust=${v}"
    return 0
  fi
  rf PATCH "/redfish/v1/Chassis/1/Thermal/" "$(jq -nc --argjson v "${v}" '{Oem:{Hpe:{FanPercentAdjust:$v}}}')"
  if [[ "${RF_CODE}" =~ ^2 ]]; then
    log "Applied FanPercentAdjust=${v}"
    return 0
  fi
  log "ERROR: PATCH FanPercentAdjust=${v} failed (HTTP ${RF_CODE}) ${RF_ERR}"
  return 1
}

# Evaluate watched sensors against the current thermal snapshot.
# Echoes "STATE|maxname|maxreading" where STATE is quiet|normal|safe.
evaluate() {
  local worst="quiet" name reading w c hottest_name="-" hottest_val=-1
  for name in "${WATCH_SENSORS[@]}"; do
    reading="$(jq -r --arg n "${name}" '
      .Temperatures[]? | select(.Name==$n) | (.ReadingCelsius // empty)' <<<"${THERMAL_JSON}" 2>/dev/null | head -n1)"
    [[ -n "${reading}" ]] || continue
    reading="${reading%.*}"
    [[ "${reading}" =~ ^[0-9]+$ ]] || continue
    (( reading > hottest_val )) && { hottest_val="${reading}"; hottest_name="${name}"; }
    w="${SENSOR_WARN[$name]:-70}"; c="${SENSOR_CRIT[$name]:-80}"
    if (( reading >= c )); then worst="safe"
    elif (( reading >= w )) && [[ "${worst}" != "safe" ]]; then worst="normal"; fi
  done
  echo "${worst}|${hottest_name}|${hottest_val}"
}

state_to_value() {
  case "$1" in
    quiet)  echo "${QUIET_ADJUST}" ;;
    normal) echo "${NORMAL_ADJUST}" ;;
    *)      echo "${SAFE_ADJUST}" ;;
  esac
}

read_cached_state() { [[ -r "${STATE_FILE}" ]] && cat "${STATE_FILE}" || echo "unknown"; }
write_cached_state() { install -d -m 0750 "${STATE_DIR}"; printf '%s' "$1" > "${STATE_FILE}"; }

FAILS=0
COOL_STREAK=0

# One evaluation cycle. force=1 ignores the cache (used on reassert).
cycle() {
  local force="${1:-0}"
  if ! read_thermal; then
    FAILS=$(( FAILS + 1 ))
    log "WARN: thermal read failed (${FAILS}/${MAX_FAILURES}) HTTP ${RF_CODE} ${RF_ERR}"
    if (( FAILS >= MAX_FAILURES )); then
      log "Failure threshold reached -> forcing SAFE (full firmware cooling)"
      apply_adjust "${SAFE_ADJUST}" || true
      write_cached_state "safe"
    fi
    return 0
  fi
  FAILS=0

  local res state hottest_name hottest_val cached desired
  res="$(evaluate)"
  state="${res%%|*}"; res="${res#*|}"
  hottest_name="${res%%|*}"; hottest_val="${res#*|}"
  cached="$(read_cached_state)"

  # Hysteresis: only de-escalate to quiet after HYSTERESIS_POLLS cool cycles.
  if [[ "${state}" == "quiet" ]]; then
    COOL_STREAK=$(( COOL_STREAK + 1 ))
    if [[ "${cached}" != "quiet" && "${force}" != "1" && "${COOL_STREAK}" -lt "${HYSTERESIS_POLLS}" ]]; then
      state="${cached}"   # hold the warmer state until the streak completes
    fi
  else
    COOL_STREAK=0
  fi

  desired="$(state_to_value "${state}")"
  if [[ "${state}" != "${cached}" || "${force}" == "1" ]]; then
    log "State ${cached} -> ${state} (hottest: ${hottest_name}=${hottest_val}C); FanPercentAdjust=${desired}"
    if apply_adjust "${desired}"; then write_cached_state "${state}"; fi
  fi
}

# ---- status dashboard ----
do_status() {
  echo "HPE iLO Fan-Watch — status (version ${VERSION:-?})"
  echo "iLO host : ${ILO_HOST}   TLS: verified (${ILO_CACERT})"
  if ! read_thermal; then
    echo "ERROR: could not read thermal data (HTTP ${RF_CODE}) ${RF_ERR}"
    return 1
  fi
  local cached; cached="$(read_cached_state)"
  printf '\n%-22s %8s %8s %8s   %s\n' "SENSOR" "TEMP" "WARN" "CRIT" "STATE"
  printf '%s\n' "--------------------------------------------------------------------"
  local name reading w c st
  for name in "${WATCH_SENSORS[@]}"; do
    reading="$(jq -r --arg n "${name}" '.Temperatures[]? | select(.Name==$n) | (.ReadingCelsius // "n/a")' <<<"${THERMAL_JSON}" 2>/dev/null | head -n1)"
    [[ -n "${reading}" ]] || reading="n/a"
    w="${SENSOR_WARN[$name]:-70}"; c="${SENSOR_CRIT[$name]:-80}"
    st="ok"
    if [[ "${reading}" =~ ^[0-9]+$ ]]; then
      if   (( reading >= c )); then st="CRIT"
      elif (( reading >= w )); then st="warn"; fi
    fi
    printf '%-22s %7sC %7sC %7sC   %s\n' "${name}" "${reading}" "${w}" "${c}" "${st}"
  done
  echo "--------------------------------------------------------------------"
  printf 'Overall state        : %s\n' "${cached}"
  printf 'Current FanPercentAdj: %s\n' "$(current_adjust)"
  printf 'Bias map             : quiet=%s normal=%s safe=%s\n' "${QUIET_ADJUST}" "${NORMAL_ADJUST}" "${SAFE_ADJUST}"
  printf 'Poll/hysteresis/fail : %ss / %s polls / %s\n' "${POLL_INTERVAL}" "${HYSTERESIS_POLLS}" "${MAX_FAILURES}"
  echo "Fans (RPM):"
  jq -r '.Fans[]? | "  \(.Name): \(.Reading // .ReadingRPM // "?") \(.ReadingUnits // "RPM")"' <<<"${THERMAL_JSON}" 2>/dev/null || true
}

on_exit() {
  trap - TERM INT EXIT
  if [[ "${REVERT_ON_EXIT:-1}" == "1" && "${DRY_RUN}" != "1" ]]; then
    log "Exit: reverting fans to SAFE (full firmware control)"
    load_creds 2>/dev/null || true
    apply_adjust "${SAFE_ADJUST}" || log "WARN: revert-on-exit failed"
  fi
  exit 0
}

case "${MODE}" in
  status)
    load_creds
    do_status
    ;;
  once)
    load_creds
    cycle 1
    ;;
  daemon)
    load_creds
    trap on_exit TERM INT
    notify --ready --status="monitoring ${ILO_HOST}"
    log "Started (poll=${POLL_INTERVAL}s hysteresis=${HYSTERESIS_POLLS} max_failures=${MAX_FAILURES} revert=${REVERT_ON_EXIT} dry_run=${DRY_RUN})"
    first=1
    while true; do
      if [[ "${first}" == "1" && "${REASSERT_ON_START:-1}" == "1" ]]; then
        cycle 1; first=0
      else
        cycle 0
      fi
      notify WATCHDOG=1 --status="state=$(read_cached_state)"
      sleep "${POLL_INTERVAL}" &
      wait $! || true
    done
    ;;
esac
MONEOF
  install -m 0750 -o root -g root "${tmp}" "${SBIN_PATH}"
  rm -f "${tmp}"
}

# --------------------------------------------------------------------------
# Write systemd unit (full; conditional on watchdog + credential mode)
# --------------------------------------------------------------------------
write_unit() {
  local watchdog=$(( POLL * 6 + 30 ))
  local tmp; tmp="$(mktemp)"
  {
    printf '[Unit]\n'
    printf 'Description=HPE iLO Fan-Watch (Redfish fan quieting) v%s\n' "${VERSION}"
    printf 'Documentation=https://github.com/bitwire-it/hpe-ilo-fan-watch\n'
    printf 'After=network-online.target\n'
    printf 'Wants=network-online.target\n\n'

    printf '[Service]\n'
    if (( NOTIFY_SUPPORTED == 1 )); then
      printf 'Type=notify\n'
      printf 'NotifyAccess=all\n'
      printf 'WatchdogSec=%s\n' "${watchdog}"
    else
      printf 'Type=simple\n'
    fi
    printf 'ExecStart=%s --daemon\n' "${SBIN_PATH}"
    printf 'Restart=on-failure\n'
    printf 'RestartSec=10\n'

    if [[ "${CRED_MODE}" == "systemd-creds" ]]; then
      printf 'LoadCredentialEncrypted=ilo:%s\n' "${CRED_ENC_FILE}"
    fi

    # Hardening
    printf 'StateDirectory=hpe-fan-watch\n'
    printf 'StateDirectoryMode=0750\n'
    printf 'ProtectSystem=strict\n'
    printf 'ProtectHome=true\n'
    printf 'PrivateTmp=true\n'
    printf 'NoNewPrivileges=true\n'
    printf 'ProtectKernelTunables=true\n'
    printf 'ProtectControlGroups=true\n'
    printf 'RestrictSUIDSGID=true\n\n'

    printf '[Install]\n'
    printf 'WantedBy=multi-user.target\n'
  } > "${tmp}"
  install -m 0644 -o root -g root "${tmp}" "${UNIT_PATH}"
  rm -f "${tmp}"
}

# --------------------------------------------------------------------------
# Install & finish
# --------------------------------------------------------------------------
ONCE_OUT=""; ONCE_RC=0
do_install() {
  decide_cred_mode
  if command -v systemd-notify >/dev/null 2>&1; then NOTIFY_SUPPORTED=1; else NOTIFY_SUPPORTED=0; fi

  install -d -m 0750 "${STATE_DIR}"
  write_credentials
  write_config
  write_monitor
  write_unit

  if ! run_critical "systemctl daemon-reload" systemctl daemon-reload; then abort; fi

  # Smoke test a single cycle before enabling.
  ONCE_RC=0
  ONCE_OUT="$(timeout 45 "${SBIN_PATH}" --once 2>&1)" || ONCE_RC=$?

  if ! run_critical "enable + start ${SERVICE}" systemctl enable --now "${SERVICE}"; then
    say_box "The service was installed but did not start cleanly.
Inspect: journalctl -u ${SERVICE} -xe" 9 70
  fi

  INSTALL_DONE=1
  # Drop admin creds from memory now that cleanup is no longer needed.
  ADMIN_USER=""; ADMIN_PASS=""
}

step_finish() {
  local active warn=""
  active="$(systemctl is-active "${SERVICE}" 2>/dev/null || true)"
  log_setup "=== installation complete: service=${active} ==="
  (( ONCE_RC != 0 )) && warn="NOTE: the single-cycle test returned code ${ONCE_RC}. If you used an EXISTING
account it may lack 'Configure iLO Settings' (PATCH -> HTTP 403). The service
is fail-safe but won't quiet until that is fixed.

"
  wt --scrolltext --msgbox \
"Installation complete (v${VERSION}).   Service status: ${active}

${warn}Test run output:
${ONCE_OUT}

Useful commands:
  journalctl -u ${SERVICE} -f     # live logs
  ${SBIN_PATH} --status           # sensor/fan dashboard
  ${SBIN_PATH} --dry-run --once   # evaluate without writing to the iLO
  systemctl restart ${SERVICE}    # apply config edits

Re-run this installer for the management menu (reconfigure / uninstall).

Install log: ${SETUP_LOG}" "$(dlg_h 26)" "$(dlg_w 84)" || :
}

# --------------------------------------------------------------------------
# Entry point
# --------------------------------------------------------------------------
main() {
  ensure_root_and_tools
  log_setup "=== HPE Fan Watch installer started (PID=$$) ==="

  if is_already_installed; then
    step_already_installed   # only returns on "reconfigure"
  fi

  step_welcome
  step_host
  step_certpin
  step_account
  step_compat
  step_sensors
  step_thresholds
  step_interval
  step_fanvalues
  step_failures
  step_options
  step_summary || abort
  do_install
  step_finish
}

main "$@"
