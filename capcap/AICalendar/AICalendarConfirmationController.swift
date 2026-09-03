import AppKit

enum AICalendarConfirmationValidationError: Equatable {
    case missingTitle
    case missingStart
    case missingEnd
    case endNotAfterStart
    case missingCalendar
    case calendarNotWritable

    var localizedMessage: String {
        switch self {
        case .missingTitle:
            return L10n.aiCalendarMissingTitle
        case .missingStart:
            return L10n.aiCalendarMissingStart
        case .missingEnd:
            return L10n.aiCalendarMissingEnd
        case .endNotAfterStart:
            return L10n.aiCalendarInvalidRange
        case .missingCalendar:
            return L10n.aiCalendarMissingCalendar
        case .calendarNotWritable:
            return L10n.aiCalendarCalendarNotWritable
        }
    }
}

struct AICalendarConfirmationSizing: Equatable {
    let contentHeight: CGFloat
    let scrollHeight: CGFloat
    let isScrollable: Bool

    static func calculate(
        cardsHeight: CGFloat,
        headerHeight: CGFloat,
        footerHeight: CGFloat,
        layoutSpacing: CGFloat,
        verticalInsets: CGFloat,
        maximumContentHeight: CGFloat
    ) -> AICalendarConfirmationSizing {
        let fixedHeight = max(0, headerHeight)
            + max(0, footerHeight)
            + max(0, layoutSpacing) * 2
            + max(0, verticalInsets)
        let measuredCardsHeight = max(0, cardsHeight)
        let contentHeight = min(fixedHeight + measuredCardsHeight, max(0, maximumContentHeight))
        let scrollHeight = max(0, contentHeight - fixedHeight)
        return AICalendarConfirmationSizing(
            contentHeight: contentHeight,
            scrollHeight: scrollHeight,
            isScrollable: measuredCardsHeight > scrollHeight + 0.5
        )
    }
}

/// Value state for one confirmation card. Keeping this separate from AppKit
/// controls makes the save button rules deterministic and unit-testable.
struct AICalendarConfirmationEventModel: Equatable {
    var draft: AICalendarEventDraft
    var included: Bool
    var calendar: CalendarDescriptor?

    init(
        draft: AICalendarEventDraft,
        included: Bool = true,
        calendar: CalendarDescriptor? = nil
    ) {
        self.draft = draft
        self.included = included
        self.calendar = calendar
    }

    var validationErrors: [AICalendarConfirmationValidationError] {
        guard included else { return [] }

        var errors: [AICalendarConfirmationValidationError] = []
        if draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            errors.append(.missingTitle)
        }
        guard let start = draft.start else {
            errors.append(.missingStart)
            if draft.end == nil { errors.append(.missingEnd) }
            appendCalendarError(to: &errors)
            return errors
        }
        guard let end = draft.end else {
            errors.append(.missingEnd)
            appendCalendarError(to: &errors)
            return errors
        }
        if end <= start {
            errors.append(.endNotAfterStart)
        }
        appendCalendarError(to: &errors)
        return errors
    }

    var isValid: Bool { validationErrors.isEmpty }

    var submission: CalendarEventSubmission? {
        guard isValid, let calendar else { return nil }
        return CalendarEventSubmission(event: draft, calendar: calendar)
    }

    private func appendCalendarError(to errors: inout [AICalendarConfirmationValidationError]) {
        if draft.calendarType == .unknown || calendar == nil {
            errors.append(.missingCalendar)
        } else if calendar?.allowsContentModifications == false {
            errors.append(.calendarNotWritable)
        }
    }
}

typealias AICalendarConfirmationEvent = AICalendarConfirmationEventModel

private final class AICalendarConfirmationDocumentView: NSView {
    override var isFlipped: Bool { true }
}

/// AppKit-only confirmation window for AI Calendar suggestions. The window
/// never writes an event until the user presses Add to Calendar.
final class AICalendarConfirmationController: NSWindowController, NSWindowDelegate, NSTextFieldDelegate {
    private final class EventControls {
        let include: NSButton
        let type: NSPopUpButton
        let title: NSTextField
        let start: NSTextField
        let end: NSTextField
        let location: NSTextField
        let url: NSTextField
        let notes: NSTextField
        let calendar: NSPopUpButton
        let attendees: NSTextField
        let warning: NSTextField

