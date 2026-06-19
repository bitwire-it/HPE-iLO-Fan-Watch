# **HPE iLO Fan-Watch Installer**

An interactive installer and systemd-based thermal watchdog for **HPE ProLiant Gen10/Gen11 servers**. It uses HPE's **official Python Redfish tooling** (`python-ilorest-library` — the same engine behind the `ilorest` RESTful Interface Tool) to optimize fan speeds and reduce unnecessary noise while maintaining safe thermal operating limits.

This tool is designed for deployments where the host OS lacks a compatible HPE AMS/AMSD package path, but iLO Redfish access is available and the platform supports the `Oem.Hpe.FanPercentAdjust` property on the thermal endpoint. It uses **only supported Redfish APIs** — no firmware modifications, no unsupported binary patching, no fan hacks.

## **Overview**

The installer configures a local service that monitors the iLO thermal endpoint, evaluates designated hardware sensors, and dynamically updates the `FanPercentAdjust` value based on real-time temperature data.

### **Operational Workflow**

* **quiet:** Applied when all monitored sensors remain below warning thresholds.
* **normal:** Applied when one or more sensors cross a warning threshold.
* **safe:** Enforced immediately if any sensor crosses a critical threshold, or if Redfish connectivity fails repeatedly (see **Max failures**).

The service is engineered to **fail-safe**. Escalation to maximum cooling occurs instantly, while de-escalation back to quieter modes uses hysteresis to prevent rapid fan speed oscillation (fan flapping). If the service stops for any reason, fans revert to full firmware control by default.

## **Problem Statement**

On certain HPE platforms — particularly those running unsupported operating systems or non-standard hardware configurations — system fans may run at unnecessarily aggressive speeds despite healthy thermals. This project offers a host-side mitigation via Redfish, removing any operational dependency on the AMSD daemon.

## **Security Model**

Security is a first-class concern in this tool:

* **Always-verified TLS.** The installed service never uses `--insecure`. During setup the installer pins the iLO's certificate (or you supply a trusted CA/PEM path), and every Redfish call is verified against it via the official library's `cafile`.
* **No cleartext credentials.** Service credentials are stored as **encrypted systemd credentials** (`systemd-creds encrypt`, systemd ≥ 250, host/TPM-bound) when available, and delivered to the unit via `LoadCredentialEncrypted=`. On older systems they fall back to a **root-only `0400` environment file**, with a warning suggesting integration with a secrets manager (e.g. HashiCorp Vault). The generated config file contains **no** secrets.
* **Least privilege.** The dedicated iLO service account is provisioned with only **Login** and **Configure iLO Settings** privileges.
* **Hardened unit.** The systemd service runs with `ProtectSystem=strict`, `ProtectHome`, `PrivateTmp`, `NoNewPrivileges`, a managed `StateDirectory`, and a `WatchdogSec` health check.
* **Explicit permissions.** All files are written with strict, explicit modes (secrets `0400`, config `0600`).

## **Features**

* **Official tooling:** All iLO I/O runs through HPE's official `python-ilorest-library` (module `redfish`) via an embedded control-plane helper.
* **Interactive setup:** Driven by a `whiptail`-based terminal UI.
* **Cross-distro dependency management:** Installs prerequisites on **Debian/Ubuntu (apt), RHEL/Rocky/Fedora (dnf/yum), and OpenSUSE Leap (zypper)**. Fails cleanly with a useful list on unknown package managers.
* **TLS certificate pinning:** Fetches and displays the iLO certificate fingerprint for confirmation, then pins it for all future calls.
* **Encrypted credential storage:** `systemd-creds` encryption with a root-only fallback.
* **Account automation:** Provisions or reuses a least-privilege iLO service account, with automatic cleanup of an orphaned account if setup is aborted.
* **Compatibility guard:** Probes the iLO generation and `FanPercentAdjust` capability and warns clearly if the platform cannot be driven.
* **Dynamic inventory:** Discovers and parses the live sensor list directly from iLO prior to configuration.
* **Granular control:** Custom sensor selection with per-sensor warning and critical thresholds, configurable poll interval, fan-bias tuning, and a configurable failure threshold (1–10).
* **Persistent, watchdog-protected service:** A dedicated systemd unit with `sd_notify` keepalive, local state caching to avoid redundant PATCH requests, re-assert-on-start, and revert-on-exit (default ON).
* **Diagnostics:** A formatted `--status` dashboard and a `--dry-run` mode.
* **Lifecycle management:** Detects existing installs and offers reconfigure, edit, restart, status, logs, and uninstall (optionally deleting the iLO account).
* **Version tracking:** An embedded `VERSION` is written to the config and shown in the management menu.

