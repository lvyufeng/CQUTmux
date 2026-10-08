/* Implements the three terminfo entry points mosh uses, against the compiled-in
 * entry in terminfo-db.h. Links to nothing — the real setupterm in the iOS
 * SDK's libncurses.tbd is never called, which is the point: there is no
 * terminfo database on iOS for it to find.
 */
#include "terminfo-shim.h"
#include "terminfo-db.h"

#include <stdlib.h>
#include <string.h>

static int cqutmux_term_active = 0;

/* setupterm(term, fd, *errret): mosh passes term == NULL and reads the name
 * from $TERM. iOS gives the app no $TERM, so the compiled-in name is the
 * answer either way — this is a fixed "terminal", not a lookup. */
int setupterm(const char *term, int filedes, int *errret)
{
    (void)filedes;
    /* Only xterm-256color is provisioned. Anything else is unknown type
       rather than a silent lie about capabilities we do not have. */
    if (term == NULL || term[0] == '\0') {
        static const char *env = 0;
        if (env == 0) {
            env = getenv("TERM");
        }
        if (env == 0 || strcmp(env, cqutmux_term_name) != 0) {
            if (errret) {
                *errret = CQUTMUX_TERM_UNKNOWN_TYPE;
            }
            return ERR;
        }
    } else if (strcmp(term, cqutmux_term_name) != 0) {
        if (errret) {
            *errret = CQUTMUX_TERM_UNKNOWN_TYPE;
        }
        return ERR;
    }

    cqutmux_term_active = 1;
    if (errret) {
        *errret = 0;
    }
    return OK;
}

/* Scratch space for a string capability, mirroring terminfo's contract that
 * the returned pointer stays valid until the next call. */
static char cqutmux_term_scratch[128];

char *tigetstr(const char *capname)
{
    if (!cqutmux_term_active || capname == NULL) {
        return (char *)-1;
    }
    for (const struct cqutmux_term_cap *cap = cqutmux_term_caps; cap->name; cap++) {
        if (strcmp(cap->name, capname) == 0) {
            /* mosh's ti_str() compares against (const char *)-1 to detect a
               missing capability, so a present-but-empty one must not be -1. */
            size_t len = strlen(cap->value);
            if (len >= sizeof(cqutmux_term_scratch)) {
                len = sizeof(cqutmux_term_scratch) - 1;
            }
            memcpy(cqutmux_term_scratch, cap->value, len);
            cqutmux_term_scratch[len] = '\0';
            return cqutmux_term_scratch;
        }
    }
    return (char *)-1;
}

int tigetflag(const char *capname)
{
    if (!cqutmux_term_active || capname == NULL) {
        return -1;
    }
    for (const struct cqutmux_term_cap *cap = cqutmux_term_caps; cap->name; cap++) {
        if (strcmp(cap->name, capname) == 0) {
            return 1;
        }
    }
    return -1;
}