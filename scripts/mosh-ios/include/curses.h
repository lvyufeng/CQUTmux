/* Stands in for a curses header on iOS, where the SDK ships libncurses.tbd
 * but no headers. mosh's #if ladder picks this via HAVE_CURSES_H; everything
 * it actually calls is declared in terminfo-shim.h. */
#ifndef CQUTMUX_CURSES_H
#define CQUTMUX_CURSES_H
#include "terminfo-shim.h"
#endif
