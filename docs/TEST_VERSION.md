# USB signal inspector — historical first test scope

Historical scope of the first inspector build. Version 1.1 now includes spatial mapping; see STATUS.md. The original long specification is retained privately as historical material.

This version offers USB Ethernet control, passive 2.4 GHz access-point discovery, BSSID selection, live RSSI history, RSSI/time density view, channel lock/sweep, configurable dwell, raw CSV logging, diagnostics and reconnect. The density plot is a histogram of received packet RSSI, not an FFT, spectrum analyzer or channel-occupancy measurement. ESP32-S3 cannot inspect 5/6 GHz.

App UI refreshes at 5 Hz. Network receive, parsing, histories and CSV writes run on one dedicated serial queue. Display memory is bounded at 3000 samples per AP; raw CSV writes every selected logging interval independently of the display history. Sensor batches carry sequences and remain buffered until acknowledgement. CSV errors are explicit. A stopped connection does not imply the remote sensor stopped; reconnect to drain it.

USB: CDC-ECM/RNDIS via esp_tinyusb 1.7.6, DHCP subnet 192.168.7.0/24, sensor 192.168.7.1:45832, no Wi-Fi association. The first build required wiredEthernet; the working fix lets iOS resolve the on-link route and excludes cellular. The user confirmed direct iPhone USB operation. Firmware retains a BLE diagnostic transport; this narrowed iPhone test UI operates over USB only.

Use the native ESP32-S3 USB port (GPIO19/20), not a separate UART bridge. For subsequent reflashing, hold BOOT, press/release RESET, release BOOT to return to ROM download mode if USB serial is absent. The native port becomes Ethernet while the app firmware runs.
