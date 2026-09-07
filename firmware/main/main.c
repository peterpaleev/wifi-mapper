#include "esp_event.h"
#include "esp_flash.h"
#include "esp_log.h"
#include "esp_mac.h"
#include "esp_netif.h"
#include "esp_psram.h"
#include "esp_random.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "mapper.h"
#include "nvs_flash.h"
#include <string.h>
uint32_t boot_id;
uint8_t active_session[16];
static uint32_t next_seq = 1, pending_seq, sent_revision[AP_CAP];
static size_t pending_count;
static bool stopping, preview;
static uint64_t last_send, last_status, stop_requested;
static void error(const char *s) {
  transport_send(WM_ERROR, 0, (const uint8_t *)s, strlen(s));
}
static void info(void) {
  uint8_t p[38] = {0};
  wr32(p, boot_id);
  p[4] = 1;
  p[5] = 0;
  p[6] = 1;
  p[7] = 0;
  esp_read_mac(p + 8, ESP_MAC_WIFI_STA);
  uint32_t flash = 0;
  esp_flash_get_size(NULL, &flash);
  wr32(p + 14, flash);
  wr32(p + 18, esp_psram_is_initialized() ? esp_psram_get_size() : 0);
  memcpy(p + 22, active_session, 16);
  transport_send(WM_INFO, 0, p, sizeof(p));
}
static void config(void) {
  uint8_t p[4];
  wr16(p, dwell_ms);
  p[2] = first_channel;
  p[3] = channel_count;
  transport_send(WM_GET_CONFIG, 0, p, 4);
}
void mapper_command(uint8_t type, const uint8_t *d, size_t n) {
  switch (type) {
  case WM_HELLO:
    memset(sent_revision, 0, sizeof(sent_revision));
    last_send = 0;
    info();
    config();
    break;
  case WM_START:
    if (n != 16) {
      error("START needs UUID16");
      break;
    }
    if (capturing && !preview) {
      if (memcmp(d, active_session, 16))
        error("Another session is active");
      else
        info();
      break;
    }
    if (stopping) {
      error("Previous session still draining");
      break;
    }
    capture_set(false);
    vTaskDelay(pdMS_TO_TICKS(30));
    ring_clear();
    pending_count = 0;
    memcpy(active_session, d, 16);
    preview = false;
    capture_set(true);
    info();
    break;
  case WM_PREVIEW:
    if (!capturing && !stopping) {
      preview = true;
      capture_set(true);
    }
    break;
  case WM_STOP:
    capture_set(false);
    stopping = true;
    stop_requested = esp_timer_get_time();
    break;
  case WM_CONFIG:
    if (capturing && !preview) {
      error("Stop recording before changing config");
      break;
    }
    if (n != 4 || !capture_config(rd16(d), d[2], d[3]))
      error("Invalid dwell/channel range");
    else
      config();
    break;
  case WM_GET_CONFIG:
    config();
    break;
  case WM_SYNC_REQUEST:
    if (n == 8) {
      uint8_t p[24];
      memcpy(p, d, 8);
      wr64(p + 8, esp_timer_get_time());
      wr64(p + 16, esp_timer_get_time());
      transport_send(WM_SYNC_RESPONSE, 0, p, 24);
    }
    break;
  case WM_ACK:
    if (n == 4 && pending_count && rd32(d) == pending_seq) {
      ring_consume(pending_count);
      pending_count = 0;
    }
    break;
  default:
    error("Unsupported command");
    break;
  }
}
static void status(void) {
  uint8_t p[140] = {0};
  wr64(p, esp_timer_get_time());
  uint32_t values[] = {diag.received,    diag.accepted,     diag.filtered,
                       diag.queue_drops, diag.buffer_drops, diag.used,
                       diag.capacity,    diag.high_water,   diag.bytes,
                       diag.reconnects};
  for (int i = 0; i < 10; i++)
    wr32(p + 8 + 4 * i, values[i]);
  p[48] = diag.channel;
  p[49] = capturing;
  wr16(p + 50, dwell_ms);
  for (int i = 0; i < 11; i++)
    wr64(p + 52 + 8 * i, diag.dwell_us[i]);
  transport_send(WM_STATUS, 0, p, sizeof(p));
}
static void send_batch(void) {
  observation_t obs[32];
  size_t count = ring_peek(obs, pending_count ? pending_count : 32);
  if (!count)
    return;
  if (!pending_count) {
    pending_count = count;
    pending_seq = next_seq++;
  }
  for (size_t i = 0; i < count; i++) {
    ap_entry_t ap;
    uint16_t id = obs[i].ap_id;
    if (!ap_get(id, &ap))
      continue;
    if (sent_revision[id] != ap.revision) {
      uint8_t p[46];
      wr16(p, id);
      memcpy(p + 2, ap.frame.bssid, 6);
      p[8] = ap.frame.channel;
      p[9] = ap.frame.ssid_len;
      wr16(p + 10, ap.frame.capability);
      wr16(p + 12, ap.frame.beacon_interval);
      memcpy(p + 14, ap.frame.ssid, ap.frame.ssid_len);
      if (!transport_send(WM_AP, 0, p, 14 + ap.frame.ssid_len))
        return;
      sent_revision[id] = ap.revision;
    }
  }
  uint8_t p[2 + 32 * 24];
  wr16(p, count);
  for (size_t i = 0; i < count; i++) {
    observation_t *o = &obs[i];
    uint8_t *r = p + 2 + i * 24;
    wr64(r, o->timestamp);
    wr16(r + 8, o->ap_id);
    r[10] = (uint8_t)o->rssi;
    r[11] = o->channel;
    r[12] = o->secondary;
    r[13] = o->subtype;
    r[14] = o->sig_mode;
    r[15] = o->mcs;
    wr16(r + 16, o->length);
    wr32(r + 18, o->radio_timestamp);
    wr16(r + 22, 0);
  }
  transport_send(WM_BATCH, pending_seq, p, 2 + count * 24);
  last_send = esp_timer_get_time();
}
void app_main(void) {
  ESP_ERROR_CHECK(nvs_flash_init());
  ESP_ERROR_CHECK(esp_netif_init());
  ESP_ERROR_CHECK(esp_event_loop_create_default());
  boot_id = esp_random();
  transport_init();
  capture_init();
  usb_network_init();
  for (;;) {
    transport_poll();
    uint64_t now = esp_timer_get_time();
    if ((!pending_count && now - last_send >= 100000) ||
        now - last_send > 1000000)
      send_batch();
    if (now - last_status > 1000000) {
      status();
      last_status = now;
      ESP_LOGI(
          "mapper",
          "rx=%lu accepted=%lu queueDrops=%lu bufferDrops=%lu buffered=%lu",
          (unsigned long)diag.received, (unsigned long)diag.accepted,
          (unsigned long)diag.queue_drops, (unsigned long)diag.buffer_drops,
          (unsigned long)diag.used);
    }
    if (stopping && now - stop_requested > 50000 && !pending_count &&
        capture_drained()) {
      if (transport_send(WM_STOPPED, 0, NULL, 0)) {
        stopping = false;
        preview = false;
        memset(active_session, 0, 16);
      }
    }
    vTaskDelay(pdMS_TO_TICKS(10));
  }
}
