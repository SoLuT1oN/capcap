import AppKit
import Foundation

/// Content of the Settings "AI Calendar" tab.
///
/// This pane owns only the three values needed by the calendar provider. The
/// calendar identifiers belong to the domain layer, so saving reloads and
/// preserves those values instead of allowing this UI to overwrite them.
final class AICalendarSettingsPane: NSView {
    private static let connectionTestMessage = "hello"

    private let endpointLabel = NSTextField(labelWithString: "")
    private let apiKeyLabel = NSTextField(labelWithString: "")
    private let modelLabel = NSTextField(labelWithString: "")
    private let settingsTitleLabel = NSTextField(labelWithString: "")
    private let settingsSubtitleLabel = NSTextField(wrappingLabelWithString: "")
    private let endpointField = PasteableTextField()
    private let apiKeyField = RevealableSecureField()
    private let modelField = PasteableTextField()
    private let saveButton = NSButton()
    private let testButton = NSButton()
    private let statusLabel = NSTextField(wrappingLabelWithString: "")

    private var connectionTask: Task<Void, Never>?
    private var connectionAttemptID: UUID?

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        buildUI()
        loadFromStore()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onLanguageChanged),
            name: .languageDidChange,
            object: nil
        )
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        connectionTask?.cancel()
        NotificationCenter.default.removeObserver(self)
    }

    /// Builds the smallest request needed to check an OpenAI-compatible Chat
    /// Completions endpoint. It deliberately does not use an image or the
    /// calendar service's multimodal extraction request.
    static func makeConnectionRequest(for config: AICalendarConfig) throws -> URLRequest {
        let normalized = config.normalized()
        let body: [String: Any] = [
            "model": normalized.model,
            "messages": [[
                "role": "user",
                "content": connectionTestMessage,
            ]],
            "stream": false,
        ]
        return try OpenAICompatibleChatTransport.makeRequest(
            endpoint: normalized.endpoint,
            apiKey: normalized.apiKey,
            body: body
        )
    }

    static func makeConfig(
        endpoint: String,
        apiKey: String,
        model: String,
        preservingCalendarIdentifiersFrom storedConfig: AICalendarConfig
    ) -> AICalendarConfig {
        AICalendarConfig(
            endpoint: endpoint,
            apiKey: apiKey,
            model: model,
            workCalendarIdentifier: storedConfig.workCalendarIdentifier,
            personalCalendarIdentifier: storedConfig.personalCalendarIdentifier
        ).normalized()
    }

    private func buildUI() {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        let header = NSStackView()
        header.orientation = .vertical
        header.alignment = .leading
        header.spacing = 4
        header.translatesAutoresizingMaskIntoConstraints = false

        settingsTitleLabel.stringValue = L10n.aiCalendarSettingsTitle
        settingsTitleLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        settingsTitleLabel.textColor = NSColor.white.withAlphaComponent(0.94)

        settingsSubtitleLabel.stringValue = L10n.aiCalendarSettingsSubtitle
        settingsSubtitleLabel.font = NSFont.systemFont(ofSize: 11)
        settingsSubtitleLabel.textColor = NSColor.white.withAlphaComponent(0.58)
        settingsSubtitleLabel.maximumNumberOfLines = 0
        settingsSubtitleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        header.addArrangedSubview(settingsTitleLabel)
        header.addArrangedSubview(settingsSubtitleLabel)
        stack.addArrangedSubview(header)
        header.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        let card = NSView()
        card.translatesAutoresizingMaskIntoConstraints = false
        card.wantsLayer = true
        card.layer?.cornerRadius = 12
        card.layer?.cornerCurve = .continuous
        card.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.04).cgColor
        card.layer?.borderColor = NSColor.white.withAlphaComponent(0.06).cgColor
        card.layer?.borderWidth = 1

        let fields = NSStackView()
        fields.orientation = .vertical
        fields.alignment = .leading
        fields.spacing = 10
        fields.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(fields)

        configureField(endpointField, placeholder: AICalendarConfig.defaultEndpoint)
        configureField(apiKeyField, placeholder: L10n.aiCalendarApiKeyPlaceholder)
        configureField(modelField, placeholder: AICalendarConfig.defaultModel)

        fields.addArrangedSubview(makeFieldRow(label: endpointLabel, field: endpointField, title: L10n.aiCalendarEndpoint))
        fields.addArrangedSubview(makeFieldRow(label: apiKeyLabel, field: apiKeyField, title: L10n.aiCalendarApiKey))
        fields.addArrangedSubview(makeFieldRow(label: modelLabel, field: modelField, title: L10n.aiCalendarModel))

        saveButton.bezelStyle = .rounded
        saveButton.controlSize = .small
        saveButton.target = self
        saveButton.action = #selector(saveTapped)

        testButton.bezelStyle = .rounded
        testButton.controlSize = .small
        testButton.target = self
        testButton.action = #selector(testTapped)

        let footer = NSStackView(views: [flexSpacer(), saveButton, testButton])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 8
        footer.translatesAutoresizingMaskIntoConstraints = false
        fields.addArrangedSubview(footer)
        footer.widthAnchor.constraint(equalTo: fields.widthAnchor).isActive = true

        statusLabel.font = NSFont.systemFont(ofSize: 11)
        statusLabel.textColor = NSColor.white.withAlphaComponent(0.58)
        statusLabel.maximumNumberOfLines = 0
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        fields.addArrangedSubview(statusLabel)
        statusLabel.widthAnchor.constraint(equalTo: fields.widthAnchor).isActive = true

        NSLayoutConstraint.activate([
            fields.topAnchor.constraint(equalTo: card.topAnchor, constant: 14),
            fields.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            fields.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
            fields.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -14),
        ])

        stack.addArrangedSubview(card)
        card.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 22),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -22),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -22),
        ])

        refreshLocalization()
    }

    private func configureField(_ field: any ProviderFieldInput, placeholder: String) {
        field.translatesAutoresizingMaskIntoConstraints = false
        field.font = NSFont.systemFont(ofSize: 12)
        field.placeholderString = placeholder
        field.widthAnchor.constraint(greaterThanOrEqualToConstant: 260).isActive = true
        field.heightAnchor.constraint(equalToConstant: 24).isActive = true
    }

    private func makeFieldRow(label: NSTextField, field: NSView, title: String) -> NSView {
        label.stringValue = title
        label.font = NSFont.systemFont(ofSize: 11)
        label.textColor = NSColor.white.withAlphaComponent(0.74)
        label.alignment = .right
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(equalToConstant: 110).isActive = true

        let row = NSStackView(views: [label, field])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false
        return row
    }

    private func flexSpacer() -> NSView {
        let view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.setContentHuggingPriority(.init(1), for: .horizontal)
        view.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        return view
    }

    private func loadFromStore() {
        let config = AICalendarConfigStore.load()
        endpointField.stringValue = config.endpoint
        apiKeyField.stringValue = config.apiKey
        modelField.stringValue = config.model
    }

    private func currentConfig() -> AICalendarConfig {
        let stored = AICalendarConfigStore.load()
        return Self.makeConfig(
            endpoint: endpointField.stringValue,
            apiKey: apiKeyField.stringValue,
            model: modelField.stringValue,
            preservingCalendarIdentifiersFrom: stored
        )
    }

    private func saveCurrentConfig() -> AICalendarConfig {
        let config = currentConfig()
        AICalendarConfigStore.save(config)
        NotificationCenter.default.post(name: .aiCalendarConfigDidChange, object: nil)
        return config
    }

    @objc private func saveTapped() {
        _ = saveCurrentConfig()
        statusLabel.textColor = NSColor.white.withAlphaComponent(0.58)
        statusLabel.stringValue = L10n.aiCalendarConfigSaved
    }

    @objc private func testTapped() {
        guard connectionTask == nil else { return }
        let config = saveCurrentConfig()
        let attemptID = UUID()
        connectionAttemptID = attemptID
        saveButton.isEnabled = false
        testButton.isEnabled = false
        statusLabel.textColor = NSColor.white.withAlphaComponent(0.58)
        statusLabel.stringValue = L10n.aiCalendarTesting

        connectionTask = Task { [weak self] in
            do {
                let request = try Self.makeConnectionRequest(for: config)
                let transport = OpenAICompatibleChatTransport()
                let (_, response) = try await transport.load(request)
                try Self.validateConnectionResponse(response)
                await MainActor.run {
                    self?.finishConnectionTest(attemptID: attemptID, error: nil)
                }
            } catch is CancellationError {
                return
            } catch {
                await MainActor.run {
                    self?.finishConnectionTest(attemptID: attemptID, error: error)
                }
            }
        }
    }

    func cancelConnectionTest() {
        connectionTask?.cancel()
        connectionTask = nil
        connectionAttemptID = nil
        saveButton.isEnabled = true
        testButton.isEnabled = true
        statusLabel.textColor = NSColor.white.withAlphaComponent(0.58)
        statusLabel.stringValue = ""
        refreshLocalization()
    }

    private static func validateConnectionResponse(_ response: URLResponse) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ConnectionTestError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw ConnectionTestError.httpStatus(httpResponse.statusCode)
        }
    }

    private func finishConnectionTest(attemptID: UUID, error: Error?) {
        guard connectionAttemptID == attemptID else { return }
        connectionAttemptID = nil
        connectionTask = nil
        saveButton.isEnabled = true
        testButton.isEnabled = true

        if let error {
            statusLabel.textColor = NSColor.systemOrange
            statusLabel.stringValue = failureMessage(for: error)
        } else {
            statusLabel.textColor = NSColor.systemGreen
            statusLabel.stringValue = L10n.aiCalendarTestPassed
        }
    }

    private func failureMessage(for error: Error) -> String {
        switch error {
        case OpenAICompatibleChatTransportError.missingAPIKey:
            return L10n.aiCalendarMissingAPIKey
        case OpenAICompatibleChatTransportError.invalidEndpoint:
            return L10n.aiCalendarInvalidEndpoint
        case OpenAICompatibleChatTransportError.invalidRequestBody:
            return L10n.aiCalendarInvalidRequest
        case ConnectionTestError.invalidResponse:
            return L10n.aiCalendarInvalidResponse
        case ConnectionTestError.httpStatus(401):
            return L10n.aiCalendarUnauthorized
        case ConnectionTestError.httpStatus(403):
            return L10n.aiCalendarForbidden
        case ConnectionTestError.httpStatus(429):
            return L10n.aiCalendarRateLimited
        case ConnectionTestError.httpStatus(500...599):
            return L10n.aiCalendarServiceUnavailable
        case is URLError:
            return AICalendarErrorMessages.message(for: error)
        default:
            return L10n.aiCalendarTestFailed
        }
    }

    @objc private func onLanguageChanged() {
        refreshLocalization()
    }

    func refreshLocalization() {
        settingsTitleLabel.stringValue = L10n.aiCalendarSettingsTitle
        settingsSubtitleLabel.stringValue = L10n.aiCalendarSettingsSubtitle
        endpointLabel.stringValue = L10n.aiCalendarEndpoint
        apiKeyLabel.stringValue = L10n.aiCalendarApiKey
        apiKeyField.placeholderString = L10n.aiCalendarApiKeyPlaceholder
        modelLabel.stringValue = L10n.aiCalendarModel
        saveButton.title = L10n.aiCalendarSave
        testButton.title = connectionTask == nil ? L10n.aiCalendarTestConnection : L10n.aiCalendarTesting
    }
}

private enum ConnectionTestError: Error {
    case invalidResponse
    case httpStatus(Int)
}
