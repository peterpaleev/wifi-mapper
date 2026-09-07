#include "esp_check.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/queue.h"
#include "freertos/task.h"
#include "host/ble_hs.h"
#include "mapper.h"
#include "nimble/nimble_port.h"
#include "nimble/nimble_port_freertos.h"
#include "services/gap/ble_svc_gap.h"
#include "services/gatt/ble_svc_gatt.h"
#include <string.h>
static uint16_t connection = BLE_HS_CONN_HANDLE_NONE, data_handle;
static bool subscribed;
static uint8_t address_type;
#define UUID(n)                                                                \
  BLE_UUID128_INIT(0x01, 0xe0, 0x46, 0x20, 0x8b, 0x3f, 0x1c, 0xa8, 0x9b, 0x4f, \
                   0x52, 0x6d, n, 0x00, 0x7a, 0x8e)
static const ble_uuid128_t service = UUID(1), info_uuid = UUID(2),
                           control_uuid = UUID(3), data_uuid = UUID(4);
typedef struct {
  uint16_t length;
  uint8_t source;
  uint8_t bytes[512];
} rx_chunk_t;
static QueueHandle_t commands;
static void advertise(void);
static int access_cb(uint16_t c, uint16_t h, struct ble_gatt_access_ctxt *ctx,
                     void *arg) {
  if (ctx->op == BLE_GATT_ACCESS_OP_READ_CHR) {
    const uint8_t info[] = {1, 0, 1, 0};
    return os_mbuf_append(ctx->om, info, sizeof(info))
               ? BLE_ATT_ERR_INSUFFICIENT_RES
               : 0;
  }
  uint16_t len = OS_MBUF_PKTLEN(ctx->om);
  uint8_t bytes[512];
  if (len > sizeof(bytes))
    return BLE_ATT_ERR_INVALID_ATTR_VALUE_LEN;
  if (ble_hs_mbuf_to_flat(ctx->om, bytes, sizeof(bytes), NULL))
    return BLE_ATT_ERR_UNLIKELY;
  transport_received(bytes, len, 0);
  return 0;
}
static const struct ble_gatt_svc_def services[] = {
    {.type = BLE_GATT_SVC_TYPE_PRIMARY,
     .uuid = &service.u,
     .characteristics =
         (struct ble_gatt_chr_def[]){{.uuid = &info_uuid.u,
                                      .access_cb = access_cb,
                                      .flags = BLE_GATT_CHR_F_READ},
                                     {.uuid = &control_uuid.u,
                                      .access_cb = access_cb,
                                      .flags = BLE_GATT_CHR_F_WRITE},
                                     {.uuid = &data_uuid.u,
                                      .access_cb = access_cb,
                                      .flags = BLE_GATT_CHR_F_NOTIFY,
                                      .val_handle = &data_handle},
                                     {0}}},
    {0}};
