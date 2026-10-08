#include "mosh_driver.h"

#include <string>
#include <cstring>
#include <cstdlib>
#include <new>

#include "completeterminal.h"
#include "networktransport.h"
#include "user.h"
#include "terminaldisplay.h"
#include "parser.h"

/* Network::Transport is a template whose methods live in the -impl headers;
 * mosh's own client (stmclient.cc) is the only thing that pulls them in, and
 * this driver replaces it. Without this include the transport's constructor,
 * recv(), tick() and wait_time() are declared but never instantiated, and the
 * link fails with undefined symbols. fatal_assert.h comes first because the
 * impl uses its macro. */
#include "fatal_assert.h"
#include "networktransport-impl.h"

/* mosh keeps its own clock (Network::timestamp), and it is not a clock: it
 * reads a cache that only mosh's Select::select() refreshes. The stock client
 * drives one, so it never notices. We drive our own run loop — iOS gives the
 * UDP socket to whoever created it, and that is this process — so unless the
 * cache is refreshed the clock stays where it started, `now` is forever short
 * of every deadline, and tick() decides there is never anything to send. The
 * session still works: the server reaches us, and its output arrives, but
 * every keystroke is withheld. Refreshing here is what makes the clock a
 * clock again. */
#include "timestamp.h"

/* Mirrors NetworkType in stmclient.h: a UserStream up, a Complete down. */
typedef Network::Transport<Network::UserStream, Terminal::Complete> NetworkType;

struct mosh_driver {
    Terminal::Framebuffer local_framebuffer;   /* what the screen currently shows */
    Terminal::Framebuffer new_state;           /* what the server says it should be */
    Terminal::Display display;
    Network::UserStream blank;
    Terminal::Complete local_terminal;
    std::shared_ptr<NetworkType> network;
    int cols, rows;
    bool shut_down;
};

static char *dup_string(const std::string &s)
{
    char *out = static_cast<char *>(malloc(s.size() + 1));
    if (out == nullptr) {
        return nullptr;
    }
    memcpy(out, s.data(), s.size());
    out[s.size()] = '\0';
    return out;
}

extern "C" mosh_driver *mosh_start(const char *key, const char *ip, const char *port,
                                   int cols, int rows)
{
    if (key == nullptr || ip == nullptr || port == nullptr || cols <= 0 || rows <= 0) {
        return nullptr;
    }

    /* raw storage: Terminal::Display has no default constructor, so the
       members are constructed in place rather than by new mosh_driver. */
    void *storage = malloc(sizeof(mosh_driver));
    if (storage == nullptr) {
        return nullptr;
    }
    mosh_driver *d = static_cast<mosh_driver *>(storage);

    /* Construct in place; Framebuffer/Display are not assignable after the
       fact, and the transport needs the terminal to exist first. */
    new (&d->local_framebuffer) Terminal::Framebuffer(cols, rows);
    new (&d->new_state) Terminal::Framebuffer(1, 1);
    /* Display(false): do not consult $TERM. iOS has no terminfo database and
       no TERM; the compiled-in entry is the one we provisioned, and asking
       for anything else would fail. */
    new (&d->display) Terminal::Display(false);
    new (&d->blank) Network::UserStream();
    new (&d->local_terminal) Terminal::Complete(cols, rows);
    d->cols = cols;
    d->rows = rows;
    d->shut_down = false;

    try {
        d->network = std::shared_ptr<NetworkType>(
            new NetworkType(d->blank, d->local_terminal, key, ip, port));
    } catch (const std::exception &) {
        /* Bad key, or a socket the OS refused. Either way there is no session
           to return, and Swift reports the failure rather than us aborting. */
        mosh_stop(d);
        return nullptr;
    }

    d->network->set_send_delay(1); /* minimal delay on outgoing keystrokes */

    /* Diagnostic only: mosh then prints every fragment it sends and its own
       view of the sender's timing, which is the difference between "the
       keystrokes never got sent" and "they were sent and ignored". */
    if (getenv("CQUTMOSH_VERBOSE") != nullptr) {
        d->network->set_verbose(1);
    }

    /* Tell the server our size before anything else, as the stock client does. */
    d->network->get_current_state().push_back(Parser::Resize(cols, rows));

    return d;
}

