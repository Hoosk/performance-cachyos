# CachyOS / Arch Linux Standby & Power Optimizer

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Platform: Arch / CachyOS](https://img.shields.io/badge/Distro-CachyOS%20%7C%20Arch%20Linux-1793d1)](https://cachyos.org/)
[![Shell: Bash](https://img.shields.io/badge/Shell-Bash-4EAA25)](https://www.gnu.org/software/bash/)

A modular, hardware-agnostic CLI toolkit for **CachyOS** and **Arch Linux** laptops designed to diagnose and eliminate standby battery drain (`s2idle` / Modern Standby / `S0ix`, ACPI `S3`, and `suspend-then-hibernate`).

---

## Why Does My Linux Laptop Drain Battery With the Lid Closed?

Modern x86 laptops (especially Intel 12th–15th Gen / Core Ultra Meteor Lake & AMD Ryzen) rely on **`s2idle` (Modern Standby / S0ix)** instead of traditional motherboard-enforced **ACPI S3 (`deep`)** sleep.

In `s2idle`, the system stays in ACPI state `S0` while software freezes user tasks, relying on **every PCIe/I2C device** entering deep runtime power states (`D3cold` / PCIe `L1.2`) so the SoC can reach hardware low-power residency (`Package C10` / `SLP_S0`). In practice, three common issues ruin standby battery life on Linux:

1. **Spurious I2C & PCIe Wakeups:** Touchpads (`i2c_hid_acpi`) and USB/Thunderbolt root ports remain configured as wakeup sources, firing hundreds of thousands of interrupts and waking the SoC inside your backpack.
2. **Blocked S0ix Residency:** Default PCIe ASPM policies (`[default]`) and PCI devices locked in `power/control=on` prevent NVMe SSDs and Wi-Fi controllers from entering `L1.2`, blocking hardware `S0ix` residency completely.
3. **ZRAM-Only Setups Cannot Hibernate:** Distributions like CachyOS ship with fast `zram` in RAM by default and no disk-backed swap. When `systemd` attempts `suspend-then-hibernate`, it silently falls back to `suspend`-only, draining 2–3.5 W continuously instead of dropping to **0.0 W** after a couple of hours.

---

## Key Features

- **Deep Telemetry & Diagnostics (`--analyze`):**
  Inspects `/sys/power/suspend_stats`, `S0ix` hardware vs. software residency times, noisy `/sys/class/wakeup` interrupt sources, PCIe ASPM policy, NVMe `D3cold` readiness, swap/ZRAM priorities, and disk caches without requiring root.
- **Spurious Wakeup & Runtime PM Udev Rules (`--udev`):**
  Dynamically detects I2C HID touchpads and PCIe/USB/Thunderbolt bridges with wakeup enabled and generates `/etc/udev/rules.d/99-standby-optimizer.rules` to silence them while **preserving** the ACPI Time & Alarm Device (`ACPI000E` / `rtc0`) and Lid switch required for `suspend-then-hibernate`. Enables Runtime PM (`auto`) across auxiliary SoC devices.
- **Zero-Interference Hibernation Swapfile (`--swap`):**
  Automatically provisions a dedicated Btrfs `@swap` subvolume (so root snapshots via Snapper are never blocked) or standard ext4/XFS swapfile at `/swap/swapfile` with **priority `0` (`pri=0`)**. Your fast `zram0` (`pri=100`) continues handling 100% of daily desktop workloads in RAM, while the disk swapfile is reserved strictly for hibernation (`0.0 W` drain).
- **Systemd `suspend-then-hibernate` & S3 Live Testing (`--systemd`, `--test-deep`):**
  Configures clean drop-in overrides under `/etc/systemd/sleep.conf.d/` and `/etc/systemd/logind.conf.d/`. Includes a safe 15-second `rtcwake` hardware test (`--test-deep`) for laptops whose BIOS still exposes `deep` (S3).
- **Multi-Bootloader Kernel Tuning (`--bootloader`):**
  Auto-detects **Limine** (`/etc/default/limine`), **GRUB** (`/etc/default/grub`), and **systemd-boot** (`/boot/loader/entries/*.conf`), injecting `pcie_aspm.policy=powersupersave` (and optional `mem_sleep_default=`) idempotently with automatic backups.
- **Disk & Package Cache Cleanup (`--clean`, `--clean-cargo`):**
  Reclaims disk space before swapfile creation by cleaning `pacman` caches (`paccache`), AUR build clones (`paru` / `yay`), and optionally scanning for bloated Rust `target/` build directories.
- **Desktop Keyring Integration (`--setup-keyring`):**
  Integrates with `libsecret` (`secret-tool` / GNOME Keyring / KeePassXC) and KDE `KWallet` via `SUDO_ASKPASS` so you can run `./optimize-standby.sh` directly without prepending `sudo`.
- **One-Command Rollback (`--revert`) & Dry-Run Mode (`--dry-run`):**
  Preview every file and command before touching your system, or revert all changes cleanly at any time.

---

## Project Structure

```text
performance-cachyos/
├── optimize-standby.sh        # Main CLI entrypoint (flags & interactive TUI menu)
├── LICENSE                    # MIT License
├── README.md                  # Documentation
└── lib/
    ├── common.sh              # Logging, dry-run wrapper, backups, hardware/FS detection
    ├── auth.sh                # Desktop keyring integration (libsecret / KWallet)
    ├── askpass-keyring.sh     # SUDO_ASKPASS helper script
    ├── analyze.sh             # Read-only hardware, S0ix residency & wakeup audit
    ├── cleanup.sh             # Pacman, Paru/Yay & optional Rust Cargo target cleanup
    ├── udev_power.sh          # Dynamic udev rules for I2C/PCIe wakeups & Runtime PM
    ├── swap_hibernate.sh      # Btrfs (@swap subvol) & ext4 swapfile provisioning
    ├── systemd_sleep.sh       # systemd-sleep & systemd-logind drop-ins + S3 rtcwake test
    ├── bootloader.sh          # Limine, GRUB & systemd-boot kernel parameter updater
    └── revert.sh              # Full rollback & uninstaller
```

---

## Quick Start

### 1. Clone the repository

```bash
git clone https://github.com/Hoosk/performance-cachyos.git
cd performance-cachyos
```

### 2. Run a non-invasive system audit (no root needed)

```bash
./optimize-standby.sh --analyze
```

### 3. Preview all optimizations in Dry-Run mode

```bash
./optimize-standby.sh --all --dry-run
```

### 4. Apply all optimizations

Run the interactive menu:

```bash
./optimize-standby.sh
```

Or run the full automated pipeline (with optional desktop keyring storage so you don't need `sudo` on future runs):

```bash
./optimize-standby.sh --setup-keyring
./optimize-standby.sh --all -y
```

---

## CLI Reference

```text
Usage: optimize-standby.sh [ACTIONS] [OPTIONS]

Actions:
  --analyze              Run full hardware, sleep residency, wakeup & disk diagnostic
  --all                  Run full optimization pipeline (analyze + clean + udev + swap + systemd + bootloader)
  --clean                Clean pacman cache (paccache) and AUR caches (paru/yay)
  --clean-cargo          Also run 'cargo clean' on Rust projects under user home during --clean
  --udev                 Generate & apply udev rules (disable spurious I2C/PCIe wakeups, enable Runtime PM)
  --swap                 Create & enable disk swapfile (Btrfs @swap subvol or ext4, pri=0 below zram)
  --systemd              Configure systemd-logind & systemd-sleep drop-ins (suspend-then-hibernate)
  --bootloader           Configure PCIe ASPM & sleep kernel parameters (Limine / GRUB / systemd-boot)
  --test-deep            Run a safe 15-second RTC alarm test of ACPI S3 (deep) sleep mode
  --setup-keyring        Save/update sudo password in desktop keyring (libsecret / KWallet)
  --clear-keyring        Remove saved sudo password from desktop keyring
  --revert               Revert all configurations, udev rules, drop-ins, and fstab entries

Options:
  --sleep-mode <mode>    Target sleep mode: s2idle | deep | auto (default: auto)
  --hibernate-delay <t>  Time in suspend before hibernating to disk (default: 2h)
  --swap-size <GB>       Swapfile size in GiB for hibernation (default: 16)
  --dry-run              Preview all commands and file changes without modifying the system
  -y, --yes              Non-interactive mode (assume yes to prompts)
  -h, --help             Show this help message
```

---

## Testing Hardware S3 (`deep`) vs `s2idle`

If `./optimize-standby.sh --analyze` reports that your BIOS advertises both `[s2idle] deep` in `/sys/power/mem_sleep`, you can safely test whether your laptop's firmware wakes cleanly from S3 sleep using the built-in 15-second RTC alarm test:

```bash
./optimize-standby.sh --test-deep
```

If the display, keyboard, and Wi-Fi resume cleanly after 15 seconds, you can make `deep` permanent:

```bash
./optimize-standby.sh --systemd --bootloader --sleep-mode deep
```

---

## Reverting Changes

Every modified system file (`/etc/fstab`, `/etc/default/limine`, `/etc/default/grub`, etc.) is automatically backed up to `/var/backups/standby-optimizer/` before editing. To roll back all configurations, drop-ins, udev rules, and swap mounts:

```bash
./optimize-standby.sh --revert
```

---

## License

Released under the [MIT License](LICENSE).
