# Shell Manager

**A root-free Android module manager** — no flashing, no bootloader unlock. It obtains shell privileges
through the system's built-in **Wireless debugging**, then runs all kinds of **root-free modules** on top of
a self-contained runtime + sandbox + write-ahead snapshot framework.

> Positioned between Shizuku / APatch and module frameworks: it is not just "granting an app elevated
> privileges", but a module runtime that can run long-term, be managed, and be **rolled back** —
> and the entire flow from pairing to deployment needs no computer.

---

## The Problem It Solves

System-level tweaks on Android (battery saving, performance scheduling, animation speed, privacy switches)
traditionally require Root + Magisk modules. But Root has a high barrier, carries risk, and voids warranties.
Root-free solutions (Shizuku / APatch) can obtain shell privileges, yet **have no usable module ecosystem** —
scripts are scattered everywhere, there is no unified lifecycle management, and once something breaks there
is no way back.

This project combines three things:

| Capability | Description |
|---|---|
| **Self-contained adb** | adb binary bundled inside the app — it pairs, connects, and launches the framework itself, with no computer involved at any point |
| **Module runtime** | A shell framework: start/stop, conflict detection, sandbox accounting, configuration, logging, boot autostart |
| **Safety net** | Write-ahead snapshots: the original value is recorded before a module touches anything, and the app can restore with one tap |

---

## Key Features

### Onboarding (entirely on the phone)

```
① Pair device       Enter the pairing code in the notification (port auto-discovered via mDNS)
② Deploy framework  Framework bundle is built into the app: deploy / repair / reset in one tap
③ Set access key    Choose your own key (WebUI authentication, APatch style)
   ↓
Framework running → install modules → manage
```

### UI

- **Theme**: Dark / Light / **Follow system** (light mode is an independent palette, not a simple inversion)
- **Language**: Simplified Chinese / English / Follow system — covers navigation, home, settings, onboarding, about
- **First-run guide**: Three pages — What this is → Risk notice → **First activation wizard**
  (live checklist: notification/storage permissions, device pairing, framework deployment, access key — each checked against real state)
- **About**: Project URL and author, openable with one tap

### Module Management

- **Start/stop**: Guard loops for long-running modules, lock and process-tree management
- **Configuration**: Modules declare `config.prop` and the app generates a settings page automatically; changes take effect within one cycle at most
- **Actions**: `action.sh` support (Magisk-style "Action" button)
- **Conflict detection**: Modules declare exclusive resources (`settings`/`setprop`/`svc`…); conflicting modules are refused
- **Logs**: Framework logs, module stdout/stderr, and module-written logs, viewed in one place
- **Install**: Import `.iwp` / Magisk-style module zips from phone storage, with a content audit before install

### Compatibility Layer (Magisk / KernelSU / AxManager-style modules)

Modules from these three frameworks share the same structure (`module.prop` + `service.sh` + `action.sh`) and are adapted automatically on install:

| Original framework concept | How this framework handles it |
|---|---|
| `module.prop` | Generates equivalent metadata (including `runtime=0` to mark long-running modules) |
| `service.sh` | Generates a compatibility entry wired into this framework's startup flow |
| `post-fs-data.sh` | Best-effort execution at startup (there is no pre-mount stage without root; the semantic difference is documented) |
| `action.sh` / `uninstall.sh` | Supported as-is |
| `disable` flag | Checked by the compatibility entry at startup |
| `MODDIR` / `AXERONDIR` env vars | Exported automatically |
| `webroot/` per-module WebUI | Served by the framework at `/mod/<module>/`, opened in an in-app WebView with a KernelSU-compatible `ksu` bridge injected |
| BusyBox applet assumptions | Framework ships BusyBox (358 applets); module `PATH` points to it first |

**Explicitly unsupported**: systemless mounts, Zygisk / kernel-level modules, and modules requiring `su` — these are physically impossible without root.
Installation performs a **pre-check** and reports a verdict (likely compatible / needs Root / undetermined) with reasons.

### Safety Net: Write-Ahead Snapshots and One-Tap Restore

The biggest fear in root-free tinkering is not "no effect" but **breaking something with no way back**.
The framework adds **one step** to the sandbox's write interception points:

**Before a system resource is written for the first time, its original value is recorded.**

```
$IWPHONE_ROOT/modsnap/<module>.snap
settings put global window_animation_scale '1.0'   # [global.window_animation_scale]
```

Each line is itself a directly executable restore command. Tapping "Restore" in the app first shows the list
(**current value → restore value**); after confirmation, modules are stopped before restoring — a running
module's guard loop would otherwise simply write the value back.

**Uninstalling a module does not delete its snapshot**: the module can be removed, but the settings it changed
can still be restored (Settings → Snapshot history, including "orphan snapshots" from uninstalled modules).

---

## Architecture

