# Project Status, Roadmap & Changelog

## 1. Pending

### Architecture
- [ ] **Migrate most expensive functions to C** 
    - Change arch scope from noarch to most used aarch on QCA NSS platforms
      - 1. aarch64
      - 2 ?

###  Engine

- [ ] **Optimise Interface/Device Detection:** Refine and improve the detection of interfaces and network devices for absolute interface (`iface`) routing rules.
    - **New Interfaces detection**: Implement an interface watchdog mechanism triggered on each execution cycle, or introduce an explicit command-line flag (`cmd`) to allow requesting a manual interface watch.

- [ ] **Expand NSS Protocol Compatibility:** Integrate compatibility with alternative connection types and protocols managed by the Qualcomm Network Subsystem (NSS), such as **WireGuard**.

- [ ] **Enhance IPv6 Handling:** Improve the management, allocation, and tracking of IPv6 addresses, explicitly targeting Unique Local Addresses (ULA) and Global Unicast Addresses (GUA).

- [IN PROGRESS] **Enhance PPPoE / WAN Interface Handling:** Currently, hot-swapping bypasses is not possible, and furthermore, interface detection within the `pick` command fails to apply a correct per-interface rule to `pppoe-wan` (it does not accurately differentiate between `lo` and `pppoe-wan`).

- [ ] **Test NSS Acceleration Behaviour on Wi-Fi Mesh:** Investigate exactly how the NSS accelerates Wi-Fi Mesh systems (whether it operates in the same manner as local connection acceleration, either targets a specific interface or device IP... or employs a different mechanism).

### Compatibility

- [ ] **Refactor `check_root()` for a better validation:**
  - Expand the function to perform exhaustive environment checks, verifying system properties including **Board**, **SoC architecture**, **NSS Variant**, `conntrack` status, `nftables` availability, and root privileges.
  - Structure this validation to gracefully permit and support alternative NSS-enabled SoC's ( **IPQ5018**, which incorporates a very-limited NSS which also uses the ECM, but operates differently from the **ipq607x / ipq807x** platform).

  
  
### UI (User Interface)
- [ ] **Optimise Table Rendering in `watch` / `pick`:** Improve the layout and data sampling/display for tables within the `watch` and `pick` command environments.

- [ ] **Implement Terminal Resolution Warnings:** Add a better  mechanism to check and notice the shell resolution; it should halt execution and alert the user if the terminal width falls below `125c` (the optimal width is exactly `125c`).
    - [ ] **Create a Dynamic Layout Toggle for `_render_watch()`:** Implement a conditional switch during execution (when the terminal width is exactly `125c`, use fixed/exact columns; when it exceeds `125c`, automatically expand all values to fill the screen).
  
- [ ] **Introduce User Preferences for Shell Compatibility:** Implement user settings to toggle colours, visual styles, and resolution targets in order to improve compatibility across diverse shell environments.

---

## 2. Changelog

### 21 May 2026
* **feat(ui):**
  * Added PROTO name mapping for common ports (SSH, HTTP, HTTPS, DNS, WG, MYSQL, PG, MONGO, REDIS, etc...) max 6 chars.
  * Implemented terminal width check (`ui_check_width`), requires minimum 120 columns for proper UI display.
  * Improved spinner with colour cycling animation.
* **feat(conntrack):**
  * Added interface normalisation functions `_normalize_iface_display` and `_normalize_iface_rule`.
  * Normalised interface names: `local:pppoe-wan`/`pppoe-wan` -> `wan`, `local:br-lan`/`br-lan` -> `lan`, etc.
* **fix(cleanup):**
  * Fixed cursor not restoring after exit in `cmd_watch()` and `cmd_pick()` commands.
  * Fixed cleanup for orphaned `/tmp/nss-iface.*` files on trap and exit.
  * Unified temporary file cleanup in `_clean_tmp()`.
* **fix(nft):**
  * Added interface normalisation for rule validation and emission, now `wan`, `wan.20`, `pppoe-wan`, `wan_6` all belong to `pppoe-wan` for nftables rules.


### 20 May 2026
* **fix(ui):**
  * Adjusted and fixed column widths to a strict `45/45/6` layout.
  * Disabled `alt_screen` buffer to enable native terminal scrolling.
  * Integrated a visual loading indicator.
  * Corrected colour palette rendering issues specifically for the `ash` shell environment.
* **fix(watch):**
  * Added `printf "\033[2J\033[3J"` to clear both screen and scrollback buffer on each `watch` refresh.
  * Eliminated garbage/artifacts left behind after terminal scroll or PgUp/PgDown.
  * Unified header bar, hint bar, separator lines and footer messages to match exact table width.
  * Added `ui_table_width()` function to calculate total table width dynamically.
* **fix(pick):**
  * Removed pagination, now shows ALL connections at once with native terminal scroll.
  * Fixed tmpfile persistence issue that caused "Connection X not found" errors.
  * Disabled alt_screen for proper PgUp/PgDown support.
* **fix(colours):**
  * Finalised ANSI colour pattern using `ESC=$(printf '\033')` for ash/BusyBox v1.1+ compatibility.

### 19 May 2026
* **feat:**
  * Introduced initial **IPv6 support**.
  * Added a dedicated real-time debug monitor (`nss-switch debug monitor`).
  * Added debug subcommands: `env`, `ecm`, `nft`, `conntrack`, `mark`, `defunct-all`, `frontend-stop`, `frontend-restart`, `log`, `log-clear`, `rules-raw`, `script-raw`.
  * Resolved underlying issues within the `pick` command execution logic.
  * Unified the connection tracking dump tool (`ct_dump`).
  * Optimised network rule validation routines and post-execution cleanup processes.

### 14 May 2026
* **fix:** Corrected IPv6 compression logic and standardised bracketed notation `[]:` for address configurations.

### 13 May 2026
* **feat:**
  * Extended IPv6 operational support.
  * Introduced `ct_mark_all_full` logic designed for robust Local Loopback (`lo`) and Wide Area Network (`wan`) boundary management.
  * Patched and stabilised the Command Line Interface (CLI) UI layout.

### 11 May 2026
* **fix/feat:**
  * Refactored multiple instances of legacy syntax to strictly comply with `ash` shell constraints.
  * Rolled out comprehensive `conntrack` filtering support across parameters: interfaces (`iface`), source IPs (`src_ip`), destination IPs (`dst_ip`), destination ports, protocols, and auxiliary variables.
  * Drafted and committed **Blueprint 1** for the *NSS Switch Test Tool*.
