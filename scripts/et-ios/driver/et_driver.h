/*
 * A C surface over Eternal Terminal's client core, for use from Swift.
 *
 * ET's stock client ("et") assumes it owns a local terminal: it spawns a shell
 * on a pty, and it starts its own server by shelling out to `ssh`. iOS can do
 * neither — no fork, no exec — but ET does not need either. Its Console
 * interface (src/terminal/Console.hpp) exists so a front end that is not a pty
 * can drive TerminalClient, and its SSH bootstrap is only a `SubprocessUtils`
 * call, which is substitutable. This driver supplies both, and leaves the
 * protocol, crypto and reconnect logic alone.
 *
 * The caller owns the run loop. Unlike mosh, ET speaks TCP, so there is no
 * socket-handoff problem: this file owns the connection and exposes it as a
 * file descriptor to poll. That difference is the whole reason ET is reachable
 * on iOS where a UDP-forwarding scheme would not be.
 */
#ifndef CQUTMUX_ET_DRIVER_H
#define CQUTMUX_ET_DRIVER_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct et_driver et_driver;

/* Starts a session. `id` and `passkey` must be the pair the server was given
 * (see et_make_credentials); `host`/`port` locate the TCP endpoint.
 *
 * Returns NULL if the connection could not be established. */
et_driver *et_start(const char *id, const char *passkey, const char *host, int port,
                    int cols, int rows);

/* Generates a fresh id/passkey pair. The caller starts the server with them.
 * Writes NUL-terminated strings into the buffers, which must hold
 * `et_id_length()` and `et_passkey_length()` bytes respectively. */
void et_make_credentials(char *id_out, char *passkey_out);
int et_id_length(void);
int et_passkey_length(void);

/* The TCP socket to poll for readability, so the caller can sleep instead of
 * spinning. -1 when not connected.
 *
 * This is not how output is read — et_recv is — and it CHANGES: ET tears the
 * socket down and opens a new one when it reconnects, which is the whole point
 * of the protocol. Treat it as a hint that may go stale; polling et_recv on a
 * timer is always correct. */
int et_socket_fd(et_driver *driver);

/* Feed terminal input. */
void et_push_keys(et_driver *driver, const char *bytes, size_t len);

/* Tell ET the terminal changed size. */
void et_push_resize(et_driver *driver, int cols, int rows);

/* Read one chunk of terminal output, NUL-terminated, or NULL when nothing is
 * pending. Free with et_free.
 *
 * ET runs its own loop on its own thread — it is a reconnecting client, not a
 * library that hands you a socket — so this only drains what that loop has
 * produced. Call it on a timer. */
char *et_recv(et_driver *driver);

/* False while the session is still being established. */
int et_still_connecting(et_driver *driver);

/* True once ET has given up on the connection (its own retries exhausted). */
int et_connection_lost(et_driver *driver);

void et_free(char *string);
void et_stop(et_driver *driver);

#ifdef __cplusplus
}
#endif

#endif /* CQUTMUX_ET_DRIVER_H */