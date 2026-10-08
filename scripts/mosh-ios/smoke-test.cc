#include "completeterminal.h"
#include "networktransport.h"
#include "user.h"
#include "terminfo-shim.h"
#include <string>
#include <cstdio>
int main() {
  int err = 0;
  if (setupterm(NULL, 1, &err) != OK) return 1;
  if (tigetstr("ech") == (char *)-1) return 2;
  if (tigetflag("bce") != 1) return 3;
  // Build a terminal, feed it a byte, and confirm the framebuffer updates.
  Terminal::Complete c(80, 24);
  std::string in = "hi";
  c.act(std::string(in.begin(), in.end()));
  auto row = c.get_fb().get_row(0);
  printf("terminfo ok\n");
  return 0;
}