```
┌─────────────────────── App (Flutter + Kotlin) ───────────────────────┐
│  UI: Home / Modules / Logs / Settings                                │
│  Kotlin: self-contained adb · pairing (NSD + notification code entry) │
│          · framework deployment · boot autostart · WebView            │
└───────────────────────────────────┬───────────────────────────────────┘
                    local adb (127.0.0.1:5555)
                                    │
┌───────────────────────────────────▼───────────────────────────────────┐
│  Framework (runs as shell: /data/local/tmp/iwphone_modrunner_v3_slim)  │
│  Daemon · module lock · sandbox (accounting + write-ahead snapshots)   │
│  · conflict detection · WebUI (Python runtime)                         │
└───────────────────────────────────┬───────────────────────────────────┘
                    modules run as shell, sandbox injects into their shell
                                    │
┌───────────────────────────────────▼───────────────────────────────────┐
│  Modules (work/<module>/): native iwphone modules / Magisk-style       │
│  modules (adapted by the compatibility layer)                          │
└─────────────────────────────────────────────────────────────────────────┘
```

### Three Key Designs

**1. Self-contained adb, no computer needed**
The app bundles the adb binary using the `jniLibs` trick (avoiding `noexec` restrictions), with keys stored in
the app's private directory. Pairing uses mDNS to discover the pairing port plus notification-based code entry;
the connection port is fixed to `persist.adb.tcp.port=5555`, surviving reboots, with `BOOT_COMPLETED` +
JobScheduler as a fallback for autostart.

**2. Two-layer sandbox interception**
Module writes to system configuration are intercepted at two layers for accounting and snapshots:

| Layer | What it catches | What it misses |
|---|---|---|
| Shell function wrappers | Bare command names (`settings`, `svc`, `cmd`…) | Invocations resolved through `PATH` |
| `PATH` wrapper scripts (`sbxbin/`) | `env` / `sh -c` / `command` / variable-built paths | Absolute paths, native binaries, `service call` |

Missed forms are **neither accounted nor snapshotted** — this is stated honestly in the docs, and the install
pre-check warns about it.

**3. Access key (WebUI authentication)**
The framework WebUI exposes `/api/shell` (executes commands as shell) and listens on `127.0.0.1` — **any app on
the same device with network permission can reach the loopback port**. Therefore:

- The key is **optional**: it works without one (the server allows requests), but the loopback port is then open
  to other apps on the device; setting a key tightens this. A one-time advisory prompt appears on first launch,
  and "Not now" dismisses it permanently
- The key is chosen by the user (APatch style, ≥8 characters) and pushed via `adb push` to `state/webui_token`
  (mode 600, owned by shell)
- The server reads it by mtime → **changing the key does not require restarting the WebUI**
- The app process cannot read that file (600) and can only read/write it through adb — so "obtaining the key"
  inherently requires "pairing already completed"

---

## Repository Layout

```
README.md / LICENSE          Repository docs and license (GPL-3.0)
framework/                   Framework source (readable, editable, re-packable)
  ├── Main.sh iwphone.sh     Daemon and command entry
  ├── core.sh env.sh         Module lifecycle / global variables
  ├── sandbox.sh             Runtime accounting sandbox + write-ahead snapshots
  ├── conflict.sh            Exclusive resource conflict detection
  ├── compat.sh              Magisk / KernelSU / AxManager compatibility layer
  ├── mod_install/run/stop   Install, run, stop
  ├── restore_snapshot.sh    Snapshot restoration
  ├── module/                Bundled modules (.iwp)
  ├── webui/                 Bundled WebUI (Python) + frontend pages
  └── tools/                 Runtime build, framework.bin packaging
lib/                         Flutter side
  screens/                   Home / Modules / Install / Config / Snapshots / Logs / Settings / Terminal / Autostart / Resources
  services/                  WebUI client · autostart channel · key management · system info · shell execution
  widgets/                   Shared widgets (snapshot list, key dialog, navigation bar…)
  models/ theme/             Data models and themes
android/app/src/main/kotlin/ Kotlin side (10 files)
  AdbBootstrap.kt            Self-contained adb: pairing / connect / fixed port / deploy framework / push key
  AutostartChannel.kt        Flutter ↔ native bridge (~30 methods)
  PairingNsd.kt              mDNS pairing-port discovery
  PairingNotify.kt/.Receiver Pairing code entry in the notification
  ModuleWebUIActivity.kt     Per-module WebUI (injects the ksu bridge)
  BootReceiver / AutostartJobService   Boot autostart and fallback
doc/
  iwphone_module_dev.md      **Module development guide** (13 chapters: from minimal module to compatibility layer, snapshots, auth)
  iwphone_conflict_v1.md     Conflict detection design
android/app/src/main/assets/
  framework.bin              Framework bundle built into the app (framework scripts + Python runtime + BusyBox, ~14 MB)
                             ⚠ Generated from framework/; regenerate with:
                               cd framework && sh tools/build_framework_bin.sh
```

