// Drives the iOS ET client against a real etserver and reports what it
// received. This is the end-to-end proof: ET's handshake, its crypto, and its
// terminal protocol.
//
// The shape differs from mosh's test in one way that matters. mosh's driver
// owns the socket, so its test polls a file descriptor. ET owns its own
// connection on its own thread — it is a reconnecting client, not a library
// that hands you a socket — so this polls et_recv on a timer instead. That is
// the contract et_driver.h documents, and exercising it is part of the point.
#include "et_driver.h"
#include <cstdio>
#include <cstring>
#include <cstdlib>
#include <string>
#include <unistd.h>
#include <ctime>

static void drain(et_driver *d, std::string *screen) {
  while (char *chunk = et_recv(d)) {
    *screen += chunk;
    et_free(chunk);
  }
}

// What the server actually printed, with the escape sequences dropped, so a
// human reading the log can see the session without a terminal emulator.
static std::string printable(const std::string &screen) {
  std::string text;
  for (size_t i = 0; i < screen.size(); i++) {
    unsigned char c = static_cast<unsigned char>(screen[i]);
    if (c == 0x1b) {
      while (i < screen.size() &&
             !((screen[i] >= 'A' && screen[i] <= 'Z') ||
               (screen[i] >= 'a' && screen[i] <= 'z')))
        i++;
      continue;
    }
    if (c == '\n' || c == '\r' || (c >= 32 && c < 127)) text += c;
  }
  return text;
}

int main(int argc, char **argv) {
  if (argc < 5) {
    fprintf(stderr, "usage: ettest <id> <passkey> <host> <port>\n");
    return 2;
  }
  const char *id = argv[1], *passkey = argv[2], *host = argv[3];
  int port = atoi(argv[4]);

  et_driver *d = et_start(id, passkey, host, port, 100, 30);
  if (!d) {
    fprintf(stderr, "et_start failed\n");
    return 3;
  }

  // Phase 1: connect. The server opens a login shell, which prints a prompt of
  // its own accord — so a non-empty screen before anything is typed is
  // unprompted output, arriving over ET's terminal channel.
  std::string screen;
  time_t start = time(NULL);
  while (time(NULL) - start < 30) {
    drain(d, &screen);
    if (!et_still_connecting(d) && !screen.empty()) break;
    if (et_connection_lost(d)) break;
    usleep(100 * 1000);
  }
  printf("connecting=%d  chars=%zu\n", et_still_connecting(d), screen.size());
  if (screen.empty()) {
    printf("OUTPUT FAILED: nothing arrived from the server\n");
    printf("connection lost: %d\n", et_connection_lost(d));
    et_stop(d);
    return 1;
  }
  printf("--- unprompted output ---\n%s\n", printable(screen).c_str());

  // Phase 2: input. ET's own client echoes locally, but this driver does not —
  // it is a front end, and echoing is the app's business — so the only way the
  // command's *output* can appear is by reaching the server and running. The
  // marker is arithmetic the shell has to evaluate: the client never produces
  // "11".
  screen.clear();
  const char *cmd = "echo ET_E2E_$((10+1))_OK\n";
  et_push_keys(d, cmd, strlen(cmd));
  start = time(NULL);
  while (time(NULL) - start < 20) {
    drain(d, &screen);
    if (screen.find("ET_E2E_11_OK") != std::string::npos) break;
    usleep(100 * 1000);
  }
  if (screen.find("ET_E2E_11_OK") == std::string::npos) {
    printf("INPUT FAILED: the server never ran the typed command\n");
    printf("--- received (%zu bytes) ---\n%s\n", screen.size(),
           printable(screen).c_str());
    et_stop(d);
    return 4;
  }
  printf("input round-trip visible: [%s]\n", printable(screen).c_str());

  // Phase 3: resize. ET sends the new size to the server, which is what makes a
  // full-screen program redraw. There is no way to observe the size from
  // outside, so this checks the weaker but real property that a resize does not
  // disturb the session.
  et_push_resize(d, 120, 40);
  usleep(500 * 1000);
  screen.clear();
  const char *resizeCmd = "echo RESIZE_$((3*8))_OK\n";
  et_push_keys(d, resizeCmd, strlen(resizeCmd));
  start = time(NULL);
  while (time(NULL) - start < 15) {
    drain(d, &screen);
    if (screen.find("RESIZE_24_OK") != std::string::npos) break;
    usleep(100 * 1000);
  }
  if (screen.find("RESIZE_24_OK") == std::string::npos) {
    printf("RESIZE FAILED: the session did not survive a resize\n");
    et_stop(d);
    return 5;
  }
  printf("resize round-trip visible: [%s]\n", printable(screen).c_str());

  // One unambiguous final line, so the caller does not have to infer the
  // verdict from a marker that a shell could have echoed.
  printf("ET_E2E_PASS\n");
  et_stop(d);
  return 0;
}