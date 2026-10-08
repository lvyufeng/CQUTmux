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
  // Now the input half. Type a command and expect the shell to answer it.
  // Nothing here reports success on its own — mosh never echoes keystrokes
  // locally, so the only way the text can appear is by the server running it
  // and sending the result back.
  std::string server_saw = screen;
  printf("connecting=%d  chars=%zu\n", mosh_still_connecting(d), server_saw.size());
  if (server_saw.find("MOSH_E2E_OK") == std::string::npos) {
    printf("OUTPUT FAILED: the server's greeting never arrived\n");
    mosh_stop(d);
    return 1;
  }

  // The input half. The session is an interactive shell, which echoes what it
  // reads and then runs it, so a successful round trip shows the command AND
  // its expansion. The marker is arithmetic the shell has to evaluate: the
  // client never produces "24".
  const char *cmd = "echo TYPED_$((20+4))_OK\n";
  mosh_push_keys(d, cmd, strlen(cmd));
  screen.clear();
  start = time(NULL);
  while (time(NULL) - start < 8) {
    struct pollfd p = { fd, POLLIN, 0 };
    int wt = mosh_wait_time(d);
    if (wt < 0) wt = 0; if (wt > 200) wt = 200;
    poll(&p, 1, wt);
    if (p.revents & POLLIN) {
      char *frame = mosh_recv(d);
      if (frame) { screen += frame; mosh_free(frame); }
    }
    mosh_tick(d);
    if (screen.find("TYPED_24_OK") != std::string::npos) break;
  }
  if (screen.find("TYPED_24_OK") == std::string::npos) {
    printf("INPUT FAILED: the server never ran the typed command\n");
    mosh_stop(d);
    return 4;
  }
  // Both halves are proven: output came down, input went up and was run.
  // Show printable content, stripping escapes crudely, so a human reading the
  // log can see what the screen held.
  std::string text;
  for (size_t i = 0; i < screen.size(); i++) {
    if (screen[i] == 0x1b) { while (i < screen.size() && !isalpha(screen[i])) i++; continue; }
    if (screen[i] >= 32 && screen[i] < 127) text += screen[i];
  }
  printf("input round-trip visible: [%s]\n", text.c_str());
  mosh_stop(d);
  return 0;
}
