#  Changelog

### 22 May 2026: Release v1.0.0 (aarch64, C compiled components)

- **Architecture:** native aarch64 support for Qualcomm IPQ807x / NSS platform
- **Performance:** `ct_dump_all_full()` fully migrated from shell to C
  - **Speed improvement: ~30s ->  <100ms for 1000+ connections**
- **Hybrid design:** UI remains in shell , heavy parsing in C (fast)
- **APK:** aarch64-only, includes both shell scripts and compiled binary, ccompiled with GitHub Actions for transparency



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
