# AI Calendar Design

## Goal and baseline

Add an AI Calendar workflow to capcap `release-v1.7.11` without changing existing screenshot, OCR, translation, upload, pin, recording, save, confirm, shortcut, or toolbar-customization behavior. The workflow sends the editor's final composited screenshot to a user-configured OpenAI-compatible Chat Completions endpoint, validates structured event suggestions, requires native AppKit confirmation, and writes selected events to Apple Calendar with EventKit full access.

The implementation stays inside the existing Swift Package Manager executable, uses pure AppKit, targets macOS 14+, and adds no third-party dependencies.

## Architecture decision

Use a shared low-level OpenAI-compatible transport plus a separate `AICalendar` domain module.

- The shared transport owns safe request construction, Bearer authorization, timeout handling, injected `URLSession` execution, HTTP status validation, and sanitized errors
- `TranslationService` continues to own translation prompts, providers, streaming, and SSE parsing, but delegates the common request setup to the transport through a compatibility wrapper
- `AICalendarService` owns multimodal request construction, non-streaming Chat Completions response parsing, image encoding, and calendar-specific errors
- Calendar DTOs, validation, EventKit access, and AppKit confirmation UI remain independent of translation

This avoids forcing calendar extraction into `TranslationService` while also avoiding a duplicate network stack.

## Source layout

Create a focused `capcap/AICalendar/` module:

- `AICalendarModels.swift`: wire DTOs, editable drafts, validation, date parsing, default one-hour end time, calendar type, attendee formatting, and batch-save result models
- `AICalendarConfig.swift`: endpoint, API key, model, work/personal calendar identifiers, normalized UserDefaults persistence, and injectable defaults for tests
- `AICalendarPrompt.swift`: strict extraction prompt with dynamic local date/time and timezone context
- `AICalendarImageEncoder.swift`: aspect-preserving JPEG encoding at quality `0.88`, longest edge capped at `2560` pixels, and no logging of image bytes
- `AICalendarService.swift`: Chat Completions request/response flow and tolerant fenced-JSON extraction
- `CalendarEventService.swift`: EventKit authorization, writable calendar enumeration/mapping, and per-event save through a testable protocol
- `AICalendarConfirmationController.swift`: native AppKit event list, editable form, validation state, calendar resolution, and batch result feedback
- `OpenAICompatibleChatTransport.swift`: small shared transport used by AI Calendar and the existing OpenAI-compatible translation request builder

Modify existing files only at their natural integration points: toolbar model/dispatch, settings tab wiring, localized accessors/resources, package framework linkage, Info.plist, documentation, and tests.

## Toolbar and editor integration

Add `ToolbarItemID.aiCalendar` without renaming or changing any existing raw value. It is a `.momentary` item with SF Symbol `calendar.badge.plus` and localized title `Add to Calendar` / `添加到日历`.

Add it to `canonicalOrder` immediately before `scrollCapture`. The default side toolbar becomes:

```swift
[.aiCalendar, .scrollCapture, .upload, .save, .pin, .record, .close, .confirm]
```

This placement makes the existing `normalized()` migration insert the missing item immediately before `scrollCapture` for old persisted layouts when a preceding canonical neighbour is not sufficient. Because the current generic algorithm inserts after the nearest previous item, the implementation will add a narrow migration rule for `aiCalendar`: when absent, insert it before `scrollCapture` in the same bucket; if `scrollCapture` is also absent, fall back to canonical-neighbour placement. Existing item ordering and buckets remain untouched.

`EditWindowController.performToolbarItem` dispatches `.aiCalendar` to `performAICalendar()`. The method commits active text editing and calls the existing `currentCompositeImage()`, which is already shared by save, upload, pin, and confirm. It never calls OCR and never captures the screen again when a final editor image is available.

The controller stores one `Task<Void, Never>?` and a monotonically increasing request generation. While a request is active, every visible AI Calendar button is disabled and visually dimmed; a project-style toast shows analysis progress. Repeated clicks are ignored. `tearDown()` cancels the task, increments the generation, and prevents late results from opening a confirmation window after the editor closes. All AppKit state changes execute on the main actor; image encoding and networking execute asynchronously.

The editor stays open during analysis. On success, the confirmation window is presented above it. Cancelling confirmation returns to the editor. Successful calendar saves do not implicitly copy, upload, save, or close the screenshot.

## Configuration and settings UI

Add a dedicated `AI Calendar` settings tab immediately after Translation. It follows the existing dark AppKit sidebar, cards, spacing, labels, secure API-key field, rounded buttons, and localization refresh behavior. No SwiftUI is introduced.

Configuration fields:

- Endpoint, default `http://aigw-api.cmsrservice.com/v1/chat/completions`
- API Key, default empty
- Model ID, default `GLM-5.3-Flash`
- Work calendar identifier, default empty
- Personal calendar identifier, default empty

The API Key remains in UserDefaults because the requirement explicitly permits the existing persistence pattern. It is trimmed on save, shown in an `NSSecureTextField`, never committed as a value, and never logged or included in an error message.

