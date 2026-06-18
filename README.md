# **HPE iLO Fan-Watch Installer**

An interactive installer and systemd-based thermal watchdog for **HPE Gen11 servers**. It utilizes the **iLO Redfish API** to optimize fan speeds and reduce unnecessary noise while maintaining safe thermal operating limits.  
This tool is designed for deployments where the host OS lacks a compatible HPE AMS/AMSD package path, but iLO Redfish access is available and supports the FanPercentAdjust property on the thermal endpoint.

## **Overview**

The installer configures a local service that monitors the iLO thermal endpoint, evaluates designated hardware sensors, and dynamically updates the FanPercentAdjust value based on real-time temperature data.

### **Operational Workflow**

* **quiet:** Applied when all monitored sensors remain below warning thresholds.  
* **normal:** Applied when one or more sensors cross a warning threshold.  
* **safe:** Enforced immediately if any sensor crosses a critical threshold or if Redfish API connectivity encounters repeated failures.

The service is engineered to **fail-safe**. Escalation to maximum cooling occurs instantly, while de-escalation back to quieter modes utilizes hysteresis to prevent rapid fan speed oscillation (fan flapping).

## **Problem Statement**

On certain HPE platforms—particularly those running unsupported operating systems or non-standard hardware configurations—system fans may operate at unnecessarily aggressive speeds despite healthy system thermals. This project offers a host-side mitigation strategy via Redfish, removing any operational dependency on the AMSD daemon.

## **Features**

* **Interactive Setup:** Driven by a whiptail-based terminal user interface.  
* **Dependency Management:** Automatically installs prerequisites (whiptail, curl, jq) on Debian/Ubuntu-based systems via apt.  
* **Account Automation:** Dynamically provisions or reuses a least-privilege iLO service account.  
* **Dynamic Inventory:** Discovers and parses the live sensor list directly from iLO prior to configuration.  
* **Granular Control:** Supports custom sensor selection along with per-sensor warning and critical thresholds.  
* **Persistent Service:** Configures a dedicated systemd service with local state caching to eliminate redundant API PATCH requests.  
* **Operational Safety:** Supports re-assertion on startup, automatic state reversion upon exit, and structured logging via syslog/journald.  
* **Diagnostic Tools:** Includes a built-in status mode for verifying parsed thermal metrics and fan states.  
* **Instance Lifecycle Management:** Detects existing installations to provide runtime shortcuts for reconfiguring, editing, monitoring, or uninstalling the service.

## **Technical Architecture**

The background daemon continuously monitors the following iLO endpoint:

`https://<ILO_HOST>/redfish/v1/Chassis/1/Thermal/`

The script extracts and processes:

* Temperatures\[\] for monitored sensor tracking.  
* Fans\[\] to log current RPM metrics.  
* Oem.Hpe.FanPercentAdjust to modify fan behavior.

### **Operating Modes**

| State | Target Behavior | Default FanPercentAdjust Value   |
| :---- | :---- | :---- |
| quiet | Maximum noise reduction when thermals are optimal. | 50 |
| normal | Moderate cooling enhancement upon crossing warning limits. | 25 |
| safe | Standard firmware control; zero offset bias during critical events or failures. | 0 |

*Note: Per HPE iLO logic, higher offset values translate to a quieter fan profile within this service's architecture.*

## **Recommended Sensors & Default Thresholds**

The installer pre-selects the following reference sensors when detected on the host:

| Sensor | Warning Threshold | Critical Threshold   |
| :---- | ----: | ----- |
| 01-Inlet Ambient | 35°C | 40°C |
| 02-CPU 1 PkgTmp | 75°C | 85°C |
| 05-Chipset | 75°C | 85°C |
| 17-BMC | 75°C | 85°C |
| 20-PCI 1 Zone | 65°C | 75°C |
| 21-M2 Zone | 60°C | 70°C |
| 22-Sys Exhaust 1 | 55°C | 65°C |

## **Requirements**

* HPE ProLiant Gen11 server with active Redfish network access.  
* Functional Redfish endpoint path at /redfish/v1/Chassis/1/Thermal/.  
* Root privileges on the target host OS.

## **Installation & First Run**

