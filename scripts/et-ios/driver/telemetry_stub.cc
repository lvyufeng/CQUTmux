/*
 * TelemetryService is compiled out on iOS (-DNO_TELEMETRY drops the Datadog and
 * Sentry senders), but the *class* is not: TerminalClient's constructor calls
 * logToDatadog("Connection Established", ...) from inside the retry loop, and
 * ET guards that call with a runtime `exists()` check rather than an #ifdef. So
 * the symbols still have to exist even though nothing can ever be sent.
 *
 * Rather than compile TelemetryService.cpp with its network paths gutted, this
 * supplies the two missing symbols directly. It is the smaller lie: the
 * behaviour is exactly the "telemetry disabled" path — the constructor's
 * NO_TELEMETRY branch returns before doing anything — and the members used are
 * the real ones, so the class layout is unchanged for every translation unit
 * that sees the header.
 */
#include "TelemetryService.hpp"

namespace et {

shared_ptr<TelemetryService> TelemetryService::telemetryServiceInstance;

TelemetryService::TelemetryService(const bool _allow, const string& databasePath,
                                   const string& environment)
    : allowed(false), environment(environment), shuttingDown(false) {
  /* _allow is deliberately dropped. The caller passes the --telemetry flag,
     which is off by default; on iOS there is nothing that could honour an
     opt-in, so reporting "allowed" would be a lie. */
  (void)_allow;
  (void)databasePath;
}

TelemetryService::~TelemetryService() = default;

void TelemetryService::logToDatadog(const string& logText, el::Level logLevel,
                                    const string& filename, const int line) {
  /* Same "not allowed" short-circuit the real implementation opens with. */
  (void)logText;
  (void)logLevel;
  (void)filename;
  (void)line;
}

void TelemetryService::logToSentry(el::Level level, const std::string& message) {
  (void)level;
  (void)message;
}

void TelemetryService::shutdown() {
  /* Nothing was ever started, so there is no thread to join. */
  shuttingDown = true;
}

}  // namespace et