`Save and Test` persists the normalized configuration and sends a minimal text-only Chat Completions request. It sends no screenshot and requires a non-empty API key, valid HTTP/HTTPS endpoint with a host, and non-empty model. The UI reports success or a localized, sanitized failure.

Calendar mapping controls request EventKit full access only when the user explicitly configures mappings. Normal app launch never requests Calendar permission.

## Multimodal request

The service encodes the final image as JPEG and creates a standard non-streaming Chat Completions request:

```json
{
  "model": "GLM-5.3-Flash",
  "messages": [
    {"role": "system", "content": "<dynamic AICalendarPrompt>"},
    {
      "role": "user",
      "content": [
        {"type": "text", "text": "Extract calendar events from this screenshot"},
        {"type": "image_url", "image_url": {"url": "data:image/jpeg;base64,<omitted>"}}
      ]
    }
  ],
  "temperature": 0.1
}
```

Headers are `Content-Type: application/json` and `Authorization: Bearer <configured key>`. The request uses the existing URLSession concurrency style and an injected data loader in tests. It does not use Responses, Assistants, an SDK, `response_format`, or JSON schema.

The implementation never logs the request body, Authorization header, Base64 data, screenshot contents, or full model response.

## Prompt and output contract

`AICalendarPrompt` dynamically formats `Date()`, `Calendar.current`, and `TimeZone.current` for every request. It includes the local ISO-8601 date/time and timezone identifier and instructs the model to:

- extract only screenshot-supported meetings, appointments, work or personal arrangements, activities, travel, and other time-bound events
- never invent missing dates, times, titles, people, locations, URLs, or durations
- use only `work`, `personal`, or `unknown` for `calendar_type`
- return multiple events when present, or `{"events":[]}` when none are explicit
- return JSON only, with no Markdown fence or explanation
- set unknown or ambiguous date/time fields to `null`, set `requires_confirmation` to `true`, and list uncertain field names
- preserve explicit time ranges and explicit approximate durations
- place recurrence wording in notes because recurrence is unsupported
- omit alarms, reminders, all-day semantics, RRULEs, and generated repeated instances

The expected event object contains `title`, `calendar_type`, `start`, `end`, `location`, `notes`, `url`, `attendees`, `requires_confirmation`, `uncertain_fields`, and `confidence`. DTO decoding treats fields as untrusted and optional where necessary.

