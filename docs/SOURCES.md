# Primary sources checked

- ESP-IDF pinned release: https://github.com/espressif/esp-idf/tree/v5.5.1 (fcae32885b0296b32044cb99ecbdc50d98dddb83).
- RF coexistence: https://docs.espressif.com/projects/esp-idf/en/v5.5.1/esp32s3/api-guides/coexist.html — sniffer plus BLE marked C1 (performance unstable).
- USB device stack: https://docs.espressif.com/projects/esp-idf/en/v5.5/esp32s3/api-reference/peripherals/usb_device.html
- Official TinyUSB network example: https://github.com/espressif/esp-idf/tree/v5.5.1/examples/peripherals/usb/device/tusb_ncm
- Apple USB Ethernet discussion, including DTS response on networking and foreground limitations: https://developer.apple.com/forums/thread/844516
- CoreBluetooth and Network API declarations validated against installed Xcode 26.5 iPhoneOS SDK and compiled for iOS 17+.

The USB network example's private Wi-Fi bridging APIs are not used. This device terminates TCP in its own ESP-NETIF Ethernet interface and independently receives Wi-Fi management frames.
