# Development environment

## New chat / fresh clone

```sh
git clone https://github.com/peterpaleev/wifi-mapper.git
cd wifi-mapper
tools/doctor.sh
tools/test_core.sh
```

Open this repository as the project in Codex. Start a new chat in this project; it discovers AGENTS.md. A useful prompt is: “Read AGENTS.md and docs/STATUS.md. Implement [change], run the relevant checks, and update the handoff state.” Choose a worktree for independent work. No old chat transcript, custom model, paid API key or global plugin is required.

The tested local toolchain is Xcode 26.5 / Swift 6.3.2; the package requires Swift 6.0+, app deployment is iOS 17+. CI uses the macos-15 runner toolchain and records its actual version. Run on macOS for Xcode and actual iPhone work. Linux can build firmware and run portable parser checks; it cannot validate ARKit or iPhone USB behavior.

## iOS builds and signing

```sh
tools/build_ios.sh                  # unsigned compile; no signing secrets
cp ios/Config/Local.xcconfig.example ios/Config/Local.xcconfig
# Edit Local.xcconfig with your own team and bundle prefix.
tools/build_ios.sh --signed
```

The wrapper passes the local xcconfig explicitly. If building directly in Xcode, configure Signing & Capabilities for your own team and unique bundle IDs. Keep those personal changes out of commits. The public project uses org.example identifiers. The original maintainer's local config preserves the installed app identity.

Build outputs live in /tmp/wifi-mapper-<checkout-hash>/DerivedData, isolating worktrees and avoiding iCloud signing metadata failures. Override MAPPER_DERIVED_DATA if needed. Core tests similarly use a checkout-specific scratch path; MAPPER_TEST_SCRATCH overrides it.

For device tests, discover the current identifier with `xcrun devicectl list devices` or `xcrun xctrace list devices`, unlock the device, and run:

```sh
xcodebuild -project 'ios/wifi mapper.xcodeproj' -scheme 'wifi mapper' \
  -xcconfig ios/Config/Local.xcconfig -allowProvisioningUpdates \
  -destination "platform=iOS,id=$MAPPER_DEVICE_ID" \
  -derivedDataPath /tmp/wifi-mapper-device-tests \
  -parallel-testing-enabled NO '-only-testing:wifi mapperTests' test
```

For the outstanding USB drain check, replace the only-testing value with `wifi mapperUITests/wifi_mapperUITests/testUSBMappingDrain` and connect the ESP to the iPhone. Only one task owns the physical rig at a time. Do not install/launch test runners while another survey is recording.

## ESP32 firmware

Install Git, Python 3, CMake, Ninja and platform prerequisites from ESP-IDF documentation. Then:

```sh
tools/bootstrap_firmware.sh
tools/build_firmware.sh build
```

The bootstrap verifies exact ESP-IDF commit fcae32885b0296b32044cb99ecbdc50d98dddb83 (v5.5.1). The manifest and lockfile pin managed components. IDF_PATH can point to a shared SDK outside a worktree; export it for each shell/task. Bootstrap does not flash. With explicitly requested firmware installation, use the current ROM serial port: `tools/build_firmware.sh -p "$MAPPER_SERIAL_PORT" flash`.

Runtime USB becomes Ethernet. Hold BOOT, press/release RESET, release BOOT to enter ROM flashing mode. Prefer a checkout outside cloud-synced directories. Do not change partitions or erase calibration/data while doing unrelated work.

## Checks and hardware evidence

- `tools/test_core.sh`: C ASan/UBSan and randomized parsing; Swift protocol/clock/spatial tests.
- `tools/build_ios.sh`: unsigned app compile.
- `tools/build_firmware.sh build`: pinned firmware compile.
- `python3 tools/usb_probe.py --duration 60`: exclusive real USB sensor smoke test, ESP connected to Mac. Uses Python standard library.
- `python3 tools/check_public.py`: staged/tracked artifact and common secret-pattern checks; also manually review `git diff --cached`.

CI runs core tests, unsigned iOS build and firmware build. It does not flash hardware, exercise AR, prove positional accuracy or run personal signing. Keep captured reports under ignored .build/ or docs/local/; publish aggregate evidence in TESTING.md.

## Cloud tasks

Connect the GitHub repository in the Codex cloud environment UI if you want cloud work. Repository publishing alone does not grant that integration access. Cloud containers are suitable for docs, C/protocol changes and firmware builds; use macOS for iOS validation. Configure a setup script to install the required platform packages and run tools/bootstrap_firmware.sh for firmware tasks. SDK download requires setup-phase network access. For maintenance, repeat bootstrap with the same pin. Do not assume shell exports survive setup; set IDF_PATH in environment settings or use the repository-default path. No project secrets are needed for these builds.

See CODEX_PRACTICES.md for the official sources and repository decisions.