The response parser accepts a bare JSON object and also strips an accidental `````json` / ````` fence before decoding. It rejects empty content, non-JSON content, invalid top-level structure, invalid calendar types, malformed URLs, and invalid dates with user-readable errors. URL values are accepted only with an explicit safe scheme supported by `URL` parsing.

## Time normalization and validation

Date parsing uses ISO-8601 with timezone offsets and supports fractional-seconds fallback. The client never derives a concrete hour from words such as afternoon, evening, later, or after lunch.

- Known start and known end: preserve both exactly
- Known start and missing end: set end to start plus one hour
- Known start and explicit duration represented by the model: use that returned end
- Unknown or ambiguous start: keep start and end empty, force confirmation, and do not apply the one-hour default
- End less than or equal to start: mark invalid and require user correction

An event is ready for saving only when title is non-empty, start and end are valid, end is later than start, and a writable target calendar is resolved. `requires_confirmation` and `uncertain_fields` control warning presentation but never override the hard validation rules.

## EventKit permission and calendar mapping

Link `EventKit` in `Package.swift`. Add `NSCalendarsFullAccessUsageDescription` to the app Info.plist because the feature must enumerate real calendars. On macOS 14+, use `requestFullAccessToEvents`; do not use deprecated access requests or write-only access.

Permission is requested only when the user clicks AI Calendar for the first time or explicitly configures calendar mappings. Denied, restricted, write-only, or unavailable states produce localized guidance and perform no network upload or calendar write.

`CalendarEventService` owns one long-lived `EKEventStore`. It enumerates `eventStore.calendars(for: .event)` and filters `allowsContentModifications == true`.

For each logical type:

1. Prefer the saved calendar identifier when it still resolves to a writable event calendar
2. Otherwise find writable calendars with exact title `工作` or `个人`
3. If exactly one matches, select it and persist its identifier
4. If zero or more than one match, present a picker showing title and source, never choose randomly
5. If a saved identifier becomes invalid or read-only, clear it and require selection again

An AI result with `calendar_type == unknown` always requires the user to choose Work or Personal, after which the corresponding real calendar mapping is resolved. The model never supplies or controls EventKit identifiers.

## Confirmation window and native visual style

Use an AppKit `NSPanel`/`NSWindowController` that follows capcap's existing adaptive dark chrome, compact card spacing, `NSStackView`, `NSTextField`, `NSSecureTextField`, `NSPopUpButton`, `NSDatePicker`, `NSTextView`, and rounded `NSButton` conventions. The new window must look like an extension of the current editor and settings UI, not a standalone design system.

For multiple results, show a left event list with inclusion checkboxes and a right editable form for the selected event. The header shows `Recognized N events`. Each event permits editing:

- include/exclude
- Work or Personal logical calendar
- title
- date and start time
- end date and time
- location
- URL
- notes
- attendees

Uncertain fields receive a visible warning such as `AI could not determine an exact time, please confirm`. Unknown required fields remain empty; the UI does not invent values merely to enable the save button. The primary button is disabled until every selected event is valid and has a writable resolved calendar. All AI output is presented as editable suggestion data.

If no events are returned, show `No clear calendar events were identified in the screenshot` and create nothing.

## Attendees

The macOS 14+ EventKit SDK exposes `EKCalendarItem.attendees` as read-only. The implementation does not use private APIs and does not attempt to construct `EKParticipant` values.

Attendees remain visible and editable in confirmation UI. On save, non-empty attendees are appended to notes in a localized section such as:

```text
与会人：
张三 zhangsan@example.com
李四
```

The UI states that attendee information is saved in notes and invitations are not sent. This avoids silently losing extracted data or implying that participants were invited.

## Save behavior and partial failures

Create one `EKEvent` per selected draft. Set title, calendar, start/end, location, notes, and URL. Do not set `isAllDay`, recurrence rules, or alarms. Save each event independently with span `.thisEvent`.

Collect each result. After the batch finishes, display `Succeeded X, failed Y`; failures include localized, sanitized per-event reasons without logging calendar contents. Successful events remain saved even if another item fails, and the UI does not claim all-or-nothing behavior.

## Error handling and security

Map these cases to localized user-facing errors: invalid endpoint, empty API key, empty model, image encoding failure, timeout, DNS/offline error, HTTP 401, 403, 429, 5xx, other non-2xx status, empty model content, JSON decode failure, non-JSON model output, permission denial, missing writable calendar, and EventKit save failure.

Error text never includes the API key, Authorization header, request body, Base64 image, full server body, full model response, or private calendar contents. No telemetry or analytics is added. The screenshot is sent only to the configured endpoint.

Because the required default endpoint uses HTTP, add an ATS exception only for `aigw-api.cmsrservice.com` with insecure HTTP loads allowed for that domain. Do not set `NSAllowsArbitraryLoads`. HTTPS endpoints continue to work normally; arbitrary custom HTTP domains remain blocked by ATS unless separately allowed by the app in a future explicit change.

## Localization and documentation

Add every new localization key to all eight existing app language files and keep key sets aligned. All visible strings must comply with the repository rule that user-facing copy does not end with punctuation.

Update `README.md` and identical `README.zh-CN.md`, plus `README.en.md`, `README.zh-TW.md`, `README.ja.md`, `README.ko.md`, `README.fr.md`, `README.ru.md`, and `README.vi.md` according to each file's current scope. Public documentation describes screenshot-to-AI-to-Apple-Calendar behavior, Calendar permission, user-supplied OpenAI-compatible configuration, Work/Personal mapping, mandatory confirmation, and attendee note fallback. It does not present the private gateway endpoint or model as an official public capability.

Add the feature under `CHANGELOG.md` `[Unreleased]` without rewriting the released `1.7.11` entry.

## Tests and verification

Use test-driven development with fake URL loading and fake calendar storage. Tests never contact a model or modify the user's Calendar.

Required coverage:

- single-event, multi-event, fenced JSON, and empty events parsing
- missing end defaults to one hour only when start exists
- ambiguous time remains empty and requires confirmation
- `work`, `personal`, and `unknown`
- URL and attendee parsing
- invalid JSON, empty content, and HTTP error mapping including 401/403/429/5xx/timeout
- multimodal request shape and absence of image data from logs/errors
- config load/save/defaults/normalization without a real API key
- EventKit abstraction permission states, writable filtering, unique-name mapping, duplicate-name selection, stale identifier recovery, and per-event partial failure summaries
- attendee note fallback and absence of alarms/recurrence
- old toolbar layouts gain `aiCalendar` before `scrollCapture` without losing or moving existing items
- default toolbar places `aiCalendar` first in the side toolbar
- all localization files retain identical key sets and valid plist syntax

Verification sequence after implementation:

1. `bash scripts/compile-check.sh`
2. `swift build`
3. `swift test`
4. `git diff --check`
5. `plutil -lint` for Info.plist and all localization files
6. targeted secret scan for API keys, Bearer values, Base64 payloads, and accidental fixtures
7. `bash scripts/rebuild-and-open.sh`
8. use the exact installed app path and capcap agent window listing for runtime UI checks

The current machine baseline can run `swift build`, but `swift test` fails before any feature changes because only Command Line Tools are selected and `XCTest`/`xctest` are absent. This environmental limitation must be rechecked after implementation and reported separately from compile/build evidence.

## Known first-version limits

- No all-day events
- No recurrence or RRULE support
- No reminders or alarms
- No attendee invitations; attendees are preserved in notes
- No automatic event creation without human confirmation
- Custom insecure HTTP domains are not globally permitted by ATS
- Calendar display-name matching is limited to exact `工作` and `个人` until the user chooses and persists identifiers
