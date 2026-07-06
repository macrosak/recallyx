import Foundation
import Testing
@testable import RecallyxCore

/// `CLIInstall.status` — the pure decision behind the Settings "Command-line
/// tool" install row. No filesystem: it takes observed facts.
@Suite("CLIInstall")
struct CLIInstallTests {
    private let helper = "/Applications/Recallyx.app/Contents/Helpers/recallyx"
    private let link = "/usr/local/bin/recallyx"

    @Test func nothingThere_writable_isInstallable() {
        let status = CLIInstall.status(
            helperPath: helper, linkPath: link,
            linkExists: false, linkTarget: nil, binDirWritable: true
        )
        #expect(status == .installable(linkPath: link))
    }

    @Test func nothingThere_notWritable_showsManualCommand() {
        let status = CLIInstall.status(
            helperPath: helper, linkPath: link,
            linkExists: false, linkTarget: nil, binDirWritable: false
        )
        #expect(status == .manual(command: CLIInstall.manualCommand(helperPath: helper, linkPath: link)))
    }

    @Test func symlinkToOurHelper_isInstalled() {
        let status = CLIInstall.status(
            helperPath: helper, linkPath: link,
            linkExists: true, linkTarget: helper, binDirWritable: true
        )
        #expect(status == .installed(linkPath: link))
    }

    @Test func installedReportedEvenWhenDirNotWritable() {
        // A correct existing link should read as installed regardless of whether
        // we could currently rewrite it.
        let status = CLIInstall.status(
            helperPath: helper, linkPath: link,
            linkExists: true, linkTarget: helper, binDirWritable: false
        )
        #expect(status == .installed(linkPath: link))
    }

    @Test func staleSymlink_writable_isConflict() {
        let status = CLIInstall.status(
            helperPath: helper, linkPath: link,
            linkExists: true,
            linkTarget: "/Users/old/Recallyx.app/Contents/Helpers/recallyx",
            binDirWritable: true
        )
        #expect(status == .conflict(linkPath: link))
    }

    @Test func staleSymlink_notWritable_showsManualCommand() {
        let status = CLIInstall.status(
            helperPath: helper, linkPath: link,
            linkExists: true, linkTarget: "/somewhere/else/recallyx",
            binDirWritable: false
        )
        #expect(status == .manual(command: CLIInstall.manualCommand(helperPath: helper, linkPath: link)))
    }

    @Test func foreignFile_noTarget_writable_isConflict() {
        // A real (non-symlink) file at the path reports linkExists but no target.
        let status = CLIInstall.status(
            helperPath: helper, linkPath: link,
            linkExists: true, linkTarget: nil, binDirWritable: true
        )
        #expect(status == .conflict(linkPath: link))
    }

    @Test func manualCommand_isReRunnable() {
        #expect(CLIInstall.manualCommand(helperPath: helper, linkPath: link)
            == "ln -sf \"\(helper)\" \(link)")
    }
}
