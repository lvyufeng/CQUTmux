/*
 * The iOS front end for ET's client core.
 *
 * Two things have to be replaced, and they are the two the stock client gets
 * from being a process on a desktop:
 *
 *   1. The console. ET's own reads and writes a pty. ETTerminalConsole below
 *      collects output for the caller and takes input from it, so the app's
 *      terminal view plays the part of the pty. ET itself does this shape of
 *      thing in test/FakeConsole.hpp, so it is a supported seam rather than a
 *      trick.
 *
 *   2. The SSH bootstrap. ET starts its server with `ssh user@host
 *      'echo id/passkey_TERM | etterminal'` via SubprocessUtils, which forks
 *      and execs. The app already holds an SSH session (the one mosh uses), so
 *      it runs that command through an ExecRequest and passes the id/passkey
 *      in here instead.
 *
 * Everything else — the handshake, the crypto, and the TCP reconnect that is
 * the reason to prefer ET on a network that blocks UDP — is ET's own code,
 * unmodified.
 *
 * Threading: ET's TerminalClient::run() is a blocking loop. It owns a thread.
 * et_recv, et_push_keys and et_push_resize are safe to call from another, which
 * is what the app does. The clock in Network.h turned out to matter for mosh;
 * ET has no equivalent — it reads time() directly — so nothing here has to
 * emulate a select loop.
 */
#include "et_driver.h"

#include <atomic>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>
#include <cstdlib>
#include <cstring>
#include <exception>

#include "Console.hpp"
#include "Headers.hpp"
#include "PipeSocketHandler.hpp"
#include "TelemetryService.hpp"
#include "TerminalClient.hpp"
#include "TcpSocketHandler.hpp"

using namespace et;
using std::string;

namespace {

/* Output waiting to be collected by et_recv. ET writes to the console from its
   own thread whenever terminal data arrives; this hands it over safely. */
class OutputBuffer {
 public:
  void append(const string &s) {
    std::lock_guard<std::mutex> guard(mutex_);
    pending_ += s;
  }

  string take() {
    std::lock_guard<std::mutex> guard(mutex_);
    string out;
    out.swap(pending_);
    return out;
  }

 private:
  std::mutex mutex_;
  string pending_;
};

class ETTerminalConsole : public Console {
 public:
  ETTerminalConsole(std::shared_ptr<OutputBuffer> out, int cols, int rows)
      : out_(std::move(out)), cols_(cols), rows_(rows) {
    /* A pipe so getFd() has something real to return. Nothing is written to
       it: writeSome is overridden below, and the poll loop never gets a short
       write to wait on. */
    int fds[2];
    if (::pipe(fds) == 0) {
      readFd_ = fds[0];
      writeFd_ = fds[1];
      setSocketBlocking(writeFd_, false);
    }
  }

  ~ETTerminalConsole() override {
    if (readFd_ >= 0) ::close(readFd_);
    if (writeFd_ >= 0) ::close(writeFd_);
  }

  std::optional<TerminalInfo> getTerminalInfo() override {
    std::lock_guard<std::mutex> guard(mutex_);
    TerminalInfo ti;
    ti.set_row(rows_);
    ti.set_column(cols_);
    /* A percentage of the screen, which is what ET means by width/height here.
       The app's terminal is the whole screen. */
    ti.set_width(100);
    ti.set_height(100);
    return ti;
  }

  void setup() override {}
  void teardown() override {}

  int getFd() override { return writeFd_; }

  void write(const string &s) override { out_->append(s); }

  size_t writeSome(const string &s) override {
    /* Accepting everything is both true — the buffer is bounded only by
       memory — and necessary: a short write makes ET wait for the output fd to
       become writable, and nothing ever writes to that pipe. */
    out_->append(s);
    return s.size();
  }

  /* Input is pushed in by the caller, not read from a descriptor. An empty
     list is ET's documented way to say "not pollable": it then calls
     readInput on every pass of its loop. */
  std::vector<int> getInputPollFds() override { return {}; }

