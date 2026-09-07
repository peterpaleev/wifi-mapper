# Wi-Fi Mapper 1.2

ESP-IDF 5.5.1 is pinned. ESP32-S3 captures beacons and probe responses on 2.4 GHz. The Wi-Fi callback copies bounded management headers into a static FreeRTOS queue without waiting; parsing, AP registry, PSRAM buffering, and transmission run outside that callback. Queue and ring losses remain visible.

USB CDC-ECM Ethernet carries a framed TCP stream at 192.168.7.1:45832. The iPhone uses Network.framework with cellular prohibited and lets iOS select the on-link Ethernet route. A strict wiredEthernet requirement was removed after a real-iPhone routing failure. Firmware also retains BLE GATT; current app controls use USB. One transport owns capture. Observation batches remain buffered until acknowledgment.

InspectorEngine receives and parses on a serial background queue. While a survey records, each batch is committed to SQLite before its ACK is sent. A separate MappingEngine queue owns the database and alignment; heatmap computation uses another utility queue. UI snapshots publish at bounded rates, with bounded display history. Full raw observations and AR matrices remain on disk.

ARKit supplies gravity-aligned local XYZ poses at approximately 20 Hz. Source ESP timestamps are converted to phone monotonic time through four-timestamp clock synchronization. Alignment requires a fresh clock sample, RTT at most 100 ms, and bracketing normal poses in the same tracking segment no more than 250 ms apart. There is no pose extrapolation. Missing/limited tracking leaves raw observations unaligned. Sensor reboots require a new survey to preserve AP identity.

SceneKit draws the camera-space trajectory and selected AP's colored trail with batched geometry. SwiftUI Canvas draws the X/Z map and optional heat cells. Spatial-bin means feed configurable measured-only, inverse-distance, nearest-neighbor or Gaussian interpolation with a bounded support radius and an optional height band. Measured bins remain distinct from estimates. Classified LiDAR floor/wall mesh observations provide separate geometry layers, without inferring RF attenuation through walls. The ESP-to-camera offset is uncalibrated; positions refer to the phone.

Stop requests sensor termination and drain before finalizing the manifest. An eight-second fallback saves available local data and records a drain-timeout event. Backgrounding ends the survey. SQLite WAL and an unfinished manifest allow reopening interrupted recordings. ZIP export includes the raw database and manifest. Optional foreground GPS fixes and manually calibrated geographic registration remain separate from raw AR coordinates. MapKit projects the survey onto a satellite layer. SQLite schema 2 adds an append-only map_layers table; schema 1 remains readable. Structured RoomPlan reconstruction and BLE controls are not part of this version.

See SPATIAL_LAYERS.md for API research, data contracts, bounds and device acceptance.

Build the Xcode project in this repository. Keep DerivedData outside iCloud-backed Documents to avoid code-signing metadata failures.
