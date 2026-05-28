## 1. Pending for v.1.0.1

### Architecture

- [PARTIAL] **Migrate most expensive functions to native C arch**.
    - [X] `conntrack.sh` > `ct_dump_all_full()` fully migrated to C, `nss-ct-dump.c`.
    - [ ] **Pending evaluation of further expensive functions to migrate to C**

###  Engine

- [X] **Optimise Interface/Device Detection:** Refine and improve the detection of interfaces and network devices for absolute interface (`iface`) routing rules.
    - **New Interfaces detection**: Implement an interface watchdog mechanism triggered on each execution cycle, or introduce an explicit command-line flag (`cmd`) to allow requesting a manual interface watch.

- [X] **Expand NSS Protocol Compatibility:** Integrate compatibility with alternative connection types and protocols managed by the Qualcomm Network Subsystem (NSS), such as **WireGuard**.

- [X] **Enhance IPv6 Handling:** Improve the management, allocation, and tracking of IPv6 addresses, explicitly targeting Unique Local Addresses (ULA) and Global Unicast Addresses (GUA).

- [X] **Enhance PPPoE / WAN Interface Handling:** Currently, hot-swapping bypasses is not possible, and furthermore, interface detection within the `pick` command fails to apply a correct per-interface rule to `pppoe-wan` (it does not accurately differentiate between `lo` and `pppoe-wan`).

- [PARTIAL] **Test NSS Acceleration Behaviour on Wi-Fi Mesh:** Investigate exactly how the NSS accelerates Wi-Fi Mesh systems (whether it operates in the same manner as local connection acceleration, either targets a specific interface or device IP... or employs a different mechanism).

### Compatibility

- [ ] **Refactor `check_root()` for a better validation:**
  - Expand the function to perform exhaustive environment checks, verifying system properties including **Board**, **SoC architecture**, **NSS Variant**, `conntrack` status, `nftables` availability, and root privileges.
  - Structure this validation to gracefully permit and support alternative NSS-enabled SoC's ( **IPQ5018**, which incorporates a very-limited NSS which also uses the ECM, but operates differently from the **ipq607x / ipq807x** platform).

  
  
### UI (User Interface)
- [ ] **Optimise Table Rendering in `watch` / `pick`:** Improve the layout and data sampling/display for tables within the `watch` and `pick` command environments.

- [ ] **Implement Terminal Resolution Warnings:** Add a better  mechanism to check and notice the shell resolution; it should halt execution and alert the user if the terminal width falls below `125c` (the optimal width is exactly `125c`).
    - [PARTIAL] **Create a Dynamic Layout Toggle for `_render_watch()`:** Implement a conditional switch during execution (when the terminal width is exactly `125c`, use fixed/exact columns; when it exceeds `125c`, automatically expand all values to fill the screen).
        * First uses in `cmd_list`, using dynamic expanders
  
- [ ] **Introduce User Preferences for Shell Compatibility:** Implement user settings to toggle colours, visual styles, and resolution targets in order to improve compatibility across diverse shell environments.