---

## Building

```bash
# Requirements: Flutter 3.x + JDK 17/21 + Android SDK
flutter pub get
flutter build apk --release
```

The artifact is `build/app/outputs/flutter-apk/app-release.apk` (~36 MB).

> **Any change under `framework/` requires re-packaging the bundled asset**, otherwise the app keeps running
> the old framework:
> ```bash
> cd framework && sh tools/build_framework_bin.sh
> ```
> Packaging requires `framework/webui/runtime/` (a ~36 MB Python runtime that is not committed);
> see [framework/README.md](framework/README.md) for how to generate it.

> The app has **zero third-party Flutter dependencies**: file picking, WebView, notification input, etc. are all
> implemented with native capabilities, reducing supply-chain risk and app size. In mainland China, configure
> pub / Gradle mirrors first.

---

## Known Limitations

An honest list of current boundaries:

- **Absolute-path invocations are not intercepted**: if a module uses `/system/bin/settings …`, native binaries,
  or `service call`, there is no accounting and no write-ahead snapshot (the install pre-check warns about this)
- **Snapshot granularity**: `settings` / `appops` produce real snapshots; `svc` / `pm` rely on reverse-verb
  inference rather than state snapshots
- **The compatibility pre-check is a static scan**: it can flag "may need root" but cannot guarantee it;
  keywords inside comments also match (deliberately conservative)
- **No support for systemless mounts / Zygisk / kernel-level modules**: physically impossible without root
- **i18n covers all UI text**: navigation, home, modules, install, logs, terminal, resource usage,
  snapshots, framework config, module config, autostart and settings all ship Chinese and English
  strings; runtime messages returned by the framework/WebUI (e.g. module stdout, raw backend
  errors) are shown as-is
- **Verification coverage**: the core flow was verified on Xiaomi 22011211C (MIUI + Android 14); other ROMs /
  Android versions (especially foreground-service and wireless-debugging behavior on 15/16) are untested
- **No online module repository**: modules must be imported from phone storage; there is no online distribution
  or update checking

---

## Development Status

**Verified** (end-to-end on a real device): pairing → framework deployment → module start/stop → configuration
delivery → compatibility-layer adaptation (Magisk-style sample) → write-ahead snapshot generation and one-tap
restore → sandbox bypass testing (5 of 7 invocation styles intercepted; absolute-path styles are not).

**Code complete, awaiting real-device verification** (latest round of changes, not yet run on a device):

- Pre-install package content audit (blocks zip path traversal / escaping symlinks)
- Orphan snapshots (snapshots kept after uninstall + snapshot history page)
- WebUI access key (APatch-style user-set key)

These three have passed syntax checks and cross-file reference checks but **have not been verified on a real
device**; please confirm before relying on them, and feel free to open issues.

## Roadmap

- [ ] Sandbox trial run: after install, actually run for N seconds and produce an empirical compatibility verdict
      from real write results (replacing pure static pre-check)
- [ ] Online module repository and update checking
- [ ] Snapshot improvements: turn `svc` / `pm` into real state snapshots
- [ ] Multi-device / multi-ROM compatibility matrix
- [x] Full UI English localization (all pages, see `lib/i18n/app_strings.dart`)

---

## License

This project is licensed under the **GNU General Public License v3.0** (see [LICENSE](LICENSE)).

The reason for GPL-3.0 is straightforward: `assets/framework.bin` bundles **BusyBox** (taken from the Magisk
project, GPL-3.0), and publicly distributing a binary containing GPL components carries consistent licensing
requirements. Rather than wrestling with a mixed-license setup, the whole project is unified under GPL-3.0 —
the same choice as Magisk and similar projects.

```
Copyright (C) 2026 haothtrteen

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.
```

> If you prefer your code to be usable under a more permissive license (e.g. closed-source integration),
> you can switch to MIT plus a public build that excludes BusyBox — see the notes under `doc/`.

### Third-Party Components

| Component | Origin | License |
|---|---|---|
| BusyBox (inside `framework.bin`) | Magisk project | GPL-3.0 |
| adb (`jniLibs/libadb.so`) | AOSP / platform-tools | Apache-2.0 |
| Python runtime (inside `framework.bin`) | python-build-standalone | PSF License |

### Acknowledgements and References

- **Magisk** — BusyBox binary, module format design (`module.prop` / `service.sh` / `action.sh`)
- **Shizuku** — self-contained adb, pairing flow, WebUI JS bridge ideas
- **APatch** — "user-set key" authentication interaction
- **KernelSU** — module WebUI (`webroot/` + `ksu` API) specification
- **AxManager** — root-free plugin system and BusyBox standalone mode

## Disclaimer

This project performs system-level operations through ADB privileges and **may affect device stability**.
Assess the risks yourself, and install a module only after understanding what it does. The author is not
responsible for device damage, data loss, or warranty issues.
