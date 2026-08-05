# Changelog

## 1.2.0 — V1 complete
- Real UI screenshots, fully rewritten documentation, polished release notes
- Screenshot rendering mode (`--render-screenshots`) producing the README images from the actual SwiftUI views

## 1.1.x
- Per-room sound settings: bass, treble, loudness, subwoofer, surrounds, Night Sound, Speech Enhancement
- System-wide levelling (every speaker in the house to one level)
- Drift-proof group volume: snapshot-scaled distribution (`SnapshotGroupVolume`) locally and on-device — evened-out speakers stay even
- Member bars track the group and master sliders in real time
- Damped horizontal-swipe volume on every bar; smooth fill animation
- State persistence: the panel renders fully populated the instant it opens, across launches
- Volume-dependent speaker glyphs; command retry on transient network errors

## 1.0.x
- Initial release: master/room/speaker volume, Even Out Volumes, play/pause/skip,
  TV audio switching, grouping, Start at Login
- Styled DMG installer; automated releases via GitHub Actions (macOS 26 SDK guard)
