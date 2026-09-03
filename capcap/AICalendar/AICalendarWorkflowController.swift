import AppKit
import Foundation

enum AICalendarWorkflowPhase: Equatable {
    case idle
    case recognizing(UUID)
    case confirming(UUID)
}

struct AICalendarWorkflowState: Equatable {
    private(set) var phase: AICalendarWorkflowPhase = .idle

    @discardableResult
    mutating func begin(requestID: UUID) -> Bool {
        guard phase == .idle else { return false }
        phase = .recognizing(requestID)
        return true
    }

    @discardableResult
    mutating func markAwaitingConfirmation(requestID: UUID) -> Bool {
        guard phase == .recognizing(requestID) else { return false }
        phase = .confirming(requestID)
        return true
    }

    @discardableResult
    mutating func finish(requestID: UUID) -> Bool {
        switch phase {
        case .recognizing(let activeID), .confirming(let activeID):
            guard activeID == requestID else { return false }
            phase = .idle
            return true
        case .idle:
            return false
        }
    }
}

@MainActor
final class AICalendarWorkflowController {
    static let shared = AICalendarWorkflowController()

    private(set) var state = AICalendarWorkflowState()
    private var workflowTask: Task<Void, Never>?
    private var extractionTask: Task<[AICalendarEventDraft], Error>?
    private var eventService: CalendarEventService?
    private var confirmationController: AICalendarConfirmationController?
    private var requestScreen: NSScreen?

    private init() {}

    /// Starts one app-wide request. Returning nil means another request is
    /// already recognizing or waiting for confirmation.
    @discardableResult
    func start(
        image: NSImage,
        config: AICalendarConfig = AICalendarConfig.load().normalized(),
        screen: NSScreen
    ) -> UUID? {
        let requestID = UUID()
        guard state.begin(requestID: requestID) else { return nil }

        let calendarService = CalendarEventService()
        let aiService = AICalendarService(config: config)
        eventService = calendarService
        requestScreen = screen

        workflowTask = Task { @MainActor [weak self] in
            do {
                // Calendar permission is requested only after the user starts
                // this workflow, before any detached extraction work.
                try await calendarService.ensureFullAccess()
                try Task.checkCancellation()

                guard let self, self.isCurrent(requestID) else { return }

                // Encoding and network work must not block the main actor.
                let extractionTask = Task.detached(priority: .userInitiated) {
                    try await aiService.extract(from: image)
                }
                self.extractionTask = extractionTask
                let events = try await extractionTask.value
                try Task.checkCancellation()

                guard self.isCurrent(requestID) else { return }
                self.finishExtraction(requestID: requestID, events: events)
            } catch is CancellationError {
                self?.cancelled(requestID: requestID)
            } catch {
                guard let self, self.isCurrent(requestID) else { return }
                self.finishFailure(requestID: requestID, error: error)
            }
        }
        return requestID
    }

    /// Convenience overload for callers that already validated the stored
    /// configuration and want the coordinator to load it itself.
    @discardableResult
    func start(image: NSImage, screen: NSScreen) -> UUID? {
        start(image: image, config: AICalendarConfig.load().normalized(), screen: screen)
    }

    /// The editor's overlay dismisses its own toast during teardown. Show the
    /// progress toast only after that dismissal, and only for the live token.
    func showProgressAfterEditorDismissal(requestID: UUID, screen: NSScreen) {
        guard isCurrent(requestID), case .recognizing = state.phase else { return }
        ToastWindow.show(message: L10n.aiCalendarAnalyzing, on: screen, duration: 2.0)
    }

    @discardableResult
    func finish(requestID: UUID) -> Bool {
        guard state.finish(requestID: requestID) else { return false }
        workflowTask?.cancel()
        extractionTask?.cancel()
        workflowTask = nil
        extractionTask = nil
        confirmationController = nil
        eventService = nil
        requestScreen = nil
        return true
    }

    private func isCurrent(_ requestID: UUID) -> Bool {
        switch state.phase {
        case .recognizing(let activeID), .confirming(let activeID):
            return activeID == requestID
        case .idle:
            return false
        }
    }

    private func finishExtraction(requestID: UUID, events: [AICalendarEventDraft]) {
        guard state.markAwaitingConfirmation(requestID: requestID) else { return }
        workflowTask = nil
        extractionTask = nil
        ToastWindow.dismiss()

        guard !events.isEmpty else {
            _ = finish(requestID: requestID)
            ToastWindow.show(message: L10n.aiCalendarNoEvents)
            return
        }

        guard let calendarService = eventService else {
            _ = finish(requestID: requestID)
            ToastWindow.show(message: L10n.aiCalendarInvalidRequest)
            return
        }

        let controller = AICalendarConfirmationController(
            events: events,
            calendarService: calendarService,
            onCancel: { [weak self] in
                guard let self, self.isCurrent(requestID) else { return }
                _ = self.finish(requestID: requestID)
            },
            onSaved: { [weak self] result in
                guard let self, self.isCurrent(requestID) else { return }
                ToastWindow.show(
                    message: L10n.aiCalendarSaveResult(
                        successes: result.successCount,
                        failures: result.failureCount
                    ),
                    on: self.requestScreen
                )
                guard result.failures.isEmpty else { return }
                _ = self.finish(requestID: requestID)
            }
        )
        confirmationController = controller
        controller.showWindow(nil)
    }

    private func finishFailure(requestID: UUID, error: Error) {
        guard isCurrent(requestID) else { return }
        workflowTask = nil
        extractionTask = nil
        _ = state.finish(requestID: requestID)
        eventService = nil
        requestScreen = nil
        ToastWindow.dismiss()
        ToastWindow.show(message: AICalendarErrorMessages.message(for: error))
    }

    private func cancelled(requestID: UUID) {
        guard isCurrent(requestID) else { return }
        workflowTask = nil
        extractionTask = nil
        _ = state.finish(requestID: requestID)
        eventService = nil
        requestScreen = nil
        ToastWindow.dismiss()
    }
}
