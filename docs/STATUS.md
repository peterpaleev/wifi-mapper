# Current project status

Updated 2026-09-08. Version 1.2 is an experimental spatial Wi-Fi instrument.

Implemented: ESP32-S3 2.4 GHz management-frame capture; USB Ethernet to iPhone; live diagnostics/channel controls; ARKit local XYZ tracking; signal-colored camera trail and top-down map; durable SQLite surveys, reopen and ZIP export. BLE endpoint exists in firmware; iPhone BLE controls are not implemented.

New in 1.2: classified LiDAR floor/wall mesh layers; optional foreground location recording and manual geographic registration; native Apple Maps satellite overlays; configurable heatmap grid, radius, measured-only/IDW/nearest/Gaussian fill, palettes, dBm range and opacity. Schema 2 preserves compressed mesh observations and geographic revisions while reading schema 1 surveys. See SPATIAL_LAYERS.md for research, usage and limits, and TESTING.md for exact evidence.

## Next concrete verification

Run the LiDAR/GPS acceptance checklist in SPATIAL_LAYERS.md on a physical device. Simulator fixtures validate UI/data flow only. Check geometry persistence overhead during a sustained ESP/iPhone walk, denied location permission, weak GPS, north calibration and satellite attribution. No real LiDAR or GPS accuracy result is claimed for 1.2.

The existing immediate stop-request flag fixes a race where firmware drain confirmation arrived before the throttled UI snapshot showed stopping. Its physical `testUSBMappingDrain` retest is still pending: the previous attempt was canceled because the phone locked. Use an unlocked iPhone with the ESP attached; do not report it as passed until rerun.

## Existing hardware evidence and limitations

- Version 1.1 was verified on ESP32-S3 N8R8 and iPhone 17 Pro: 220 raw observations, 193 aligned samples, approximately 32.6 m of trajectory and 805 heatmap cells, with no sensor queue/ring drops. This predates the new mesh/GPS features.
- Foreground recording only; uncalibrated antenna offset. Raw AR coordinates remain local.
- Mesh is approximate, classified and sampled; it is not a complete architectural floor plan. No RoomPlan integration or wall-aware RF propagation.
- Geographic placement uses GPS and a manually set bearing, with visible accuracy. It is not automatic or precision indoor registration. Saved unregistered surveys remain local maps.
- Heatmap fill is radius-bounded estimation, not measurement. The work budget may fall back to measured bins.
- Long accuracy/drift, storage overhead and high-density RF soak tests remain pending.
- App Store/TestFlight distribution, app icon and BLE app controls remain future work. GitHub releases distribute source; personal signing stays local.

For a new chat: read AGENTS.md, inspect git status, choose the requested task, and update this file when evidence changes.