static int gap_event(struct ble_gap_event *e, void *arg) {
  switch (e->type) {
  case BLE_GAP_EVENT_CONNECT:
    if (e->connect.status == 0) {
      connection = e->connect.conn_handle;
      diag.reconnects++;
    } else
      advertise();
    break;
  case BLE_GAP_EVENT_DISCONNECT:
    connection = BLE_HS_CONN_HANDLE_NONE;
    subscribed = false;
    advertise();
    break;
  case BLE_GAP_EVENT_SUBSCRIBE:
    subscribed = e->subscribe.cur_notify;
    break;
  case BLE_GAP_EVENT_ADV_COMPLETE:
    advertise();
    break;
  default:
    break;
  }
  return 0;
}
static void advertise(void) {
  struct ble_hs_adv_fields f = {0};
  f.flags = BLE_HS_ADV_F_DISC_GEN | BLE_HS_ADV_F_BREDR_UNSUP;
  f.uuids128 = (ble_uuid128_t *)&service;
  f.num_uuids128 = 1;
  f.uuids128_is_complete = 1;
  ble_gap_adv_set_fields(&f);
  struct ble_hs_adv_fields scan = {0};
  const char *name = "WiFi Mapper";
  scan.name = (uint8_t *)name;
  scan.name_len = strlen(name);
  scan.name_is_complete = 1;
  ble_gap_adv_rsp_set_fields(&scan);
  struct ble_gap_adv_params p = {0};
  p.conn_mode = BLE_GAP_CONN_MODE_UND;
  p.disc_mode = BLE_GAP_DISC_MODE_GEN;
  p.itvl_min = 320;
  p.itvl_max = 480;
  ble_gap_adv_start(address_type, NULL, BLE_HS_FOREVER, &p, gap_event, NULL);
}
static void sync_cb(void) {
  ble_hs_id_infer_auto(0, &address_type);
  advertise();
}
static void host_task(void *arg) {
  nimble_port_run();
  nimble_port_freertos_deinit();
}
void transport_init(void) {
  commands = xQueueCreate(32, sizeof(rx_chunk_t));
  configASSERT(commands);
  ESP_ERROR_CHECK(nimble_port_init());
  ble_svc_gap_init();
  ble_svc_gatt_init();
  ble_svc_gap_device_name_set("WiFi Mapper");
  ble_hs_cfg.sync_cb = sync_cb;
  assert(ble_gatts_count_cfg(services) == 0);
  assert(ble_gatts_add_svcs(services) == 0);
  nimble_port_freertos_init(host_task);
}
void transport_received(const uint8_t *d, size_t n, int source) {
  if (n > 512)
    return;
  rx_chunk_t chunk = {.length = n, .source = source};
  memcpy(chunk.bytes, d, n);
  if (xQueueSend(commands, &chunk, 0) != pdTRUE)
    __atomic_fetch_add(&diag.queue_drops, 1, __ATOMIC_RELAXED);
}
void transport_poll(void) {
  static uint8_t buffers[2][WM_MAX_PAYLOAD + 12];
  static size_t lengths[2];
  rx_chunk_t chunk;
  while (xQueueReceive(commands, &chunk, 0) == pdTRUE) {
    if ((usb_connected() ? 1 : 0) != chunk.source)
      continue;
    int s = chunk.source;
    size_t *n = &lengths[s];
    uint8_t *b = buffers[s];
    if (*n + chunk.length > WM_MAX_PAYLOAD + 12) {
      *n = 0;
      continue;
    }
    memcpy(b + *n, chunk.bytes, chunk.length);
    *n += chunk.length;
    while (*n >= 12) {
      if (b[0] != 0x57 || b[1] != 0x4d || b[2] != 1 ||
          rd16(b + 8) > WM_MAX_PAYLOAD) {
        memmove(b, b + 1, --*n);
        continue;
      }
      size_t total = 12 + rd16(b + 8);
      if (*n < total)
        break;
      mapper_command(b[3], b + 12, total - 12);
      memmove(b, b + total, *n - total);
      *n -= total;
    }
  }
}
bool transport_send(uint8_t type, uint32_t seq, const uint8_t *d, size_t n) {
  if (n > WM_MAX_PAYLOAD) {
    return false;
  }
  uint8_t bytes[WM_MAX_PAYLOAD + 12] = {0x57, 0x4d, 1, type};
  wr32(bytes + 4, seq);
  wr16(bytes + 8, n);
  if (n)
    memcpy(bytes + 12, d, n);
  n += 12;
  if (usb_connected()) {
    bool ok = usb_send(bytes, n);
    if (ok)
      diag.bytes += n;
    return ok;
  }
  if (connection == BLE_HS_CONN_HANDLE_NONE || !subscribed)
    return false;
  size_t mtu = ble_att_mtu(connection);
  if (mtu < 23)
    return false;
  mtu -= 3;
  for (size_t pos = 0; pos < n;) {
    size_t len = n - pos;
    if (len > mtu)
      len = mtu;
    bool sent = false;
    for (int retry = 0; retry < 20; retry++) {
      struct os_mbuf *om = ble_hs_mbuf_from_flat(bytes + pos, len);
      if (om && ble_gatts_notify_custom(connection, data_handle, om) == 0) {
        sent = true;
        break;
      }
      vTaskDelay(pdMS_TO_TICKS(5));
      if (connection == BLE_HS_CONN_HANDLE_NONE)
        break;
    }
    if (!sent) {
      if (connection != BLE_HS_CONN_HANDLE_NONE)
        ble_gap_terminate(connection, BLE_ERR_REM_USER_CONN_TERM);
      return false;
    }
    pos += len;
    diag.bytes += len;
  }
  return true;
}
