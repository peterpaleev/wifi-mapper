#include "esp_check.h"
#include "esp_mac.h"
#include "esp_netif.h"
#include "esp_netif_net_stack.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "lwip/sockets.h"
#include "mapper.h"
#include "tinyusb.h"
#include "tinyusb_net.h"
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
// ECM descriptors are explicit: esp_tinyusb 1.7.x defaults describe NCM only.
uint8_t tud_network_mac_address[6];
uint8_t tusb_get_mac_string_id(void) { return 5; }
static const tusb_desc_device_t device_descriptor = {
    .bLength = sizeof(tusb_desc_device_t),
    .bDescriptorType = TUSB_DESC_DEVICE,
    .bcdUSB = 0x0200,
    .bDeviceClass = TUSB_CLASS_MISC,
    .bDeviceSubClass = MISC_SUBCLASS_COMMON,
    .bDeviceProtocol = MISC_PROTOCOL_IAD,
    .bMaxPacketSize0 = 64,
    .idVendor = 0x303a,
    .idProduct = 0x4002,
    .bcdDevice = 0x0100,
    .iManufacturer = 1,
    .iProduct = 2,
    .iSerialNumber = 3,
    .bNumConfigurations = 1};
static const uint8_t ecm_descriptor[] = {
    TUD_CONFIG_DESCRIPTOR(1, 2, 0, TUD_CONFIG_DESC_LEN + TUD_CDC_ECM_DESC_LEN,
                          0, 250),
    TUD_CDC_ECM_DESCRIPTOR(0, 4, 5, 0x81, 64, 0x02, 0x82, 64, 1514)};
static const char *usb_strings[] = {
    "\x09\x04",  "WiFi Mapper", "WiFi Mapper USB Ethernet",
    "WFM-S3-01", "WiFi Sensor", "020000000001"};
static esp_netif_t *netif;
static atomic_int client_fd = -1;
static esp_err_t receive_usb(void *buffer, uint16_t len, void *ctx) {
  void *copy = malloc(len);
  if (!copy)
    return ESP_ERR_NO_MEM;
  memcpy(copy, buffer, len);
  return esp_netif_receive(netif, copy, len, NULL);
}
static void release_rx(void *h, void *buffer) { free(buffer); }
static void release_tx(void *buffer, void *ctx) { free(buffer); }
static esp_err_t transmit(void *h, void *buffer, size_t len) {
  void *copy = malloc(len);
  if (!copy)
    return ESP_ERR_NO_MEM;
  memcpy(copy, buffer, len);
  esp_err_t err = tinyusb_net_send_sync(copy, len, copy, pdMS_TO_TICKS(100));
  if (err != ESP_OK) {
    free(copy);
  }
  return err;
}
bool usb_connected(void) { return atomic_load(&client_fd) >= 0; }
bool usb_send(const uint8_t *d, size_t n) {
  int fd = atomic_load(&client_fd);
  if (fd < 0)
    return false;
  size_t pos = 0;
  while (pos < n) {
    int sent = send(fd, d + pos, n - pos, 0);
    if (sent <= 0) {
      shutdown(fd, SHUT_RDWR);
      return false;
    }
    pos += sent;
  }
  return true;
}
static void server(void *arg) {
  int listener = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
  configASSERT(listener >= 0);
  int yes = 1;
  setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));
  struct sockaddr_in address = {.sin_family = AF_INET,
                                .sin_port = htons(WM_PORT),
                                .sin_addr.s_addr = htonl(INADDR_ANY)};
  configASSERT(bind(listener, (struct sockaddr *)&address, sizeof(address)) ==
               0);
  listen(listener, 1);
  for (;;) {
    int fd = accept(listener, NULL, NULL);
    if (fd < 0) {
      vTaskDelay(pdMS_TO_TICKS(50));
      continue;
    }
    struct timeval timeout = {.tv_sec = 2};
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));
    atomic_store(&client_fd, fd);
    diag.reconnects++;
    uint8_t b[512];
    int n;
    while ((n = recv(fd, b, sizeof(b), 0)) > 0)
      transport_received(b, n, 1);
    atomic_store(&client_fd, -1);
    close(fd);
  }
}
void usb_network_init(void) {
  esp_netif_ip_info_t ip = {0};
  IP4_ADDR(&ip.ip, 192, 168, 7, 1);
  IP4_ADDR(&ip.netmask, 255, 255, 255, 0);
  IP4_ADDR(&ip.gw, 0, 0, 0, 0);
  esp_netif_inherent_config_t base = {.flags = ESP_NETIF_DHCP_SERVER |
                                               ESP_NETIF_FLAG_AUTOUP,
                                      .ip_info = &ip,
                                      .if_key = "USB_ECM",
                                      .if_desc = "usb",
                                      .route_prio = 10};
  esp_netif_config_t cfg = {.base = &base,
                            .stack = ESP_NETIF_NETSTACK_DEFAULT_ETH};
  netif = esp_netif_new(&cfg);
  configASSERT(netif);
  esp_netif_driver_ifconfig_t driver = {.handle = netif,
                                        .transmit = transmit,
                                        .driver_free_rx_buffer = release_rx};
  ESP_ERROR_CHECK(esp_netif_set_driver_config(netif, &driver));
  uint8_t mac[6];
  esp_read_mac(mac, ESP_MAC_WIFI_STA);
  mac[0] |= 2;
  ESP_ERROR_CHECK(esp_netif_set_mac(netif, mac));
  memcpy(tud_network_mac_address, mac, 6);
  tud_network_mac_address[5] ^= 1;
  tinyusb_config_t usb = {.external_phy = false,
                          .device_descriptor = &device_descriptor,
                          .configuration_descriptor = ecm_descriptor,
                          .string_descriptor = usb_strings,
                          .string_descriptor_count =
                              sizeof(usb_strings) / sizeof(usb_strings[0])};
  ESP_ERROR_CHECK(tinyusb_driver_install(&usb));
  tinyusb_net_config_t nc = {.on_recv_callback = receive_usb,
                             .free_tx_buffer = release_tx};
  memcpy(nc.mac_addr, mac, 6);
  nc.mac_addr[5] ^= 1;
  ESP_ERROR_CHECK(tinyusb_net_init(TINYUSB_USBDEV_0, &nc));
  esp_netif_action_start(netif, NULL, 0, NULL);
  esp_netif_action_connected(netif, NULL, 0, NULL);
  xTaskCreate(server, "usb_tcp", 4096, NULL, 5, NULL);
}
