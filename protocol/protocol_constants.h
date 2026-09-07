#pragma once
#include <stddef.h>
#include <stdint.h>
#define WM_VERSION 1
#define WM_MAX_PAYLOAD 2048
#define WM_PORT 45832
#define WM_SERVICE "8e7a0001-6d52-4f9b-a81c-3f8b2046e001"
enum {
  WM_HELLO = 1,
  WM_INFO,
  WM_START,
  WM_STOP,
  WM_CONFIG,
  WM_GET_CONFIG,
  WM_SYNC_REQUEST,
  WM_SYNC_RESPONSE,
  WM_AP,
  WM_BATCH,
  WM_STATUS,
  WM_ERROR,
  WM_ACK,
  WM_STOPPED,
  WM_PREVIEW
};
static inline uint16_t rd16(const uint8_t *p) {
  return p[0] | (uint16_t)p[1] << 8;
}
static inline uint32_t rd32(const uint8_t *p) {
  return rd16(p) | (uint32_t)rd16(p + 2) << 16;
}
static inline uint64_t rd64(const uint8_t *p) {
  return rd32(p) | (uint64_t)rd32(p + 4) << 32;
}
static inline void wr16(uint8_t *p, uint16_t v) {
  p[0] = v;
  p[1] = v >> 8;
}
static inline void wr32(uint8_t *p, uint32_t v) {
  wr16(p, v);
  wr16(p + 2, v >> 16);
}
static inline void wr64(uint8_t *p, uint64_t v) {
  wr32(p, v);
  wr32(p + 4, v >> 32);
}
