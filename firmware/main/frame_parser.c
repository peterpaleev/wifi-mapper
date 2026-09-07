#include "frame_parser.h"
#include <string.h>
bool parse_management(const uint8_t *d, size_t n, ap_frame_t *o) {
  if (!d || !o || n < 36 || (d[0] & 0x0f) != 0 ||
      (d[0] >> 4 != 8 && d[0] >> 4 != 5))
    return false;
  memset(o, 0, sizeof(*o));
  o->subtype = d[0] >> 4;
  memcpy(o->bssid, d + 16, 6);
  o->beacon_interval = d[32] | (uint16_t)d[33] << 8;
  o->capability = d[34] | (uint16_t)d[35] << 8;
  for (size_t p = 36; p < n;) {
    if (n - p < 2)
      return false;
    uint8_t id = d[p++], len = d[p++];
    if (len > n - p)
      return false;
    if (id == 0) {
      if (len > 32)
        return false;
      o->ssid_len = len;
      memcpy(o->ssid, d + p, len);
    }
    if (id == 3 && len == 1)
      o->channel = d[p];
    if (id == 48) {
      if (len < 2)
        return false;
      o->rsn = true;
    }
    p += len;
  }
  return true;
}
