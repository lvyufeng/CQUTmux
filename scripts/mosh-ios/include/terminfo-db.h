/* The terminfo entry mosh's Terminal::Display asks for, compiled in.
 *
 * iOS has no terminfo database for setupterm() to read, and mosh needs a
 * terminal before its first byte of output. xterm-256color is what the app
 * requests from the server anyway (TransportConfiguration.terminalType), so
 * the two ends agree by construction.
 *
 * The strings are copied verbatim from `infocmp xterm-256color` rather than
 * recalled from memory; only the capabilities mosh actually queries are here.
 * It is a read-only stand-in — mosh never calls setaf/setab/putp, it emits
 * its own escapes in terminaldisplay.cc.
 */
#ifndef CQUTMUX_TERMINFO_DB_H
#define CQUTMUX_TERMINFO_DB_H

#include <string.h>

#define CQUTMUX_TERM_UNKNOWN (-2)
#define CQUTMUX_TERM_HARDCOPY 1
#define CQUTMUX_TERM_UNKNOWN_TYPE 0

/* Terminal name mosh requests; must match the PTY request we make. */
static const char *const cqutmux_term_name = "xterm-256color";

struct cqutmux_term_cap {
    const char *name;
    const char *value; /* NULL for a false boolean; "" is a present-but-empty string */
};

static const struct cqutmux_term_cap cqutmux_term_caps[] = {
    /* Boolean: background-colour erase. Declared true in xterm-256color. */
    { "bce", (const char *)1 },
    /* String: erase N characters. */
    { "ech", "\033[%p1%dX" },
    { "clear", "\033[H\033[2J" },
    { "civis", "\033[?25l" },
    { "cnorm", "\033[?12l\033[?25h" },
    { "cup", "\033[%i%p1%d;%p2%dH" },
    /* Alternate screen, which mosh wraps the session in. */
    { "smcup", "\033[?1049h" },
    { "rmcup", "\033[?1049l" },
    /* Omitted deliberately: the argument-taking caps (setaf, setab, …) mosh
       never calls. Returning NULL for them is honest; a caller that did ask
       would raise rather than get a wrong escape. */
    { NULL, NULL }
};

#endif