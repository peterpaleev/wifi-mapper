# Current project status

Updated 2026-09-08. Version 1.1 is an experimental spatial Wi-Fi instrument.

Implemented: ESP32-S3 2.4 GHz management-frame capture; USB Ethernet to iPhone; live signal diagnostics and channel controls; ARKit local XYZ tracking; camera trail colored by selected AP RSSI; top-down trace; optional height-filtered IDW heatmap; raw SQLite surveys, reopen and ZIP export. BLE endpoint exists in firmware; iPhone BLE controls are not implemented.

Verified on ESP32-S3 N8R8 and iPhone 17 Pro: a walk produced 220 raw observations, 193 aligned samples, approximately 32.6 m of trajectory and 805 heatmap cells. No sensor queue/ring drops. Clock freshness regression fixed and checked. See TESTING.md for scope and limitations.

## Next concrete verification
The immediate stop-request flag fixes a race where firmware drain confirmation arrived before the throttled UI snapshot showed stopping. It builds and was installed. The first hardware UI attempt failed on an unrelated accessibility selector, which was removed; the next attempt was canceled because the phone locked. Run `testUSBMappingDrain` with the ESP attached and the phone unlocked. Do not report it as passed yet.

## Limitations / possible future tasks
- Foreground recording only; relative coordinates and an uncalibrated antenna offset.
- Heatmap estimates have 1.5 m support, no wall model; no GPS registration or reconstructed floor plan.
- Longer accuracy/drift and high-density RF soak tests remain useful.
- Hardware iOS simulator boot failed on the original machine; real-device tests were used.
- Review bounded display-history behavior for long surveys; full raw data remains on disk.
- App icon, release distribution and BLE app mode remain future work, not completed features.

For a new chat: read AGENTS.md, inspect git status, choose the requested task, and update this file if the project's actual state changes. Do not implement this entire backlog unless requested.
