/* mosh includes <term.h> right after <curses.h>; there is no term.h on iOS,
 * and the surface it needs is the same three calls. */
#ifndef CQUTMUX_TERM_H
#define CQUTMUX_TERM_H
#include "terminfo-shim.h"
#endif
