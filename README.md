# Wi-Fi Mapper — spatial surveys

An iPhone + WeAct ESP32-S3 N8R8 instrument for live 2.4 GHz Wi-Fi mapping. Version 1.2 combines ARKit position tracking, a signal-colored 3D camera trail, a top-down trace, an optional live heatmap, and the original signal inspector.

## Make a survey

1. Connect the ESP32's **native USB** connector directly to the iPhone with a data cable. Keep the board fixed relative to the phone while walking.
2. Open **Map → Connect USB**, allowing Local Network access. Tap **Start survey** and allow Camera access. Capture starts automatically when the sensor is connected.
3. Move slowly while pointing the camera at a well-lit room. Choose the Wi-Fi radio from the network menu once discovered. **Map options → Lock radio to selected network** gives denser measurements; Controls can restore channel sweep.
4. Walk through the area. **Camera** places the trail in 3D space; turn back to see the path behind you. The default palette uses red for weak signal and green for strong signal. Gray marks position tracking without aligned signal.
5. Switch to **Top down** for the live X/Z trace. Pan, pinch, fit the map, or tap a measurement. Enable **Live heatmap** using the layers button or Map options.
6. Tap **Stop & save**. The folder button reopens saved or interrupted surveys. Map options can prepare and share the full survey ZIP.

Raw positions are local to each survey's starting point. Tracking uses the iPhone camera and motion sensors. Optional GPS/manual-bearing registration places this local map geographically without changing its raw coordinates; it is not a precision floor plan. Wi-Fi observations are matched to poses using synchronized capture timestamps. Tracking gaps stay unaligned. The antenna-to-camera offset is uncalibrated.

By default, the live heatmap averages 0.25 m spatial bins and estimates values within 1.5 m of measurements. Grid size, fill algorithm, support radius and colors are configurable in Map options. It does not model walls. The default height band is ±0.75 m around the starting height; adjust it for different levels. The optional camera-trail projection is a visual plane 1.2 m below the origin, not a detected floor.

Surveys save raw Wi-Fi, raw AR transforms, clock synchronization, AP metadata, quality events, and derived aligned points incrementally in SQLite under Documents/Surveys. Recording stays in the foreground; backgrounding ends and saves the survey. Display history is bounded while the raw database retains the full recording.

## Signal inspector

**Signal**, **Networks**, **Controls**, and **Diagnostics** retain live RSSI traces, density history, channel sweep/lock, dwell controls, statistics, raw CSV export, packet metadata, loss counters, and clock diagnostics. The RSSI density view is not an RF spectrum analyzer. This ESP32 observes 2.4 GHz channels 1–11; it does not measure 5/6 GHz.

## Develop or start a new Codex chat

Read [AGENTS.md](AGENTS.md), [current status](docs/STATUS.md), and [development setup](docs/DEVELOPMENT.md). Open this repository as your Codex project; new chats can work from the checked-in context. Use a worktree for independent changes.

```sh
tools/doctor.sh
tools/test_core.sh
tools/build_ios.sh  # unsigned, macOS + Xcode
```

See [development setup](docs/DEVELOPMENT.md) for private signing configuration, pinned firmware bootstrap, device tests, and cloud-task limitations. [Codex practices](docs/CODEX_PRACTICES.md) records the official guidance behind this organization.

## Test

```sh
tools/test_core.sh
python3 tools/usb_probe.py --duration 60
```

The USB probe needs the ESP32 connected to the Mac and temporarily owns its TCP connection. It verifies real capture, channel config, rejected invalid controls, sync, ACK, replay and stop/drain. The Swift package tests run on the Mac; the same tests also belong to the iOS test target. UI tests use explicitly labeled synthetic data, activated only with `--ui-test-fixture` in Debug builds. Normal app launches never use synthetic data.

See [test evidence](docs/TESTING.md), [protocol](protocol/protocol.md), and [earlier USB test scope](docs/TEST_VERSION.md). Firmware retains a BLE diagnostic endpoint; the app control UI currently uses USB.

## Contributing and license

See [CONTRIBUTING.md](CONTRIBUTING.md) and [SECURITY.md](SECURITY.md). MIT licensed; upstream dependencies retain their own licenses.

## Spatial layers (1.2)

LiDAR floor/wall observations, optional GPS registration and an Apple Maps satellite layer are available in Map options. Heatmap settings now include resolution, fill algorithm, support radius, palettes, signal limits and opacity. [Usage, API research and limitations](docs/SPATIAL_LAYERS.md) · [Release history](CHANGELOG.md). New spatial layers require real-device acceptance; a build or simulator fixture does not establish LiDAR/GPS accuracy.
