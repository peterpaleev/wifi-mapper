# Firmware-specific guidance

Target: WeAct ESP32-S3 N8R8, ESP-IDF 5.5.1 at the commit pinned by tools/bootstrap_firmware.sh. Preserve dependencies.lock and sdkconfig.defaults. Runtime USB is ECM Ethernet, not serial; absence of a serial device is expected. ROM flashing requires BOOT/RESET and should only occur for requested firmware work on the identified board.

Run tools/test_core.sh after parser/protocol edits and tools/build_firmware.sh build for firmware changes. Hardware integration is tools/usb_probe.py and requires exclusive ownership of the TCP sensor connection. Do not flash merely to validate documentation or app changes.

Capture callback: bounded copy to a static queue, no blocking I/O or dynamic work. Report queue/ring drops. Keep ACK/replay semantics, AP identity and packet layouts consistent with protocol/. Only 2.4 GHz management frames are observed. BLE remains a firmware diagnostic endpoint, not a completed app mode.

TinyUSB ECM integration has a deliberate wrapper compatibility shim in main/CMakeLists.txt. Do not remove it as redundant without building and testing enumeration on actual hardware.
