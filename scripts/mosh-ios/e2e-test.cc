// Drives the iOS mosh client against a real mosh-server and reports what it
// received. This is the end-to-end proof: handshake, crypto, state sync.
#include "mosh_driver.h"
#include <cstdio>
#include <cstring>
#include <vector>
#include <string>
#include <poll.h>
#include <unistd.h>
#include <ctime>

int main(int argc, char **argv) {
  if (argc < 4) { fprintf(stderr, "usage: moshtest <key> <ip> <port>\n"); return 2; }
  mosh_driver *d = mosh_start(argv[1], argv[2], argv[3], 80, 24);
  if (!d) { fprintf(stderr, "mosh_start failed\n"); return 3; }
  int fd = mosh_socket_fd(d);
  printf("socket fd = %d\n", fd);

  std::string screen;
  time_t start = time(NULL);
  bool got = false;
  while (time(NULL) - start < 12) {
    struct pollfd p = { fd, POLLIN, 0 };
    int wt = mosh_wait_time(d);
    if (wt < 0) wt = 0; if (wt > 200) wt = 200;
    poll(&p, 1, wt);
    if (p.revents & POLLIN) {
      char *frame = mosh_recv(d);
      if (frame) { screen += frame; mosh_free(frame); got = true; }
    }
    mosh_tick(d);
    if (mosh_still_connecting(d) == 0 && got) break;
  }
  printf("connecting=%d  chars=%zu\n", mosh_still_connecting(d), screen.size());
  // Show printable content, stripping escapes crudely for a readable check.
  std::string text;
  for (size_t i = 0; i < screen.size(); i++) {
    if (screen[i] == 0x1b) { while (i < screen.size() && !isalpha(screen[i])) i++; continue; }
    if (screen[i] >= 32 && screen[i] < 127) text += screen[i];
  }
  printf("visible: [%s]\n", text.c_str());
  mosh_stop(d);
  return got ? 0 : 1;
}