  int getOutputPollFd() override { return -1; }  // writeSome never goes short

  ConsoleInputStatus readInput(const std::set<int> &, string *out) override {
    std::lock_guard<std::mutex> guard(mutex_);
    if (input_.empty()) {
      return ConsoleInputStatus::NONE;
    }
    out->swap(input_);
    return ConsoleInputStatus::DATA;
  }

  void pushInput(const string &s) {
    std::lock_guard<std::mutex> guard(mutex_);
    input_ += s;
  }

  void setSize(int cols, int rows) {
    std::lock_guard<std::mutex> guard(mutex_);
    cols_ = cols;
    rows_ = rows;
  }

 private:
  std::shared_ptr<OutputBuffer> out_;
  std::mutex mutex_;
  string input_;
  int cols_, rows_;
  int readFd_ = -1, writeFd_ = -1;
};

/* Exists only to reach the connection's socket: TerminalClient keeps
   `connection` protected and exposes no descriptor. The app wants one to sleep
   on instead of polling et_recv, and a stale value is harmless because ET
   replaces the socket on reconnect — so this is a hint, not a handle. */
class IOSClient : public TerminalClient {
 public:
  using TerminalClient::TerminalClient;

  int socketFd() {
    return connection ? connection->getSocketFd() : -1;
  }
};

}  // namespace

struct et_driver {
  std::shared_ptr<OutputBuffer> out;
  std::shared_ptr<ETTerminalConsole> console;
  std::shared_ptr<TcpSocketHandler> socketHandler;
  std::shared_ptr<IOSClient> client;
  std::thread thread;
  std::atomic<bool> started{false};
  std::atomic<bool> finished{false};
  std::atomic<bool> failed{false};
};

void et_make_credentials(char *id_out, char *passkey_out) {
  /* Same shape the stock client generates: 16 and 32 characters, with the id's
     first three pinned so servers that do not mint their own keys stay
     compatible. */
  string id = genRandomAlphaNum(16);
  id[0] = id[1] = id[2] = 'X';
  const string passkey = genRandomAlphaNum(32);
  std::memcpy(id_out, id.c_str(), id.size() + 1);
  std::memcpy(passkey_out, passkey.c_str(), passkey.size() + 1);
}

int et_id_length(void) { return 17; }       /* 16 chars + NUL */
int et_passkey_length(void) { return 33; }  /* 32 chars + NUL */

