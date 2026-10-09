import CQUTTransport

/// The half of `IntegrationSettings` that needs the transport package.
///
/// Kept out of `IntegrationSettings.swift` so that file compiles with Foundation
/// alone, which is what lets `scripts/integrations-check.sh` exercise the marker
/// rules without a simulator — the same reason `CloudTranscription` is split
/// from `CloudDictation`.
extension TransportConfiguration {
    /// Adds this app's exported environment on top of whatever the
    /// configuration already carries.
    ///
    /// Mosh needs this even though it also gets the export line typed into the
    /// session: mosh-server builds the session's environment itself from its own
    /// `-l` arguments, so the configuration is what the launcher reads to
    /// produce that list.
    ///
    /// Applied at connect time rather than defaulted where the configuration is
    /// built: the toggle is a live setting, and a value captured at
    /// construction would keep exporting after the user turned it off. Merging
    /// rather than replacing leaves the transport's own defaults — `LANG`,
    /// which both ends need — alone.
    mutating func applyIntegrationMarkers(_ settings: IntegrationSettings) {
        for (name, value) in settings.environment {
            environment[name] = value
        }
    }
}