Execute the installer script with root privileges:

`chmod +x hpe-fan-watch-installer.sh`  
`sudo ./hpe-fan-watch-installer.sh`

### **Setup Wizard Steps**

1. Target Definition: Specify the iLO hostname or IP address.  
2. Credentials: Generate a dedicated iLO service account or input existing credentials.  
3. Sensor Selection: Isolate specific hardware sensors for tracking.  
4. Threshold Definition: Set warning and critical temperature targets.  
5. Polling Frequency: Set the monitoring interval duration.  
6. Tuning: Adjust baseline values for quiet, normal, and safe execution modes.  
7. Policy: Configure operational behaviors like state re-assertion and teardown policies.

## **Existing Installation Management**

The script includes an automated deployment check (is\_already\_installed()). If the script detects existing components (SBIN\_PATH, UNIT\_PATH, or CONF\_PATH), it bypasses the initial wizard and routes directly to an interactive management menu:

| Menu Option | Action Performed   |
| :---- | :---- |
| **Reconfigure** | Breaks out of the menu loop and falls through to the full step-by-step setup wizard. |
| **Edit config** | Opens the configuration file in the preferred terminal editor ($VISUAL → $EDITOR → nano → vim → vi). Offers to restart the service immediately upon exit. |
| **Restart service** | Executes systemctl restart and displays the updated operational status. |
| **Show status** | Runs hpe-fan-watch.sh \--status and displays the parsed thermal data within a scrollable message box. |
| **Tail logs** | Drops out of whiptail to run journalctl \-u ... \-n 40 \-f. Pressing Ctrl+C returns cleanly to the menu interface. |
| **Uninstall** | Initiates a comprehensive teardown sequence via the \_do\_uninstall helper module. |

### **Teardown Sequence (\_do\_uninstall)**

1. Requires a double-confirmation safety prompt.  
2. Stops and disables the background systemd service.  
3. Deletes all four primary installed script and config paths.  
4. Triggers a systemd daemon-reload.  
5. Offers an optional prompt to completely purge the state directory (/var/lib/hpe-fan-watch).  
6. *Note: For safety and security reasons, the dedicated iLO service account is left intact, as deletion requires higher administrative credentials.*

## **File System Footprint**

The following assets are managed by this tool on the host machine:

* /usr/local/sbin/hpe-fan-watch.sh (Core Execution Script)  
* /etc/systemd/system/hpe-fan-watch.service (Systemd Unit Configuration)  
* /etc/default/hpe-fan-watch (Environment & Credential Store; restricted permissions)

## **CLI Usage Modes**

The core script supports manual execution via the following flags:

`# Run a single evaluation cycle and terminate`  
`/usr/local/sbin/hpe-fan-watch.sh --once`

`# Run continuously as a system daemon (handled by systemd)`  
`/usr/local/sbin/hpe-fan-watch.sh --daemon`

`# Output current thermal matrices and fan states without modifying system behavior`  
`/usr/local/sbin/hpe-fan-watch.sh --status`

## **Security Policy**

* **Credential Handling:** Administrative and service passwords are passed to curl using secure standard input parsing (curl \-K \-), preventing secrets from leaking into system process trees (ps aux).  
* **Permissions:** Configuration files contain plaintext access keys and are strictly locked to root-only read access.  
* **Privilege Minimization:** It is highly recommended to isolate permissions by provisioning a dedicated, low-privilege iLO user account restricted entirely to basic login and iLO command properties.

## **Limitations & Disclaimer**

* **Support Status:** This software operates independently as a Redfish-based hardware workaround and is not an officially supported HPE AMSD deployment.  
* **Firmware Compliance:** Proper execution depends on the underlying system firmware's ability to process and accept Oem.Hpe.FanPercentAdjust parameters.  
* **Validation Requirement:** Users must validate system thermals under sustained production workloads prior to deploying aggressive noise reduction profiles.

**Use at your own risk.** Changing fan profiles impacts hardware cooling metrics. Thoroughly test configurations against your specific environmental profiles and firmware baselines before broad production rollouts.

## **License**

This project is open-source. Insert your preferred licensing terms here (e.g., MIT, GPLv3).
