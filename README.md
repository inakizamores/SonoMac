<div align="center">

<img src="docs/icon.png" width="128" alt="SonoMac icon">

# SonoMac

**Sonos control that feels built into macOS.**

A tiny native menu bar app for your Sonos system — volume, grouping, playback and TV audio, styled like Control Center. No cloud, no account, no Electron. One 740 KB binary.

[![Latest release](https://img.shields.io/github/v/release/SistemasKitMachinery/SonoMac?label=Download&color=blue)](https://github.com/SistemasKitMachinery/SonoMac/releases/latest)
[![macOS 14+](https://img.shields.io/badge/macOS-14%2B-black)](#requirements)
[![Apple Silicon](https://img.shields.io/badge/Apple%20Silicon-native-black)](#requirements)
[![Swift](https://img.shields.io/badge/Swift-SwiftUI-orange)](Sources/SonoMac)
[![License: MIT](https://img.shields.io/badge/License-MIT-green)](LICENSE)

</div>

---

## Install

**[⬇ Download SonoMac.dmg](https://github.com/SistemasKitMachinery/SonoMac/releases/latest/download/SonoMac.dmg)** — open it, drag SonoMac into Applications, launch it.

> **First launch:** SonoMac is open source and not notarized by Apple (no paid developer account), so macOS will show *"Apple could not verify SonoMac"*. Open **System Settings → Privacy & Security**, scroll down, and click **Open Anyway** — needed exactly once.

Prefer to skip that dialog? This one-liner downloads, installs and launches it directly:

```bash
curl -fsSL -o /tmp/SonoMac.zip https://github.com/SistemasKitMachinery/SonoMac/releases/latest/download/SonoMac.zip && ditto -xk /tmp/SonoMac.zip /Applications && xattr -dr com.apple.quarantine /Applications/SonoMac.app && open /Applications/SonoMac.app
```

When macOS asks for **Local Network** access, click **Allow** — that's how SonoMac finds your speakers. That's the entire setup.

## Features

- 🎚️ **Master volume** — one slider moves every room proportionally; click the speaker glyph to mute everything
- 🔊 **Per-room & per-speaker volume** — Control-Center-style capsule sliders, mute on the glyph
- ⚖️ **Even Out Volumes** — one click sets every speaker in a group to the group average (70/60/50 → 60/60/60)
- ⏯️ **Playback** — play, pause, previous, next, with a now-playing line per room
- 📺 **TV Audio** — switch home-theater speakers (Arc, Beam, Ray, Playbar/Playbase, Amp) to TV input and back
- 🔗 **Grouping** — right-click a room to *Group With…* another, separate speakers, or group/separate all rooms at once
- 🚀 **Start at Login** — lives quietly in the menu bar, ready before you are

## Design

SonoMac is built to disappear into macOS:

- **Native everywhere** — SwiftUI `MenuBarExtra`, system panel chrome, SF Symbols, system materials and semantic colors. Dark mode, accent colors and accessibility settings just work.
- **Light for real** — single arm64 binary, ~740 KB on disk, idle at 0% CPU. It polls speakers only while the panel is open; closed, it does nothing at all.
- **Local only** — talks directly to your speakers over your LAN using the same UPnP API the Sonos app uses (`AVTransport`, `RenderingControl`, `GroupRenderingControl`, `ZoneGroupTopology`). Nothing ever leaves your network. No analytics, no accounts, no telemetry.
- **Instant** — last-known speaker addresses are cached, so reconnecting is immediate; multicast discovery is the fallback.

## Requirements

- macOS 14 Sonoma or later (Apple Silicon)
- A Sonos system on the same local network

## Build from source

Only Xcode Command Line Tools needed (`xcode-select --install`):

```bash
git clone https://github.com/SistemasKitMachinery/SonoMac.git
cd SonoMac
./build.sh --install
```

`./build.sh` builds `build/SonoMac.app`; `--install` also copies it to /Applications and launches it. `./release.sh` produces the distributable `.dmg` and `.zip`. Releases are built automatically by GitHub Actions when a `v*` tag is pushed.

## License

[MIT](LICENSE) — do whatever you like with it.
