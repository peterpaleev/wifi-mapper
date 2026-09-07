#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
typedef struct {
  uint8_t bssid[6], ssid[32], ssid_len, channel, subtype;
  uint16_t capability, beacon_interval;
  bool rsn;
} ap_frame_t;
bool parse_management(const uint8_t *data, size_t length, ap_frame_t *out);
