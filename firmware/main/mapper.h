#pragma once
#include "frame_parser.h"
#include "protocol_constants.h"
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#define AP_CAP 512
#define RX_CAP 64
#define RING_CAP 32768
typedef struct {
  uint64_t timestamp;
  uint16_t ap_id;
  int8_t rssi;
  uint8_t channel, secondary, subtype, sig_mode, mcs;
  uint16_t length;
  uint32_t radio_timestamp;
} observation_t;
typedef struct {
  ap_frame_t frame;
  uint32_t revision;
} ap_entry_t;
typedef struct {
  uint32_t received, accepted, filtered, queue_drops, buffer_drops, used,
      capacity, high_water, bytes, reconnects;
  uint64_t dwell_us[11];
  uint8_t channel;
} diagnostics_t;
extern diagnostics_t diag;
extern uint32_t boot_id;
extern uint8_t active_session[16];
extern bool capturing;
extern uint16_t dwell_ms;
extern uint8_t first_channel, channel_count;
void capture_init(void);
void capture_set(bool enabled);
bool capture_config(uint16_t dwell, uint8_t first, uint8_t count);
size_t ring_peek(observation_t *out, size_t max);
void ring_consume(size_t count);
void ring_clear(void);
bool capture_drained(void);
bool ap_get(uint16_t id, ap_entry_t *out);
void transport_init(void);
void transport_received(const uint8_t *d, size_t n, int source);
bool transport_send(uint8_t type, uint32_t seq, const uint8_t *d, size_t n);
void transport_poll(void);
void usb_network_init(void);
bool usb_send(const uint8_t *d, size_t n);
bool usb_connected(void);
void mapper_command(uint8_t type, const uint8_t *d, size_t n);
