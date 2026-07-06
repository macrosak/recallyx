import Foundation

/// First-run "starter action showcase". On a true first launch we seed one
/// sample clip and show a one-line hint teaching the ⇥ actions flow, so a new
/// user's very first ⌘⇧V demonstrates the product's core idea — per-clip action
/// pipelines. Existing installs (and any later empty store) never see it.
///
/// All the decision logic is pure and unit-tested here; the app wires it into
/// `HistoryPanelController.show()` (seed + hint) and persists the two gate flags
/// in `AppSettings` (`firstRunHandled`, `firstRunShowcaseCompleted`).
public enum FirstRunShowcase {
    /// Seed the sample clip only when BOTH gates hold: the store is empty AND
    /// the seed decision hasn't been made yet (`handled`).
    ///
    /// Two gates because `RECALLYX_DATA_DIR` isolates the history store but NOT
    /// UserDefaults — once the owner has run the real app once, `handled` is
    /// persisted, so a later debug run with a fresh (empty) data dir must not
    /// re-seed. The empty-store gate alone would re-trigger every fresh dir.
    public static func shouldSeed(storeIsEmpty: Bool, handled: Bool) -> Bool {
        storeIsEmpty && !handled
    }

    /// The teaching hint shows in list mode until the showcase is completed —
    /// the user opened an action menu once, or dismissed the hint. `completed`
    /// is persisted, so the hint never reappears after that (idempotent).
    public static func shouldShowHint(completed: Bool) -> Bool {
        !completed
    }

    /// A compact one-line JSON clip whose obvious next step is "Pretty-print
    /// JSON" — a zero-config, offline built-in action (python3 filter, no API
    /// key needed), so even a brand-new user with no providers configured can
    /// run the demo end to end.
    public static let sampleJSON =
        #"{"app":"Recallyx","tip":"press Tab to run actions","pipeline":["script","ai"],"pinned":false}"#

    /// The saved action the hint points at (a built-in in `Action.defaults()`).
    public static let sampleActionName = "Pretty-print JSON"

    /// Provenance label for the seeded sample, so it reads as coming from the app.
    public static let sampleSourceAppName = "Recallyx"
}