## **Technical Architecture**

The background daemon monitors the following iLO endpoint:

`https://<ILO_HOST>/redfish/v1/Chassis/1/Thermal/`

The script extracts and processes:

* `Temperatures[]` for monitored sensor tracking.
* `Fans[]` to report current RPM metrics.
* `Oem.Hpe.FanPercentAdjust` to modify fan behavior.

All requests are made by the embedded Python helper (`redfish_ctl.py`), which logs into iLO with a verified TLS session and returns a clean JSON envelope to the Bash monitor.

### **Operating Modes**

| State | Target Behavior | Default FanPercentAdjust Value |
| :---- | :---- | :---- |
| quiet | Maximum noise reduction when thermals are optimal. | 50 |
| normal | Moderate cooling enhancement upon crossing warning limits. | 25 |
| safe | Standard firmware control; zero offset bias during critical events or failures. | 0 |

*Note: Per HPE iLO logic, higher offset values translate to a quieter fan profile within this service's architecture.*

## **Recommended Sensors & Default Thresholds**

The installer pre-selects the following reference sensors when detected on the host:

| Sensor | Warning Threshold | Critical Threshold |
| :---- | ----: | ----- |
| 01-Inlet Ambient | 35°C | 40°C |
| 02-CPU 1 PkgTmp | 75°C | 85°C |
| 05-Chipset | 75°C | 85°C |
| 17-BMC | 75°C | 85°C |
| 20-PCI 1 Zone | 65°C | 75°C |
| 21-M2 Zone | 60°C | 70°C |
| 22-Sys Exhaust 1 | 55°C | 65°C |

## **Requirements**

* HPE ProLiant Gen10/Gen11 server with active Redfish network access (iLO 5/6).
* Functional Redfish endpoint at `/redfish/v1/Chassis/1/Thermal/` exposing `Oem.Hpe.FanPercentAdjust`.
* Root privileges on the target host OS.
* One of: Debian/Ubuntu, RHEL/Rocky, Fedora, or OpenSUSE Leap.

The installer automatically installs its prerequisites: `whiptail`/`newt`, `curl`, `jq`, `openssl`, `python3`, `python3-pip`, and HPE's `python-ilorest-library`.

> **TLS note:** Verification succeeds cleanly when you connect using the name or IP present in the iLO certificate's subject/SAN. If the default iLO certificate does not include the IP you connect by, connect via the certificate's hostname or regenerate the iLO certificate with the correct SAN — the service intentionally does **not** weaken verification.

## **Installation & First Run**

Execute the installer script with root privileges:

```
chmod +x hpe-fan-watch-installer.sh
sudo ./hpe-fan-watch-installer.sh
```

### **Setup Wizard Steps**

1. **Target definition:** Specify the iLO hostname or IP address.
2. **TLS pinning:** Fetch and confirm the iLO certificate fingerprint (or supply a trusted CA/PEM path).
3. **Credentials:** Generate a dedicated least-privilege iLO service account or input existing credentials.
4. **Compatibility check:** Probe iLO generation and `FanPercentAdjust` availability.
5. **Sensor selection:** Choose specific hardware sensors to track.
6. **Threshold definition:** Set warning and critical temperature targets.
7. **Polling frequency:** Set the monitoring interval.
8. **Tuning:** Adjust baseline values for quiet, normal, and safe modes.
9. **Failure threshold:** Set how many consecutive Redfish failures force SAFE (1–10).
10. **Policy:** Configure re-assert-on-start, revert-on-exit (default ON), and journal logging.

## **Existing Installation Management**

If the installer detects existing components, it routes to an interactive management menu:

| Menu Option | Action Performed |
| :---- | :---- |
| **Reconfigure** | Falls through to the full setup wizard. |
| **Edit config** | Opens the config in `$VISUAL` → `$EDITOR` → `nano`/`vim`/`vi`; offers to restart afterward. |
| **Restart service** | Runs `systemctl restart` and reports status. |
| **Show status** | Runs `hpe-fan-watch.sh --status` and displays the dashboard in a scrollable box. |
| **Tail logs** | Drops to `journalctl -u … -n 40 -f`; Ctrl+C returns to the menu. |
| **Uninstall** | Comprehensive teardown (see below). |

### **Teardown Sequence**

1. Double-confirmation safety prompt.
2. Stops and disables the systemd service (failures surfaced via `whiptail`).
3. **Optionally deletes the iLO service account** via Redfish, after prompting for an iLO administrator login.
4. Deletes all installed files: monitor, unit, config, credentials, pinned certificate, and helper.
5. Triggers `systemctl daemon-reload`.
6. Offers to purge the state directory (`/var/lib/hpe-fan-watch`).

## **File System Footprint**

| Path | Purpose | Mode |
| :---- | :---- | :---- |
| `/usr/local/sbin/hpe-fan-watch.sh` | Core monitor script | `0750` |
| `/usr/local/lib/hpe-fan-watch/redfish_ctl.py` | Official-library control-plane helper | `0755` |
| `/etc/systemd/system/hpe-fan-watch.service` | Systemd unit (watchdog-protected) | `0644` |
| `/etc/hpe-fan-watch/config` | Configuration (no secrets) | `0600` |
| `/etc/hpe-fan-watch/ilo.crt` | Pinned iLO TLS certificate | `0644` |
| `/etc/hpe-fan-watch/ilo.cred` | Encrypted credentials (`systemd-creds` mode) | `0400` |
| `/etc/hpe-fan-watch/ilo.env` | Root-only credentials (fallback mode) | `0400` |
| `/var/lib/hpe-fan-watch/` | State/cache directory | `0750` |

## **CLI Usage Modes**

The core script supports manual execution via the following flags:

```
# Run a single evaluation cycle and exit
/usr/local/sbin/hpe-fan-watch.sh --once

# Run continuously as a daemon (handled by systemd)
/usr/local/sbin/hpe-fan-watch.sh --daemon

# Print the formatted sensor/fan status dashboard
/usr/local/sbin/hpe-fan-watch.sh --status

# Evaluate and log without writing anything to the iLO
/usr/local/sbin/hpe-fan-watch.sh --dry-run --once
```

## **Limitations & Disclaimer**

* **Support status:** This software operates independently as a Redfish-based workaround and is not an officially supported HPE AMSD deployment.
* **Firmware compliance:** Proper execution depends on the firmware accepting `Oem.Hpe.FanPercentAdjust`. iLO 4 (Gen8/Gen9) does not expose this control; the installer warns when it cannot be driven.
* **Validation requirement:** Validate system thermals under sustained production workloads before deploying aggressive noise-reduction profiles.

**Use at your own risk.** Changing fan profiles impacts hardware cooling. Thoroughly test configurations against your environmental profiles and firmware baselines before broad production rollouts.

## **License**

This project is open-source. Insert your preferred licensing terms here (e.g., MIT, GPLv3).

### **Screenshot**

<img width="755" height="462" alt="Setup" src="https://github.com/user-attachments/assets/55449ffa-6f17-4926-b116-f11352a00f65" />
<img width="755" height="403" alt="Setup2" src="https://github.com/user-attachments/assets/7f4cd0fa-5c69-480f-b749-ac8eaebd48ef" />
<img width="755" height="402" alt="Setup3" src="https://github.com/user-attachments/assets/955f9235-8923-4b9e-916e-abe5373f9c8e" />
<img width="755" height="522" alt="Setup4" src="https://github.com/user-attachments/assets/b69213b7-81a8-4d50-8788-ce7e5ee37f41" />
<img width="755" height="478" alt="Setup5" src="https://github.com/user-attachments/assets/e90dd1a6-ecd4-4cfe-a7bc-4abafd313f46" />
<img width="755" height="581" alt="Setup6" src="https://github.com/user-attachments/assets/7690fc98-4d30-4435-8fa1-e28eed6b1997" />
<img width="755" height="530" alt="Setup7" src="https://github.com/user-attachments/assets/971aafa5-ebf3-47a9-875c-a5172b330dbc" />
