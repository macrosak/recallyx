import Foundation

/// Pure decision logic for the Settings "Command-line tool" install row.
///
/// The app ships the `recallyx` CLI inside the bundle at
/// `Contents/Helpers/recallyx`; the Install button symlinks it into
/// `/usr/local/bin/recallyx`. This helper decides what the row should present
/// given the *observed* state of the filesystem, so the actual FileManager
/// probing/symlink ops stay a thin, near-logic-free shell around it (and this
/// stays unit-testable without touching `/usr/local/bin`).
///
/// We deliberately never escalate privileges: when `/usr/local/bin` is missing
/// or not writable we surface a copy-pasteable `ln -s` command instead of
/// prompting for an admin password.
public enum CLIInstall {
    /// The standard install location.
    public static let defaultLinkPath = "/usr/local/bin/recallyx"

    /// What the CLI-install row should present.
    public enum Status: Equatable {
        /// A symlink at `linkPath` already resolves to this bundle's helper.
        case installed(linkPath: String)
        /// A symlink/file at `linkPath` points somewhere else (a stale link to
        /// an old bundle, or a foreign binary) and the dir is writable — Install
        /// should replace it.
        case conflict(linkPath: String)
        /// Nothing is at `linkPath` and the bin dir is writable — offer Install.
        case installable(linkPath: String)
        /// The bin dir is missing or not writable — no button; show the manual
        /// `ln -s` command in the caption instead.
        case manual(command: String)
    }

    /// Decide the row's state from observed filesystem facts.
    ///
    /// - Parameters:
    ///   - helperPath: absolute path to the bundled CLI (`Contents/Helpers/recallyx`).
    ///   - linkPath: where we'd install the symlink.
    ///   - linkExists: whether *anything* (symlink, file, dir) is at `linkPath`.
    ///   - linkTarget: the resolved absolute destination of an existing symlink
    ///     at `linkPath`, or `nil` when it isn't a symlink / nothing is there.
    ///   - binDirWritable: whether the containing dir exists and is writable.
    public static func status(helperPath: String,
                              linkPath: String = defaultLinkPath,
                              linkExists: Bool,
                              linkTarget: String?,
                              binDirWritable: Bool) -> Status {
        if linkExists {
            if linkTarget == helperPath {
                return .installed(linkPath: linkPath)
            }
            // Something is there but not our current helper. If the dir is
            // writable we can replace it; otherwise fall back to the command.
            return binDirWritable
                ? .conflict(linkPath: linkPath)
                : .manual(command: manualCommand(helperPath: helperPath, linkPath: linkPath))
        }
        return binDirWritable
            ? .installable(linkPath: linkPath)
            : .manual(command: manualCommand(helperPath: helperPath, linkPath: linkPath))
    }

    /// The copy-pasteable command shown when we can't install directly. `-f` so
    /// it replaces a stale link and is safe to re-run.
    public static func manualCommand(helperPath: String, linkPath: String = defaultLinkPath) -> String {
        "ln -sf \"\(helperPath)\" \(linkPath)"
    }
}