extern "C" int mosh_socket_fd(mosh_driver *d)
{
    if (d == nullptr || !d->network) {
        return -1;
    }
    /* A client has exactly one socket. */
    const std::vector<int> fds = d->network->fds();
    return fds.empty() ? -1 : fds.front();
}

extern "C" int mosh_wait_time(mosh_driver *d)
{
    if (d == nullptr || !d->network) {
        return 100;
    }
    return d->network->wait_time();
}

extern "C" const char *mosh_send_error(mosh_driver *d)
{
    if (d == nullptr || !d->network) {
        return "";
    }
    return d->network->get_send_error().c_str();
}

extern "C" void mosh_push_keys(mosh_driver *d, const char *bytes, size_t len)
{
    if (d == nullptr || !d->network || bytes == nullptr || len == 0) {
        return;
    }
    /* Before the state change, so the sender's mindelay clock starts from the
       real present rather than from whenever it was last ticked. */
    freeze_timestamp();

    Network::UserStream &us = d->network->get_current_state();
    for (size_t i = 0; i < len; i++) {
        us.push_back(Parser::UserByte(bytes[i]));
    }
}

extern "C" void mosh_push_resize(mosh_driver *d, int cols, int rows)
{
    if (d == nullptr || !d->network || cols <= 0 || rows <= 0) {
        return;
    }
    d->cols = cols;
    d->rows = rows;
    d->network->get_current_state().push_back(Parser::Resize(cols, rows));
}

extern "C" void mosh_tick(mosh_driver *d)
{
    if (d != nullptr && d->network) {
        /* See the note on timestamp.h: mosh's clock is a cache that only its
           own select loop refills, and this driver is the select loop. */
        freeze_timestamp();
        d->network->tick();
    }
}

extern "C" char *mosh_recv(mosh_driver *d)
{
    if (d == nullptr || !d->network) {
        return nullptr;
    }
    try {
        d->network->recv();
    } catch (const std::exception &) {
        /* A malformed or unauthorised datagram is not fatal to the session;
           mosh's own client treats receiver errors as recoverable too. */
        return nullptr;
    }

    d->new_state = d->network->get_latest_remote_state().state.get_fb();

    /* Diff against what the screen already shows, so we emit only the change.
       `true` = initialized; the first frame after construction is not. */
    std::string diff = d->display.new_frame(true, d->local_framebuffer, d->new_state);
    d->local_framebuffer = d->new_state;

    if (diff.empty()) {
        return nullptr;
    }
    return dup_string(diff);
}

extern "C" char *mosh_initial_frame(mosh_driver *d)
{
    if (d == nullptr) {
        return nullptr;
    }
    std::string init = d->display.new_frame(false, d->local_framebuffer, d->local_framebuffer);
    return dup_string(init);
}

extern "C" char *mosh_shutdown(mosh_driver *d)
{
    if (d == nullptr) {
        return nullptr;
    }
    d->shut_down = true;
    if (d->network) {
        d->network->start_shutdown();
    }
    return dup_string(d->display.close());
}

extern "C" int mosh_still_connecting(mosh_driver *d)
{
    if (d == nullptr || !d->network) {
        return 1;
    }
    return d->network->get_remote_state_num() == 0 ? 1 : 0;
}

extern "C" int mosh_shutdown_done(mosh_driver *d)
{
    if (d == nullptr || !d->network) {
        return 1;
    }
    return d->network->shutdown_acknowledged() ? 1 : 0;
}

extern "C" void mosh_free(char *string)
{
    free(string);
}

extern "C" void mosh_stop(mosh_driver *d)
{
    if (d == nullptr) {
        return;
    }
    d->network.reset();
    d->display.~Display();
    d->local_terminal.~Complete();
    d->blank.~UserStream();
    d->new_state.~Framebuffer();
    d->local_framebuffer.~Framebuffer();
    /* freed, not deleted: the storage was malloc'd so the non-default-
       constructible members could be built in place. */
    free(d);
}