        init(
            include: NSButton,
            type: NSPopUpButton,
            title: NSTextField,
            start: NSTextField,
            end: NSTextField,
            location: NSTextField,
            url: NSTextField,
            notes: NSTextField,
            calendar: NSPopUpButton,
            attendees: NSTextField,
            warning: NSTextField
        ) {
            self.include = include
            self.type = type
            self.title = title
            self.start = start
            self.end = end
            self.location = location
            self.url = url
            self.notes = notes
            self.calendar = calendar
            self.attendees = attendees
            self.warning = warning
        }
    }

    private var models: [AICalendarConfirmationEventModel]
    private let calendarService: CalendarEventService
    private var controls: [EventControls] = []
    private var addButton: NSButton?
    private var resultLabel: NSTextField?
    private var failureLabel: NSTextField?
    private var closeWasNotified = false
    private var isSaving = false
    private var savedEventIndices = Set<Int>()
    private var onCancel: (() -> Void)?
    private var onSaved: ((CalendarEventSaveResult) -> Void)?
    private var headerStack: NSStackView?
    private var cardsStack: NSStackView?
    private var footerStack: NSStackView?
    private var layoutStack: NSStackView?
    private var eventScrollView: NSScrollView?
    private var scrollHeightConstraint: NSLayoutConstraint?
    private var documentHeightConstraint: NSLayoutConstraint?
    private var isUpdatingWindowSize = false

    private static let panelWidth: CGFloat = 560

