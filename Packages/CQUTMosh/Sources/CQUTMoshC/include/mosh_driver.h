/* A C surface over mosh's client libraries, for use from Swift.
 *
 * iOS cannot fork or exec, so the stock mosh-client binary can never run here:
 * it is main() driving select() on fd 0/1 and calling tcsetattr on them. This
 * driver keeps everything that makes mosh mosh — the state-sync machines, the
 * crypto, the transport with its roaming — and replaces only the parts that
 * assume a local tty and a process to own it.
 *
 * The caller owns the run loop. Mosh's UDP socket is exposed as a file
 * descriptor to poll (mosh_mosh_fd), because iOS will not hand a UDP socket to
 * anything but the process that created it, and this process is the app.
 *
 * Threading: not thread-safe. Drive it from one thread.
 */
#ifndef CQUTMUX_MOSH_DRIVER_H
#define CQUTMUX_MOSH_DRIVER_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct mosh_driver mosh_driver;

/* Starts a session. `key` is the base64 key mosh-server printed; `ip`/`port`
 * locate it. Returns NULL on a bad key or an unreachable/refused socket. */
mosh_driver *mosh_start(const char *key, const char *ip, const char *port,
                        int cols, int rows);

/* The UDP socket to poll for readability. -1 once stopped. */
int mosh_socket_fd(mosh_driver *driver);

/* Milliseconds until mosh next wants to send (its ack/ping cadence). Poll with
 * this as the timeout; 0 means "now". */
int mosh_wait_time(mosh_driver *driver);

/* Feed terminal input. Bytes are the raw keys from the terminal view. */
void mosh_push_keys(mosh_driver *driver, const char *bytes, size_t len);

/* Tell mosh the terminal changed size. */
void mosh_push_resize(mosh_driver *driver, int cols, int rows);

/* Let mosh send whatever is pending. Call on the wait_time cadence. */
void mosh_tick(mosh_driver *driver);

/* The last sendto() failure, or "" when sends are healthy. mosh records this
 * rather than reporting it, so without asking, a send that never leaves looks
 * exactly like a server that never answers. */
const char *mosh_send_error(mosh_driver *driver);

/* Read one datagram and return the screen update it produced, as a NUL-
 * terminated string of terminal escapes ready for the terminal view, or NULL
 * when the datagram changed nothing. Free with mosh_free. */
char *mosh_recv(mosh_driver *driver);

/* The initial screen, to be written before the first mosh_recv. Free with
 * mosh_free. */
char *mosh_initial_frame(mosh_driver *driver);

/* Begin shutdown; returns the escape to restore the screen. */
char *mosh_shutdown(mosh_driver *driver);

/* True while the server is still being contacted (no state received yet). */
int mosh_still_connecting(mosh_driver *driver);

/* True once both sides have agreed to shut down. */
int mosh_shutdown_done(mosh_driver *driver);

void mosh_free(char *string);
void mosh_stop(mosh_driver *driver);

#ifdef __cplusplus
}
#endif

#endif /* CQUTMUX_MOSH_DRIVER_H */