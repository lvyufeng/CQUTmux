import Foundation

/// What a commit changed, as the History tab's row states it.
///
/// The one rule here is that "no diffstat" and "changed nothing" are different
/// answers, and only one of them is real. git prints no `--shortstat` line for a
/// merge commit, so those counts arrive absent; drawing them as zeros would put
/// `0 files` on every merge in the list, which reads as a commit that touched
/// nothing rather than one git did not diff. Absent stays absent — `init?`
/// returns nil and the row draws no summary at all.
///
/// Foundation-only on purpose: `scripts/revision-check.sh` compiles this file on
/// its own, so it must not import SwiftUI.
struct CommitStat: Equatable {
    var files: Int
    var insertions: Int
    var deletions: Int

    /// Nil when the host reported no diffstat for the commit — a merge, or a
    /// host that predates the field.
    init?(files: Int?, insertions: Int?, deletions: Int?) {
        guard let files else { return nil }
        self.files = files
        self.insertions = insertions ?? 0
        self.deletions = deletions ?? 0
    }

    /// "1 file" / "3 files".
    var filesLabel: String { files == 1 ? "1 file" : "\(files) files" }

    /// "+12", or nil when the commit added nothing.
    ///
    /// A bare `+0` is a claim about the diff — that this commit added no lines
    /// — which is true and not worth the width on a row that already carries a
    /// file count and a date. Omitted rather than coloured grey.
    var insertionsLabel: String? { insertions > 0 ? "+\(insertions)" : nil }

    /// "-3", or nil when the commit removed nothing.
    var deletionsLabel: String? { deletions > 0 ? "-\(deletions)" : nil }
}