extern "C" et_driver *et_start(const char *id, const char *passkey,
                               const char *host, int port, int cols, int rows) {
  if (id == nullptr || passkey == nullptr || host == nullptr || port <= 0 ||
      cols <= 0 || rows <= 0) {
    return nullptr;
  }

  et_driver *d = new (std::nothrow) et_driver();
  if (d == nullptr) {
    return nullptr;
  }

  d->out = std::make_shared<OutputBuffer>();
  d->console = std::make_shared<ETTerminalConsole>(d->out, cols, rows);
  d->socketHandler = std::make_shared<TcpSocketHandler>();

  SocketEndpoint endpoint;
  endpoint.set_name(host);
  endpoint.set_port(port);

  /* ET's own main creates this singleton before building the client, and
     TerminalClient calls get() unconditionally from its constructor and its
     connect loop. Without it the first connection attempt aborts with "Tried
     to get a singleton before it was created" — which reads like a driver bug
     but is really a missing startup step, because the driver is standing in
     for main(). The stub in telemetry_stub.cc ignores the allow flag and sends
     nothing; the path is only used for a database directory that no longer
     exists on this platform. */
  if (!TelemetryService::exists()) {
    TelemetryService::create(false, "/tmp/.sentry-native-et", "Client");
  }

  try {
    auto pipeHandler = std::make_shared<PipeSocketHandler>();
    d->client = std::make_shared<IOSClient>(
        d->socketHandler,        /* socketHandler */
        pipeHandler,             /* pipeSocketHandler: local IPC between ET's
                                    own components; only one here, so it is
                                    never used to talk to anything */
        endpoint,                /* what to connect to */
        id, passkey,             /* the pair etserver was started with */
        d->console,
        false,                   /* jumphost */
        "",                      /* tunnels */
        "",                      /* reverseTunnels */
        false,                   /* forwardSshAgent */
        "",                      /* identityAgent */
        5,                       /* keepalive, seconds */
        std::vector<std::pair<string, string>>{},  /* envVars */
        /* noPty false and command empty: the server opens a shell on a pty and
           sends its output down the terminal channel. That is what this front
           end wants — the *local* pty is what ET's stock client supplies and
           iOS cannot, not the remote one. Setting noPty true here would be
           wrong twice over: it is rejected outright unless a command is given,
           and a command turns the session into a one-shot pipe that exits on
           EOF instead of a shell to type into. */
        false,                   /* noPty */
        "",                      /* command */
        std::vector<string>{},   /* dynamicForwards */
        "",                      /* stdioForward */
        3,                       /* maxConnectAttempts: a few, because the
                                    server was started over SSH and may not be
                                    listening yet. ET's own reconnect handles
                                    everything after that. */
        false,                   /* resumeSavedSession */
        []() { return true; },   /* sessionHeartbeat */
        [](const string &) { return true; },  /* sessionTitleUpdate */
        std::nullopt,            /* disconnectTimeoutMinutes */
        false,                   /* noShell */
        false);                  /* exitOnForwardFailure */
  } catch (const std::exception &) {
    et_stop(d);
    return nullptr;
  }

  /* run() is a blocking loop, so it owns this thread. The app's calls are the
     console pushes and et_recv, both of which are safe from elsewhere. */
  d->thread = std::thread([d]() {
    d->started.store(true);
    try {
      d->client->run("", /* noexit */ true);
    } catch (const std::exception &) {
      d->failed.store(true);
    }
    d->finished.store(true);
  });

  return d;
}

extern "C" int et_socket_fd(et_driver *d) {
  if (d == nullptr || !d->client) {
    return -1;
  }
  return d->client->socketFd();
}

extern "C" void et_push_keys(et_driver *d, const char *bytes, size_t len) {
  if (d == nullptr || !d->console || bytes == nullptr || len == 0) {
    return;
  }
  d->console->pushInput(string(bytes, len));
}

extern "C" void et_push_resize(et_driver *d, int cols, int rows) {
  if (d == nullptr || !d->console || cols <= 0 || rows <= 0) {
    return;
  }
  /* TerminalClient notices the change by comparing getTerminalInfo() against
     the last value it sent, so updating the console is the whole of it. */
  d->console->setSize(cols, rows);
}

extern "C" char *et_recv(et_driver *d) {
  if (d == nullptr || !d->out) {
    return nullptr;
  }
  const string pending = d->out->take();
  if (pending.empty()) {
    return nullptr;
  }
  char *out = static_cast<char *>(malloc(pending.size() + 1));
  if (out == nullptr) {
    return nullptr;
  }
  std::memcpy(out, pending.data(), pending.size());
  out[pending.size()] = '\0';
  return out;
}

extern "C" int et_still_connecting(et_driver *d) {
  if (d == nullptr || !d->client) {
    return 1;
  }
  return d->client->isConnected() ? 0 : 1;
}

extern "C" int et_connection_lost(et_driver *d) {
  if (d == nullptr) {
    return 1;
  }
  /* ET retries a dropped link itself; this reports only that its loop has
     ended, which means the session is over rather than paused. */
  return d->finished.load() ? 1 : 0;
}

extern "C" void et_free(char *string) { free(string); }

extern "C" void et_stop(et_driver *d) {
  if (d == nullptr) {
    return;
  }
  if (d->client) {
    d->client->shutdown();
  }
  if (d->thread.joinable()) {
    d->thread.join();
  }
  delete d;
}