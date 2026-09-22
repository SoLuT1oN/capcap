import AppKit

final class SourceAppFocusRestorer {
    struct Environment {
        var activate: (pid_t) -> Void
        var frontmostPID: () -> pid_t?
        var isTrusted: () -> Bool
        var postPaste: (pid_t) -> Void

        static let live = Environment(
            activate: { pid in
                guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else { return }
                app.activate(options: [.activateAllWindows])
            },
            frontmostPID: { NSWorkspace.shared.frontmostApplication?.processIdentifier },
            isTrusted: { AXIsProcessTrusted() },
            postPaste: { pid in
                let source = CGEventSource(stateID: .privateState)
                guard let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
                      let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false)
                else { return }
                down.flags = .maskCommand
                up.flags = .maskCommand
                down.postToPid(pid)
                up.postToPid(pid)
            }
        )
    }

    private let processIdentifier: pid_t?
    private let environment: Environment
    private var restoreScheduled = false
    private var pasteScheduled = false

    init(processIdentifier: pid_t?, environment: Environment = .live) {
        self.processIdentifier = processIdentifier
        self.environment = environment
    }

    static func captureFrontmostApplication() -> SourceAppFocusRestorer {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let app = NSWorkspace.shared.frontmostApplication
        let targetPID = app?.processIdentifier == ownPID ? nil : app?.processIdentifier
        return SourceAppFocusRestorer(processIdentifier: targetPID)
    }

    func restore() {
        guard !restoreScheduled else { return }
        restoreScheduled = true

        DispatchQueue.main.async { [self] in
            guard let processIdentifier,
                  processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
            environment.activate(processIdentifier)
        }
    }

    /// Called only after the final encoded image has been written to the clipboard.
    /// Focus restoration is already scheduled by the editor. Never reactivate an
    /// application here: the user may have switched apps while encoding finished.
    func pasteCopiedImage(pasteboard: NSPasteboard = .general) {
        guard !pasteScheduled, let processIdentifier,
              processIdentifier != ProcessInfo.processInfo.processIdentifier,
              environment.isTrusted(),
              pasteboard.availableType(from: [.png, .tiff]) != nil else { return }
        pasteScheduled = true
        waitForPasteTarget(pasteboard: pasteboard, changeCount: pasteboard.changeCount, attemptsRemaining: 20)
    }

    private func waitForPasteTarget(pasteboard: NSPasteboard, changeCount: Int, attemptsRemaining: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [self] in
            guard let processIdentifier,
                  pasteboard.changeCount == changeCount,
                  environment.isTrusted() else { return }
            let activePID = environment.frontmostPID()
            if activePID == processIdentifier {
                environment.postPaste(processIdentifier)
            } else if activePID == ProcessInfo.processInfo.processIdentifier, attemptsRemaining > 1 {
                waitForPasteTarget(pasteboard: pasteboard, changeCount: changeCount,
                                   attemptsRemaining: attemptsRemaining - 1)
            }
            // A different application, changed clipboard, or timeout cancels the paste.
        }
    }
}
