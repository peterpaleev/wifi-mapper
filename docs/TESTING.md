# Test evidence — 2026-09-07

## Passed

- ESP-IDF 5.5.1 release build, ESP32-S3, 8 MB flash and 8 MB PSRAM. Firmware binary 980,576 bytes, 36% of app partition remaining. Flash written and readback hash verified.
- Actual board enumerates as CDC-ECM Ethernet on the Mac; DHCP assigned 192.168.7.2, sensor is 192.168.7.1.
- Real USB integration: 60-second sweep followed by channel lock, disconnect/reconnect and drain. 352 observations, 2 APs, 323 unique batches, one successfully deduplicated retransmission. Zero queue drops, zero buffer drops; final ring occupancy zero. Best measured sync RTT 7.613 ms. Detailed raw evidence is kept locally; only aggregate results are published.
- C parser under AddressSanitizer and UndefinedBehaviorSanitizer: metadata, hidden/max SSID, malformed/truncated IE, fixed-width endian helpers and 100,000 randomized inputs.
- Five Swift protocol/statistics/clock tests pass on the Mac and on the user's real iPhone 17 Pro (iOS 27.0, build 24A5380h). Real-device xcresult reports five passed, zero failed/skipped.
- Signed iPhone app builds, installs and launches on the real device.
- User confirmed direct ESP32-to-iPhone USB operation after removing the overly strict wiredEthernet route requirement. Ethernet DHCP and Local Network permission were verified during diagnosis.
- Real-iPhone UI test: Signal, Networks, Controls and Diagnostics navigation, network selection and screenshot capture passed (28.98 seconds, zero failures). Five screenshots visually reviewed; density axis labeling was clarified afterward and the final signed build installed.

## In progress / remaining

- Main spatial mapping was verified with a combined ESP32 + iPhone walk; extended accuracy/soak testing remains outside this smoke test.
- Long-duration/high-density RF soak and BLE transport validation are not claimed by the initial smoke test.

The pre-existing iOS simulators stalled during boot; testing was moved to the real iPhone. Build success and synthetic UI fixtures do not establish hardware capture quality.

## Mapping version 1.1

- Twelve pure Swift tests pass: protocol, clock freshness and expired-best-sync regression, source-time pose interpolation, refusal of tracking gaps/extrapolation, measured-bin preservation, interpolation support radius, height filtering and bounded heatmap output.
- All thirteen unit tests pass on the real iPhone, including SQLite raw/aligned round-trip, duplicate preservation, unfinished survey recovery and real ZIP export signature.
- Both mapping UI tests pass on the real iPhone (36.04 seconds): synthetic trail/heatmap/options and real camera start, top-down switch, stop, and saved-survey navigation. Screenshots exported and visually reviewed.
- The real camera lifecycle saved 97 raw poses, including 14 with normal tracking, in a finalized survey database. Live walking telemetry subsequently confirmed normal tracking and approximately 5.5 m of movement.
- Evidence: `local test-results/mapping-ui-tests.json`. The UI fixture uses labeled simulated Wi-Fi; the camera lifecycle uses actual AR frames.

### Live walking regression

The first combined walk recorded 149 raw observations and 48 aligned positions. Database inspection found 95 observations without a clock estimate despite normal AR tracking. The minimum-RTT clock selector was retaining an expired sample while fresher candidates existed. The transport now chooses the lowest-RTT sample among candidates that are actually younger than 30 seconds at batch receipt. A regression test reproduces the old-low-RTT/fresh-higher-RTT case and confirms selection of the fresh sample. All 12 Mac tests pass; the signed corrected app was installed and launched on the iPhone. The combined retest passed: 220 raw observations all had fresh clock estimates, 193 aligned, including 102 after 30 seconds. Remaining observations correspond to missing/limited pose coverage. Four clock models were used. The survey covered approximately 32.6 m, generated 805 heatmap cells, and saved 1,264 raw poses. SQLite integrity_check returned ok; the manifest finalized. Sensor queue/buffer drops were zero. Evidence: `local test-results/mapping-walking-survey.json`.

The same walk exposed a separate UI-snapshot race in stop confirmation: the sensor confirmed drain before the 250 ms UI snapshot exposed the stopping flag. An immediate main-actor stop-request flag now handles that callback; a dedicated live-USB UI test checks completion before the eight-second fallback. The first live-USB test reached capture but failed on an unrelated heatmap-toggle accessibility selector before exercising stop. That unnecessary selector was removed. The rerun was canceled while waiting for the locked iPhone; the stop-confirmation fix builds and is installed, but its final hardware retest remains pending.