    init(
        events: [AICalendarEventDraft],
        calendarService: CalendarEventService,
        onCancel: (() -> Void)? = nil,
        onSaved: ((CalendarEventSaveResult) -> Void)? = nil
    ) {
        self.models = events.map { AICalendarConfirmationEventModel(draft: $0) }
        self.calendarService = calendarService
        self.onCancel = onCancel
        self.onSaved = onSaved

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.panelWidth, height: 360),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: true
        )
        panel.title = L10n.aiCalendarConfirmTitle
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.contentMinSize = NSSize(width: 520, height: 280)
        super.init(window: panel)
        panel.delegate = self
        buildContent()
    }

    convenience init(
        events: [AICalendarEventDraft],
        onCancel: (() -> Void)? = nil,
        onSaved: ((CalendarEventSaveResult) -> Void)? = nil
    ) {
        self.init(
            events: events,
            calendarService: CalendarEventService(),
            onCancel: onCancel,
            onSaved: onSaved
        )
    }

    required init?(coder: NSCoder) {
        return nil
    }

    override func showWindow(_ sender: Any?) {
        refreshAllControls()
        resizeWindowToFitContent()
        super.showWindow(sender)
        window?.center()
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        guard !closeWasNotified else { return }
        closeWasNotified = true
        let callback = onCancel
        onCancel = nil
        onSaved = nil
        callback?()
    }

    @objc private func cancelButtonPressed(_ sender: Any?) {
        closeWindowAndNotify()
    }

    @objc private func addButtonPressed(_ sender: Any?) {
        guard !isSaving else { return }
        syncModelsFromControls()
        updateValidationState()
        let includedIndices = models.indices.filter { models[$0].included && models[$0].submission != nil }
        let submissions = includedIndices.compactMap { models[$0].submission }
        guard !submissions.isEmpty else { return }

        isSaving = true
        addButton?.isEnabled = false
        let result = calendarService.save(events: submissions)
        resultLabel?.stringValue = L10n.aiCalendarSaveResult(
            successes: result.successCount,
            failures: result.failureCount
        )
        resultLabel?.isHidden = false

        // EventKit saves each submission independently. Remove successful rows
        // from the pending set so a retry cannot create duplicate events when a
        // later row failed.
        for success in result.successes {
            guard includedIndices.indices.contains(success.index) else { continue }
            let modelIndex = includedIndices[success.index]
            savedEventIndices.insert(modelIndex)
            models[modelIndex].included = false
            controls[modelIndex].include.state = .off
            controls[modelIndex].include.isEnabled = false
        }

        if result.failures.isEmpty {
            failureLabel?.stringValue = ""
            failureLabel?.isHidden = true
            isSaving = false
            let callback = onSaved
            onSaved = nil
            onCancel = nil
            closeWasNotified = true
            callback?(result)
            window?.close()
        } else {
            let details = result.failures.map {
                "\($0.eventTitle): \($0.reason.userMessage)"
            }.joined(separator: "\n")
            failureLabel?.stringValue = details
            failureLabel?.isHidden = false
            isSaving = false
            updateValidationState()
        }
    }

    @objc private func typeChanged(_ sender: NSPopUpButton) {
        let index = sender.tag
        guard models.indices.contains(index) else { return }
        syncModel(at: index)
        models[index].draft.calendarType = typeForPopup(sender)
        models[index].calendar = nil
        refreshCalendarPopup(at: index)
        updateValidationState()
    }

    @objc private func calendarChanged(_ sender: NSPopUpButton) {
        let index = sender.tag
        guard models.indices.contains(index) else {
            updateValidationState()
            return
        }
        let calendars = calendarsForModel(at: index)
        let identifier = sender.selectedItem?.representedObject as? String
        models[index].calendar = identifier.flatMap { value in
            calendars.first { $0.identifier == value }
        }
        if let calendar = models[index].calendar,
           models[index].draft.calendarType != .unknown {
            _ = calendarService.remember(calendar, for: models[index].draft.calendarType)
        }
        updateValidationState()
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else {
            updateValidationState()
            return
        }
        if let index = controls.firstIndex(where: {
            $0.title === field || $0.start === field || $0.end === field ||
            $0.location === field || $0.url === field || $0.notes === field ||
            $0.attendees === field
        }) {
            syncModel(at: index)
        }
        updateValidationState()
    }

    private func closeWindowAndNotify() {
        guard !closeWasNotified else {
            window?.close()
            return
        }
        closeWasNotified = true
        let callback = onCancel
        onCancel = nil
        onSaved = nil
        callback?()
        window?.close()
    }

    private func buildContent() {
        guard let contentView = window?.contentView else { return }

        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            root.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            root.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 20),
            root.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -20),
        ])

        let header = NSStackView()
        header.orientation = .vertical
        header.alignment = .leading
        header.spacing = 5
        let count = NSTextField(labelWithString: L10n.aiCalendarRecognizedCount(models.count))
        count.font = .systemFont(ofSize: 13, weight: .regular)
        header.addArrangedSubview(count)
        headerStack = header

        let cards = NSStackView()
        cards.orientation = .vertical
        cards.alignment = .leading
        cards.spacing = 12
        cards.edgeInsets = NSEdgeInsets(top: 4, left: 0, bottom: 4, right: 0)
        cards.translatesAutoresizingMaskIntoConstraints = false
        for index in models.indices {
            let card = makeEventCard(at: index)
            cards.addArrangedSubview(card)
            card.widthAnchor.constraint(equalTo: cards.widthAnchor).isActive = true
        }
        if models.isEmpty {
            let empty = NSTextField(wrappingLabelWithString: L10n.aiCalendarNoEvents)
            empty.textColor = .secondaryLabelColor
            cards.addArrangedSubview(empty)
        }
        cardsStack = cards

        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let document = AICalendarConfirmationDocumentView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(cards)
        let documentHeight = document.heightAnchor.constraint(equalToConstant: 1)
        NSLayoutConstraint.activate([
            cards.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            cards.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            cards.topAnchor.constraint(equalTo: document.topAnchor),
            documentHeight,
        ])
        scroll.documentView = document
        eventScrollView = scroll
        documentHeightConstraint = documentHeight

        let footer = NSStackView()
        footer.orientation = .vertical
        footer.alignment = .leading
        footer.spacing = 6
        let result = NSTextField(labelWithString: "")
        result.textColor = .secondaryLabelColor
        result.isHidden = true
        resultLabel = result
        footer.addArrangedSubview(result)
        let failures = NSTextField(wrappingLabelWithString: "")
        failures.textColor = .systemOrange
        failures.isHidden = true
        failureLabel = failures
        footer.addArrangedSubview(failures)

        let buttons = NSStackView()
        buttons.orientation = .horizontal
        buttons.spacing = 8
        buttons.alignment = .centerY
        let cancel = NSButton(title: L10n.aiCalendarCancel, target: self, action: #selector(cancelButtonPressed(_:)))
        cancel.bezelStyle = .rounded
        buttons.addArrangedSubview(cancel)
        let add = NSButton(title: L10n.aiCalendarAdd, target: self, action: #selector(addButtonPressed(_:)))
        add.bezelStyle = .rounded
        add.keyEquivalent = "\r"
        addButton = add
        buttons.addArrangedSubview(add)
        footer.addArrangedSubview(buttons)
        footerStack = footer

        let layout = NSStackView(views: [header, scroll, footer])
        layout.orientation = .vertical
        layout.alignment = .leading
        layout.spacing = 12
        layout.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(layout)
        let scrollHeight = scroll.heightAnchor.constraint(equalToConstant: 1)
        NSLayoutConstraint.activate([
            layout.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            layout.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            layout.topAnchor.constraint(equalTo: root.topAnchor),
            layout.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            scroll.widthAnchor.constraint(equalTo: layout.widthAnchor),
            scrollHeight,
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])
        layoutStack = layout
        scrollHeightConstraint = scrollHeight
        refreshAllControls()
    }

    private func resizeWindowToFitContent() {
        guard !isUpdatingWindowSize,
              let window,
              let contentView = window.contentView,
              let headerStack,
              let cardsStack,
              let footerStack,
              let layoutStack,
              let eventScrollView,
              let scrollHeightConstraint,
              let documentHeightConstraint else { return }

        isUpdatingWindowSize = true
        defer { isUpdatingWindowSize = false }

        let visibleHeight = (window.screen ?? NSScreen.main)?.visibleFrame.height ?? 800
        let maximumContentHeight = max(300, min(720, visibleHeight - 100))

        func measure() -> (cardsHeight: CGFloat, sizing: AICalendarConfirmationSizing) {
            contentView.layoutSubtreeIfNeeded()
            let cardsHeight = ceil(max(1, cardsStack.fittingSize.height))
            let sizing = AICalendarConfirmationSizing.calculate(
                cardsHeight: cardsHeight,
                headerHeight: ceil(max(1, headerStack.fittingSize.height)),
                footerHeight: ceil(max(1, footerStack.fittingSize.height)),
                layoutSpacing: layoutStack.spacing,
                verticalInsets: 40,
                maximumContentHeight: maximumContentHeight
            )
            return (cardsHeight, sizing)
        }

        // Measure once at the widest viewport. If a scroller is needed, add
        // it and measure again because its gutter can change text wrapping.
        eventScrollView.hasVerticalScroller = false
        var measurement = measure()
        if measurement.sizing.isScrollable {
            eventScrollView.hasVerticalScroller = true
            measurement = measure()
        }

        documentHeightConstraint.constant = measurement.cardsHeight
        scrollHeightConstraint.constant = max(1, measurement.sizing.scrollHeight)
        let currentContentWidth = contentView.bounds.width > 0
            ? contentView.bounds.width
            : Self.panelWidth
        window.setContentSize(
            NSSize(
                width: max(window.contentMinSize.width, currentContentWidth),
                height: ceil(max(1, measurement.sizing.contentHeight))
            )
        )
        contentView.layoutSubtreeIfNeeded()
    }

    private func makeEventCard(at index: Int) -> NSView {
        let model = models[index]
        let include = NSButton(checkboxWithTitle: L10n.aiCalendarEventNumber(index + 1), target: self, action: #selector(includeChanged(_:)))
        include.tag = index
        include.state = model.included ? .on : .off

        let type = NSPopUpButton()
        type.tag = index
        type.addItem(withTitle: L10n.aiCalendarWork)
        type.lastItem?.representedObject = AICalendarType.work.rawValue
        type.lastItem?.tag = typeTag(.work)
        type.addItem(withTitle: L10n.aiCalendarPersonal)
        type.lastItem?.representedObject = AICalendarType.personal.rawValue
        type.lastItem?.tag = typeTag(.personal)
        type.addItem(withTitle: L10n.aiCalendarUnknown)
        type.lastItem?.representedObject = AICalendarType.unknown.rawValue
        type.lastItem?.tag = typeTag(.unknown)
        type.target = self
        type.action = #selector(typeChanged(_:))

        let title = editableField(placeholder: L10n.aiCalendarTitle)
        let start = editableField(placeholder: L10n.aiCalendarDateTimePlaceholder)
        let end = editableField(placeholder: L10n.aiCalendarDateTimePlaceholder)
        let location = editableField(placeholder: L10n.aiCalendarLocation)
        let url = editableField(placeholder: L10n.aiCalendarURL)
        let notes = editableField(placeholder: L10n.aiCalendarNotes)
        [title, start, end, location, url, notes].forEach { $0.delegate = self }

        let calendar = NSPopUpButton()
        calendar.tag = index
        calendar.target = self
        calendar.action = #selector(calendarChanged(_:))

        let attendees = editableField(placeholder: L10n.aiCalendarAttendees)
        attendees.stringValue = model.draft.attendees.map(\.displayName).joined(separator: ", ")
        attendees.delegate = self

        let warning = NSTextField(wrappingLabelWithString: "")
        warning.textColor = .systemOrange
        warning.isHidden = true

        let header = NSStackView(views: [include, type])
        header.orientation = .horizontal
        header.spacing = 10
        let form = NSStackView()
        form.orientation = .vertical
        form.alignment = .leading
        form.spacing = 6
        form.addArrangedSubview(header)
        form.addArrangedSubview(row(label: L10n.aiCalendarTitle, view: title))
        form.addArrangedSubview(row(label: L10n.aiCalendarStart, view: start))
        form.addArrangedSubview(row(label: L10n.aiCalendarEnd, view: end))
        form.addArrangedSubview(row(label: L10n.aiCalendarChooseCalendar, view: calendar))
        form.addArrangedSubview(row(label: L10n.aiCalendarLocation, view: location))
        form.addArrangedSubview(row(label: L10n.aiCalendarURL, view: url))
        form.addArrangedSubview(row(label: L10n.aiCalendarNotes, view: notes))
        form.addArrangedSubview(row(label: L10n.aiCalendarAttendees, view: attendees))
        form.addArrangedSubview(warning)

        let card = NSBox()
        card.boxType = .custom
        card.cornerRadius = 10
        card.borderWidth = 1
        card.borderColor = .separatorColor
        card.fillColor = .controlBackgroundColor
        card.contentViewMargins = NSSize(width: 12, height: 10)
        card.contentView = form

        controls.append(
            EventControls(
                include: include,
                type: type,
                title: title,
                start: start,
                end: end,
                location: location,
                url: url,
                notes: notes,
                calendar: calendar,
                attendees: attendees,
                warning: warning
            )
        )
        return card
    }

    @objc private func includeChanged(_ sender: NSButton) {
        let index = sender.tag
        guard models.indices.contains(index), !savedEventIndices.contains(index) else { return }
        syncModel(at: index)
        models[index].included = sender.state == .on
        updateValidationState()
    }

    private func editableField(placeholder: String) -> NSTextField {
        let field = NSTextField()
        field.placeholderString = placeholder
        field.translatesAutoresizingMaskIntoConstraints = false
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.widthAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true
        return field
    }

    private func row(label: String, view: NSView) -> NSStackView {
        let labelView = NSTextField(labelWithString: label)
        labelView.alignment = .right
        labelView.widthAnchor.constraint(equalToConstant: 86).isActive = true
        let row = NSStackView(views: [labelView, view])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        return row
    }

    private func refreshAllControls() {
        for index in models.indices {
            syncControls(at: index)
            refreshCalendarPopup(at: index)
        }
        updateValidationState()
    }

    private func syncControls(at index: Int) {
        guard models.indices.contains(index), controls.indices.contains(index) else { return }
        let model = models[index]
        let control = controls[index]
        control.include.state = model.included ? .on : .off
        control.include.isEnabled = !savedEventIndices.contains(index)
        control.type.selectItem(withTag: typeTag(model.draft.calendarType))
        control.title.stringValue = model.draft.title
        control.start.stringValue = formattedDate(model.draft.start)
        control.end.stringValue = formattedDate(model.draft.end)
        control.location.stringValue = model.draft.location
        control.url.stringValue = model.draft.url?.absoluteString ?? ""
        control.notes.stringValue = model.draft.notes
        let attendees = model.draft.attendees.map(\.displayName).joined(separator: ", ")
        control.attendees.stringValue = attendees
    }

    private func syncModelsFromControls() {
        for index in models.indices { syncModel(at: index) }
    }

    private func syncModel(at index: Int) {
        guard models.indices.contains(index), controls.indices.contains(index) else { return }
        let control = controls[index]
        var draft = models[index].draft
        draft.title = control.title.stringValue
        draft.start = parseDate(control.start.stringValue)
        draft.end = parseDate(control.end.stringValue)
        if draft.start != nil {
            draft.uncertainFields.removeAll { ["date", "time", "start"].contains($0.lowercased()) }
        }
        if draft.end != nil {
            draft.uncertainFields.removeAll { ["end", "duration"].contains($0.lowercased()) }
        }
        draft.location = control.location.stringValue
        let urlValue = control.url.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if urlValue.isEmpty {
            draft.url = nil
            draft.uncertainFields.removeAll { $0 == "url" }
        } else if let parsed = parseURL(urlValue) {
            draft.url = parsed
            draft.uncertainFields.removeAll { $0 == "url" }
        } else {
            draft.url = nil
            if !draft.uncertainFields.contains("url") { draft.uncertainFields.append("url") }
            draft.requiresConfirmation = true
        }
        draft.notes = control.notes.stringValue
        draft.attendees = parseAttendees(control.attendees.stringValue)
        draft.calendarType = typeForPopup(control.type)
        models[index].draft = draft
    }

    private func updateValidationState() {
        for index in models.indices where controls.indices.contains(index) {
            let errors = models[index].validationErrors
            let draft = models[index].draft
            let uncertain = draft.requiresConfirmation || !draft.uncertainFields.isEmpty
            let timeIsUncertain = draft.start == nil || draft.end == nil || draft.uncertainFields.contains {
                ["date", "time", "start", "end", "duration"].contains($0.lowercased())
            }
            let reviewMessage: String? = uncertain
                ? (timeIsUncertain ? L10n.aiCalendarRequiresConfirmation : L10n.aiCalendarReviewSuggestion)
                : nil
            let warningText = ([reviewMessage] + errors.map(\.localizedMessage))
                .compactMap { $0 }
                .joined(separator: "\n")
            controls[index].warning.stringValue = warningText
            controls[index].warning.isHidden = warningText.isEmpty
        }
        let selected = models.filter(\.included)
        addButton?.isEnabled = !isSaving && !selected.isEmpty && selected.allSatisfy(\.isValid)
        resizeWindowToFitContent()
    }

    private func refreshCalendarPopup(at index: Int) {
        guard models.indices.contains(index), controls.indices.contains(index) else { return }
        let popup = controls[index].calendar
        let selectedIdentifier = models[index].calendar?.identifier
        let calendars = calendarsForModel(at: index)
        popup.removeAllItems()
        if calendars.isEmpty {
            popup.addItem(withTitle: L10n.aiCalendarNoWritableCalendar)
            popup.item(at: 0)?.isEnabled = false
            models[index].calendar = nil
            return
        }
        let needsChoice = models[index].draft.calendarType == .unknown || calendars.count > 1
        if needsChoice {
            popup.addItem(withTitle: L10n.aiCalendarChooseCalendarPlaceholder)
            popup.item(at: 0)?.representedObject = nil
            popup.item(at: 0)?.isEnabled = false
        }
        for calendar in calendars {
            popup.addItem(withTitle: calendar.pickerTitle(disambiguatingAmong: calendars))
            popup.lastItem?.representedObject = calendar.identifier
        }
        if let selectedIdentifier,
           let selectedIndex = calendars.firstIndex(where: { $0.identifier == selectedIdentifier }) {
            popup.selectItem(at: selectedIndex + (needsChoice ? 1 : 0))
        } else if models[index].draft.calendarType != .unknown, calendars.count == 1 {
            models[index].calendar = calendars[0]
            popup.selectItem(at: needsChoice ? 1 : 0)
        } else {
            models[index].calendar = nil
            popup.selectItem(at: 0)
        }
    }

    private func calendarsForModel(at index: Int) -> [CalendarDescriptor] {
        guard models.indices.contains(index) else { return [] }
        let type = models[index].draft.calendarType
        if type != .unknown {
            do {
                switch try calendarService.resolveCalendar(for: type) {
                case .selected(let calendar):
                    return [calendar]
                case .requiresSelection(_, let calendars):
                    return calendars
                }
            } catch {
                return []
            }
        }

        // Unknown events still get a real writable-calendar menu. Resolve both
        // logical categories and merge their candidates without guessing a
        // category for the event.
        var result: [CalendarDescriptor] = []
        for candidateType in [AICalendarType.work, .personal] {
            do {
                switch try calendarService.resolveCalendar(for: candidateType) {
                case .selected(let calendar):
                    if !result.contains(calendar) { result.append(calendar) }
                case .requiresSelection(_, let calendars):
                    for calendar in calendars where !result.contains(calendar) {
                        result.append(calendar)
                    }
                }
            } catch {
                continue
            }
        }
        return result
    }

    private func typeForPopup(_ popup: NSPopUpButton) -> AICalendarType {
        guard let raw = popup.selectedItem?.representedObject as? String else { return .unknown }
        return AICalendarType(rawValue: raw) ?? .unknown
    }

    private func parseAttendees(_ value: String) -> [AICalendarAttendee] {
        value
            .components(separatedBy: CharacterSet(charactersIn: ",;\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { token in
                if let opening = token.lastIndex(of: "<"),
                   let closing = token.lastIndex(of: ">"),
                   opening < closing {
                    let name = token[..<opening].trimmingCharacters(in: .whitespacesAndNewlines)
                    let emailStart = token.index(after: opening)
                    let email = token[emailStart..<closing].trimmingCharacters(in: .whitespacesAndNewlines)
                    if !email.isEmpty {
                        return AICalendarAttendee(name: String(name), email: String(email))
                    }
                }

                if let at = token.firstIndex(of: "@") {
                    let emailStart = token[..<at].lastIndex {
                        $0 == " " || $0 == "\t"
                    }.map { token.index(after: $0) }
                    if let emailStart {
                        return AICalendarAttendee(
                            name: String(token[..<emailStart]).trimmingCharacters(in: .whitespacesAndNewlines),
                            email: String(token[emailStart...]).trimmingCharacters(in: .whitespacesAndNewlines)
                        )
                    }
                    return AICalendarAttendee(email: token)
                }
                return AICalendarAttendee(name: token)
            }
            .filter { !$0.name.isEmpty || !$0.email.isEmpty }
    }

    private func typeTag(_ type: AICalendarType) -> Int {
        switch type {
        case .work: return 0
        case .personal: return 1
        case .unknown: return 2
        }
    }

    private func formattedDate(_ date: Date?) -> String {
        guard let date else { return "" }
        return Self.dateFormatter.string(from: date)
    }

    private func parseDate(_ value: String) -> Date? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: trimmed) { return date }
        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        if let date = standard.date(from: trimmed) { return date }
        return Self.dateFormatter.date(from: trimmed)
    }

    private func parseURL(_ value: String) -> URL? {
        guard let url = URL(string: value),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              url.host != nil else {
            return nil
        }
        return url
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()
}
