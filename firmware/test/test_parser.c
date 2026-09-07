#include "frame_parser.h"
#include "protocol_constants.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
int main(void) {
  uint8_t frame[256] = {0x80};
  for (int i = 0; i < 6; i++)
    frame[16 + i] = i;
  frame[32] = 100;
  frame[34] = 0x11;
  frame[36] = 0;
  frame[37] = 4;
  memcpy(frame + 38, "test", 4);
  frame[42] = 3;
  frame[43] = 1;
  frame[44] = 6;
  ap_frame_t ap;
  assert(parse_management(frame, 45, &ap));
  assert(ap.ssid_len == 4 && !memcmp(ap.ssid, "test", 4));
  assert(ap.channel == 6 && ap.beacon_interval == 100 && ap.capability == 0x11);
  assert(ap.bssid[5] == 5);
  assert(!parse_management(frame, 35, &ap));
  assert(!parse_management(frame, 44, &ap));
  frame[37] = 33;
  assert(!parse_management(frame, 45, &ap));
  frame[37] = 0;
  assert(parse_management(frame, 38, &ap) && ap.ssid_len == 0);
  frame[0] = 0x50;
  assert(parse_management(frame, 38, &ap) && ap.subtype == 5);
  frame[0] = 0x40;
  assert(!parse_management(frame, 38, &ap));
  frame[0] = 0x80;
  frame[37] = 32;
  memset(frame + 38, 'a', 32);
  assert(parse_management(frame, 70, &ap) && ap.ssid_len == 32);
  frame[70] = 48;
  frame[71] = 2;
  frame[72] = 1;
  frame[73] = 0;
  assert(parse_management(frame, 74, &ap) && ap.rsn);
  frame[71] = 1;
  assert(!parse_management(frame, 73, &ap));
  srand(7);
  for (int test = 0; test < 100000; test++) {
    size_t n = rand() % 256;
    for (size_t i = 0; i < n; i++)
      frame[i] = rand();
    parse_management(frame, n, &ap);
  }
  uint8_t bytes[8];
  wr64(bytes, 0x0102030405060708ULL);
  assert(bytes[0] == 8 && bytes[7] == 1 &&
         rd64(bytes) == 0x0102030405060708ULL);
  puts("Parser boundary, metadata, hidden/max SSID, malformed IE, protocol "
       "endian and 100000 fuzz cases passed.");
}
