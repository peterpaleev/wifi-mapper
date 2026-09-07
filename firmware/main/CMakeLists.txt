idf_component_register(SRCS "main.c" "frame_parser.c" "capture.c" "transport.c" "usb_network.c" INCLUDE_DIRS "." "../../protocol" REQUIRES esp_wifi esp_event esp_netif esp_timer nvs_flash bt esp_psram lwip esp_app_format spi_flash)

# esp_tinyusb 1.7.6 only registers this source for NCM although its wrapper
# supports both network classes. Explicitly include it for the ECM build.
if(CONFIG_TINYUSB_NET_MODE_ECM_RNDIS)
    idf_component_get_property(tinyusb_wrapper espressif__esp_tinyusb COMPONENT_LIB)
    idf_component_get_property(tinyusb_dir espressif__esp_tinyusb COMPONENT_DIR)
    target_sources(${tinyusb_wrapper} PRIVATE "${tinyusb_dir}/tinyusb_net.c")
endif()
