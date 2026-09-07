#include "esp_check.h"
#include "esp_heap_caps.h"
#include "esp_timer.h"
#include "esp_wifi.h"
#include "freertos/FreeRTOS.h"
#include "freertos/queue.h"
#include "freertos/task.h"
#include "mapper.h"
#include <stdatomic.h>
#include <string.h>

typedef struct {
  uint64_t ts;
  uint32_t radio_ts;
  uint16_t len, original_len;
  int8_t rssi;
  uint8_t ch, secondary, mode, mcs;
  uint8_t data[768];
} rx_item_t;
static QueueHandle_t rx_queue;
static StaticQueue_t rx_control;
static uint8_t rx_storage[RX_CAP * sizeof(rx_item_t)];
static observation_t *ring;
static size_t capacity;
static atomic_uint head, tail;
static atomic_bool processing;
static ap_entry_t aps[AP_CAP];
static uint16_t ap_count;
static portMUX_TYPE registry_lock = portMUX_INITIALIZER_UNLOCKED;
diagnostics_t diag;
bool capturing;
uint16_t dwell_ms = 80;
uint8_t first_channel = 1, channel_count = 11;
static portMUX_TYPE state_lock = portMUX_INITIALIZER_UNLOCKED;
static void receive(void *buffer, wifi_promiscuous_pkt_type_t type) {
  __atomic_fetch_add(&diag.received, 1, __ATOMIC_RELAXED);
  if (!__atomic_load_n(&capturing, __ATOMIC_RELAXED) || type != WIFI_PKT_MGMT) {
    __atomic_fetch_add(&diag.filtered, 1, __ATOMIC_RELAXED);
    return;
  }
  const wifi_promiscuous_pkt_t *p = buffer;
  size_t len = p->rx_ctrl.sig_len;
  if (len < 40 || len - 4 > 768 ||
      (p->payload[0] != 0x80 && p->payload[0] != 0x50)) {
    __atomic_fetch_add(&diag.filtered, 1, __ATOMIC_RELAXED);
    return;
  }
  rx_item_t item = {.ts = esp_timer_get_time(),
                    .radio_ts = p->rx_ctrl.timestamp,
                    .len = len - 4,
                    .original_len = len,
                    .rssi = p->rx_ctrl.rssi,
                    .ch = p->rx_ctrl.channel,
                    .secondary = p->rx_ctrl.secondary_channel,
                    .mode = p->rx_ctrl.sig_mode,
                    .mcs = p->rx_ctrl.mcs};
  memcpy(item.data, p->payload, item.len);
  if (xQueueSend(rx_queue, &item, 0) != pdTRUE)
    __atomic_fetch_add(&diag.queue_drops, 1, __ATOMIC_RELAXED);
}
static void process(void *arg) {
  rx_item_t item;
  for (;;) {
    if (xQueueReceive(rx_queue, &item, pdMS_TO_TICKS(10)) != pdTRUE)
      continue;
    atomic_store(&processing, true);
    ap_frame_t frame;
    if (!parse_management(item.data, item.len, &frame)) {
      __atomic_fetch_add(&diag.filtered, 1, __ATOMIC_RELAXED);
      atomic_store(&processing, false);
      continue;
    }
    uint16_t id = 0;
    portENTER_CRITICAL(&registry_lock);
    for (; id < ap_count; id++)
      if (!memcmp(aps[id].frame.bssid, frame.bssid, 6))
        break;
    if (id == AP_CAP) {
      portEXIT_CRITICAL(&registry_lock);
      __atomic_fetch_add(&diag.buffer_drops, 1, __ATOMIC_RELAXED);
      atomic_store(&processing, false);
      continue;
    }
    if (id == ap_count)
      ap_count++;
    if (!aps[id].revision || memcmp(&aps[id].frame, &frame, sizeof(frame))) {
      aps[id].frame = frame;
      aps[id].revision++;
    }
    portEXIT_CRITICAL(&registry_lock);
    unsigned h = atomic_load(&head), t = atomic_load(&tail);
    if (h - t >= capacity)
      __atomic_fetch_add(&diag.buffer_drops, 1, __ATOMIC_RELAXED);
    else {
      ring[h % capacity] = (observation_t){.timestamp = item.ts,
                                           .ap_id = id,
                                           .rssi = item.rssi,
                                           .channel = item.ch,
                                           .secondary = item.secondary,
                                           .subtype = frame.subtype,
                                           .sig_mode = item.mode,
                                           .mcs = item.mcs,
                                           .length = item.original_len,
                                           .radio_timestamp = item.radio_ts};
      atomic_store(&head, h + 1);
      __atomic_fetch_add(&diag.accepted, 1, __ATOMIC_RELAXED);
      unsigned used = h + 1 - t;
      if (used > diag.high_water)
        diag.high_water = used;
    }
    atomic_store(&processing, false);
  }
}
static void hop(void *arg) {
  uint8_t ch = 1;
  uint64_t last = esp_timer_get_time();
  for (;;) {
    uint16_t dwell;
    uint8_t first, count;
    portENTER_CRITICAL(&state_lock);
    dwell = dwell_ms;
    first = first_channel;
    count = channel_count;
    portEXIT_CRITICAL(&state_lock);
    if (ch < first || ch >= first + count)
      ch = first;
    if (esp_wifi_set_channel(ch, WIFI_SECOND_CHAN_NONE) == ESP_OK)
      diag.channel = ch;
    uint64_t start = esp_timer_get_time();
    last = start;
    vTaskDelay(pdMS_TO_TICKS(dwell));
    if (ch >= 1 && ch <= 11)
      diag.dwell_us[ch - 1] += esp_timer_get_time() - last;
    ch++;
    if (ch >= first + count)
      ch = first;
  }
}
void capture_init(void) {
  rx_queue =
      xQueueCreateStatic(RX_CAP, sizeof(rx_item_t), rx_storage, &rx_control);
  configASSERT(rx_queue);
  capacity = RING_CAP;
  ring = heap_caps_calloc(capacity, sizeof(*ring),
                          MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
  if (!ring) {
    capacity = 1024;
    ring = heap_caps_calloc(capacity, sizeof(*ring),
                            MALLOC_CAP_INTERNAL | MALLOC_CAP_8BIT);
  }
  configASSERT(ring);
  diag.capacity = capacity;
  wifi_init_config_t cfg = WIFI_INIT_CONFIG_DEFAULT();
  ESP_ERROR_CHECK(esp_wifi_init(&cfg));
  ESP_ERROR_CHECK(esp_wifi_set_storage(WIFI_STORAGE_RAM));
  ESP_ERROR_CHECK(esp_wifi_set_mode(WIFI_MODE_NULL));
  ESP_ERROR_CHECK(esp_wifi_start());
  wifi_country_t country = {.cc = "01",
                            .schan = 1,
                            .nchan = 11,
                            .policy = WIFI_COUNTRY_POLICY_MANUAL};
  ESP_ERROR_CHECK(esp_wifi_set_country(&country));
  wifi_promiscuous_filter_t filter = {.filter_mask =
                                          WIFI_PROMIS_FILTER_MASK_MGMT};
  ESP_ERROR_CHECK(esp_wifi_set_promiscuous_filter(&filter));
  ESP_ERROR_CHECK(esp_wifi_set_promiscuous_rx_cb(receive));
  ESP_ERROR_CHECK(esp_wifi_set_promiscuous(true));
  xTaskCreatePinnedToCore(process, "observation_parser", 6144, NULL, 6, NULL,
                          1);
  xTaskCreate(hop, "channel_scheduler", 3072, NULL, 4, NULL);
}
void capture_set(bool enabled) {
  __atomic_store_n(&capturing, enabled, __ATOMIC_RELAXED);
}
bool capture_config(uint16_t d, uint8_t f, uint8_t c) {
  if (d < 40 || d > 1000 || f < 1 || !c || f + c > 12)
    return false;
  portENTER_CRITICAL(&state_lock);
  dwell_ms = d;
  first_channel = f;
  channel_count = c;
  portEXIT_CRITICAL(&state_lock);
  return true;
}
size_t ring_peek(observation_t *out, size_t max) {
  unsigned t = atomic_load(&tail), h = atomic_load(&head);
  size_t n = h - t;
  if (n > max)
    n = max;
  for (size_t i = 0; i < n; i++)
    out[i] = ring[(t + i) % capacity];
  diag.used = h - t;
  return n;
}
void ring_consume(size_t n) {
  atomic_fetch_add(&tail, n);
  diag.used = atomic_load(&head) - atomic_load(&tail);
}
void ring_clear(void) {
  atomic_store(&tail, atomic_load(&head));
  diag.used = 0;
}
bool capture_drained(void) {
  return !atomic_load(&processing) && uxQueueMessagesWaiting(rx_queue) == 0 &&
         atomic_load(&head) == atomic_load(&tail);
}
bool ap_get(uint16_t id, ap_entry_t *out) {
  portENTER_CRITICAL(&registry_lock);
  bool ok = id < ap_count;
  if (ok)
    *out = aps[id];
  portEXIT_CRITICAL(&registry_lock);
  return ok;
}
