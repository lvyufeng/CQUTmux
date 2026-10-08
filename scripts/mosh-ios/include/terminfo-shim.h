/* Minimal terminfo surface for mosh on iOS.
 *
 * iOS ships libncurses.tbd (it exports setupterm/tigetstr/tigetflag) but no
 * headers and no terminfo database. mosh's Terminal::Display uses exactly
 * three entry points, so declaring them here is cheaper and far more stable
 * than cross-compiling ncurses. The database that setupterm would have read
 * is compiled in by terminfo-db.h instead.
 */
#ifndef CQUTMUX_TERMINFO_SHIM_H
#define CQUTMUX_TERMINFO_SHIM_H

#ifdef __cplusplus
extern "C" {
#endif

/* ncurses' OK is 0; mosh checks `ret != OK`. */
#define OK 0
#define ERR (-1)

int setupterm(const char *term, int filedes, int *errret);
char *tigetstr(const char *capname);
int tigetflag(const char *capname);

#ifdef __cplusplus
}
#endif

#endif
