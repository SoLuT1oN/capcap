import AppKit
import Foundation
import XCTest
@testable import capcap

final class AICalendarServiceTests: XCTestCase {
    func testUserFacingErrorMessagesAreLocalizedAndSanitized() {
        XCTAssertEqual(
            AICalendarErrorMessages.message(for: AICalendarServiceError.unauthorized),
            L10n.aiCalendarUnauthorized
        )
        XCTAssertEqual(
            AICalendarErrorMessages.message(for: AICalendarServiceError.rateLimited),
            L10n.aiCalendarRateLimited
        )
        XCTAssertEqual(
            AICalendarErrorMessages.message(for: AICalendarServiceError.invalidJSON),
            L10n.aiCalendarInvalidResponse
        )
        XCTAssertEqual(
            AICalendarErrorMessages.message(for: CalendarEventServiceError.accessRequiresFullAccess),
            L10n.aiCalendarFullAccessRequired
        )
        XCTAssertEqual(
            AICalendarErrorMessages.message(for: CalendarEventServiceError.noWritableCalendars(type: .work)),
            L10n.aiCalendarNoWritableCalendar
        )
        XCTAssertEqual(
            AICalendarErrorMessages.message(for: NSError(
                domain: "Sensitive",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "secret-key-and-calendar-name"]
            )),
            L10n.aiCalendarInvalidRequest
        )
    }

    func testParsesSingleEventAndDefaultsMissingEndToOneHour() throws {
        let events = try AICalendarService.parse(content: """
        {"events":[{"title":"Planning","calendar_type":"work","start":"2026-09-03T09:00:00+08:00"}]}
        """)

        let event = try XCTUnwrap(events.first)
        XCTAssertEqual(event.title, "Planning")
        XCTAssertEqual(event.calendarType, .work)
        XCTAssertEqual(event.start, isoDate("2026-09-03T09:00:00+08:00"))
        XCTAssertEqual(event.end, isoDate("2026-09-03T10:00:00+08:00"))
        XCTAssertFalse(event.requiresConfirmation)
    }

    func testParsesFractionalDatesAndMultipleEventsFromJsonFence() throws {
        let events = try AICalendarService.parse(content: """
        ```json
        {"events":[
          {"title":"Work","calendar_type":"work","start":"2026-09-03T09:00:00.123+08:00","end":"2026-09-03T10:00:00.123+08:00"},
          {"title":"Dinner","calendar_type":"personal","start":"2026-09-03T18:00:00+08:00","end":"2026-09-03T19:30:00+08:00"}
        ]}
        ```
        """)

        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events[0].calendarType, .work)
        XCTAssertEqual(events[1].calendarType, .personal)
        let start = try XCTUnwrap(events[0].start)
        let end = try XCTUnwrap(events[0].end)
        XCTAssertEqual(end.timeIntervalSince(start), 3600.0, accuracy: 0.01)
    }

    func testEmptyEventsProducesNoDrafts() throws {
        XCTAssertTrue(try AICalendarService.parse(content: #"{"events":[]}"#).isEmpty)
    }

    func testMissingOrAmbiguousStartKeepsBothDatesEmptyAndRequiresConfirmation() throws {
        let events = try AICalendarService.parse(content: """
        {"events":[
          {"title":"Missing","calendar_type":"unknown","end":"2026-09-03T10:00:00+08:00"},
          {"title":"Ambiguous","calendar_type":"personal","start":"tomorrow afternoon","end":"tomorrow evening"},
          {"title":"Date only","calendar_type":"work","start":"2026-09-03"}
        ]}
        """)

        XCTAssertNil(events[0].start)
        XCTAssertNil(events[0].end)
        XCTAssertTrue(events[0].requiresConfirmation)
        XCTAssertNil(events[1].start)
        XCTAssertNil(events[1].end)
        XCTAssertTrue(events[1].requiresConfirmation)
        XCTAssertTrue(events[1].uncertainFields.contains("start"))
        XCTAssertNil(events[2].start)
        XCTAssertNil(events[2].end)
        XCTAssertTrue(events[2].requiresConfirmation)
        XCTAssertTrue(events[2].uncertainFields.contains("start"))
    }

    func testUnknownCalendarTypeIsPreservedAsUnknown() throws {
        let events = try AICalendarService.parse(content: """
        {"events":[
          {"title":"Other","calendar_type":"unknown","start":"2026-09-03T09:00:00Z","end":"2026-09-03T10:00:00Z"}
        ]}
        """)

        XCTAssertEqual(events[0].calendarType, .unknown)
        XCTAssertTrue(events[0].requiresConfirmation)
    }

    func testParsesAttendeesAndDropsUnsafeURLWithoutLeakingIt() throws {
        let events = try AICalendarService.parse(content: """
        {"events":[{"title":"Review","calendar_type":"work","start":"2026-09-03T09:00:00Z","end":"2026-09-03T10:00:00Z","url":"javascript:alert(1)","attendees":[{"name":"张三","email":"zhangsan@example.com"},{"email":"li@example.com"}]}]}
        """)

        let event = try XCTUnwrap(events.first)
        XCTAssertNil(event.url)
        XCTAssertTrue(event.uncertainFields.contains("url"))
        XCTAssertEqual(event.attendees.count, 2)
        XCTAssertEqual(event.attendees[0].name, "张三")
        XCTAssertEqual(event.attendees[0].email, "zhangsan@example.com")
        XCTAssertEqual(event.attendees[1].name, "")
    }

    func testParsesSafeHTTPURL() throws {
        let events = try AICalendarService.parse(content: """
        {"events":[{"title":"Review","calendar_type":"work","start":"2026-09-03T09:00:00Z","end":"2026-09-03T10:00:00Z","url":"https://meet.example.com/room/42"}]}
        """)

        XCTAssertEqual(events.first?.url?.absoluteString, "https://meet.example.com/room/42")
    }

    func testRejectsEmptyAndInvalidJsonContent() {
        XCTAssertThrowsError(try AICalendarService.parse(content: " \n\t")) { error in
            XCTAssertEqual(error as? AICalendarServiceError, .emptyContent)
        }
        XCTAssertThrowsError(try AICalendarService.parse(content: "not json")) { error in
            XCTAssertEqual(error as? AICalendarServiceError, .invalidJSON)
        }
        XCTAssertThrowsError(try AICalendarService.parse(content: #"{}"#)) { error in
            XCTAssertEqual(error as? AICalendarServiceError, .invalidResponse)
        }
        XCTAssertThrowsError(try AICalendarService.parse(content: #"{"events":null}"#)) { error in
            XCTAssertEqual(error as? AICalendarServiceError, .invalidResponse)
        }
        XCTAssertThrowsError(try AICalendarService.parse(content: #"{"events":"not-an-array"}"#)) { error in
            XCTAssertEqual(error as? AICalendarServiceError, .invalidResponse)
        }
    }

    func testConfigDefaultsAndUserDefaultsRoundTripTrimValues() throws {
        let suiteName = "AICalendarServiceTests.config"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let defaultsConfig = AICalendarConfigStore.load(from: defaults)
        XCTAssertEqual(defaultsConfig.endpoint, AICalendarConfig.defaultEndpoint)
        XCTAssertEqual(defaultsConfig.model, AICalendarConfig.defaultModel)
        XCTAssertEqual(defaultsConfig.apiKey, "")

        AICalendarConfigStore.save(
            AICalendarConfig(
                endpoint: " https://example.com/v1/chat/completions ",
                apiKey: " test-key ",
                model: " GLM-test ",
                workCalendarIdentifier: " work-id ",
                personalCalendarIdentifier: " personal-id "
            ),
            to: defaults
        )
        let loaded = AICalendarConfigStore.load(from: defaults)
        XCTAssertEqual(loaded.endpoint, "https://example.com/v1/chat/completions")
        XCTAssertEqual(loaded.apiKey, "test-key")
        XCTAssertEqual(loaded.model, "GLM-test")
        XCTAssertEqual(loaded.workCalendarIdentifier, "work-id")
        XCTAssertEqual(loaded.personalCalendarIdentifier, "personal-id")
    }

    func testPromptIncludesCurrentDateCalendarAndTimezoneRules() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 60 * 60)!
        let now = isoDate("2026-09-03T12:34:56+08:00")
        let prompt = AICalendarPrompt.make(
            now: now,
            calendar: calendar,
            timeZone: calendar.timeZone
        )

        XCTAssertTrue(prompt.contains("2026-09-03T12:34:56"))
        XCTAssertTrue(prompt.contains(String(describing: calendar.identifier)))
        XCTAssertTrue(prompt.contains(calendar.timeZone.identifier))
        XCTAssertTrue(prompt.contains("requires_confirmation"))
        XCTAssertTrue(prompt.contains("work"))
        XCTAssertTrue(prompt.contains("personal"))
        XCTAssertTrue(prompt.contains("unknown"))
        XCTAssertTrue(prompt.contains("events"))
        XCTAssertTrue(prompt.contains("JSON"))
        XCTAssertTrue(prompt.contains("recurrence"))
    }

    func testBuildsNonStreamingMultimodalRequestWithoutResponseFormat() throws {
        let image = try onePixelImage()
        let config = AICalendarConfig(
            endpoint: "https://example.com/v1/chat/completions",
            apiKey: "test-key",
            model: "test-model"
        )
        let request = try AICalendarService.makeRequest(
            image: image,
            config: config,
            now: isoDate("2026-09-03T12:34:56+08:00"),
            calendar: .current,
            timeZone: .current
        )

        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")
        let body = try XCTUnwrap(request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        XCTAssertEqual(body["model"] as? String, "test-model")
        XCTAssertEqual(body["temperature"] as? Double, 0.1)
        XCTAssertEqual(body["stream"] as? Bool, false)
        XCTAssertNil(body["response_format"])
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        let content = try XCTUnwrap(messages.last?["content"] as? [[String: Any]])
        XCTAssertEqual(content.first?["type"] as? String, "text")
        XCTAssertEqual(content.last?["type"] as? String, "image_url")
        let imageURL = try XCTUnwrap(content.last?["image_url"] as? [String: Any])
        XCTAssertTrue((imageURL["url"] as? String)?.hasPrefix("data:image/jpeg;base64,") == true)
    }

    func testValidatesHTTPAndHTTPSEndpointsAndRequiredFields() throws {
        let image = try onePixelImage()
        let base = AICalendarConfig(apiKey: "test-key", model: "test-model")
        for scheme in ["http", "https"] {
            let config = AICalendarConfig(
                endpoint: "\(scheme)://example.com/v1/chat/completions",
                apiKey: base.apiKey,
                model: base.model
            )
            XCTAssertNoThrow(try AICalendarService.makeRequest(image: image, config: config))
        }
        for endpoint in ["ftp://example.com/v1/chat/completions", "https:///missing-host"] {
            XCTAssertThrowsError(try AICalendarService.makeRequest(
                image: image,
                config: AICalendarConfig(endpoint: endpoint, apiKey: base.apiKey, model: base.model)
            )) { error in
                XCTAssertEqual(error as? AICalendarServiceError, .invalidEndpoint)
            }
        }
        XCTAssertThrowsError(try AICalendarService.makeRequest(
            image: image,
            config: AICalendarConfig(apiKey: "", model: base.model)
        )) { error in
            XCTAssertEqual(error as? AICalendarServiceError, .missingAPIKey)
        }
        XCTAssertThrowsError(try AICalendarService.makeRequest(
            image: image,
            config: AICalendarConfig(apiKey: base.apiKey, model: " ")
        )) { error in
            XCTAssertEqual(error as? AICalendarServiceError, .invalidModel)
        }
    }

    func testMapsHTTPAndNetworkFailuresWithoutReturningSensitiveDetails() async throws {
        let image = try onePixelImage()
        let endpoint = URL(string: "https://example.com/v1/chat/completions")!
        for (status, expected) in [
            (401, AICalendarServiceError.unauthorized),
            (403, AICalendarServiceError.forbidden),
            (429, AICalendarServiceError.rateLimited),
            (500, AICalendarServiceError.serverError),
            (418, AICalendarServiceError.httpError)
        ] as [(Int, AICalendarServiceError)] {
            let service = AICalendarService(
                config: AICalendarConfig(endpoint: endpoint.absoluteString, apiKey: "test-key", model: "test-model"),
                dataLoader: { _ in
                    let response = HTTPURLResponse(url: endpoint, statusCode: status, httpVersion: nil, headerFields: nil)!
                    return (Data(#"{"secret":"test-key","image":"ZmFrZQ=="}"#.utf8), response)
                }
            )

            do {
                _ = try await service.extract(from: image)
                XCTFail("Expected HTTP (status) failure")
            } catch let error as AICalendarServiceError {
                switch (status, error) {
                case (401, .unauthorized), (403, .forbidden), (429, .rateLimited), (500, .serverError), (418, .httpError):
                    break
                default:
                    XCTFail("Unexpected mapped error: \(error)")
                }
                XCTAssertFalse(error.localizedDescription.contains("test-key"))
                XCTAssertFalse(error.localizedDescription.contains("ZmFrZQ=="))
            }
            _ = expected
        }

        let timeoutService = AICalendarService(
            config: AICalendarConfig(endpoint: endpoint.absoluteString, apiKey: "test-key", model: "test-model"),
            dataLoader: { _ in throw URLError(.timedOut) }
        )
        do {
            _ = try await timeoutService.extract(from: image)
            XCTFail("Expected timeout failure")
        } catch let error as AICalendarServiceError {
            XCTAssertEqual(error, .timeout)
        }

        for networkCode in [URLError.Code.cannotFindHost, .notConnectedToInternet] {
            let networkService = AICalendarService(
                config: AICalendarConfig(endpoint: endpoint.absoluteString, apiKey: "test-key", model: "test-model"),
                dataLoader: { _ in throw URLError(networkCode) }
            )
            do {
                _ = try await networkService.extract(from: image)
                XCTFail("Expected network failure")
            } catch let error as AICalendarServiceError {
                XCTAssertEqual(error, .networkError)
            }
        }

        let emptyService = AICalendarService(
            config: AICalendarConfig(endpoint: endpoint.absoluteString, apiKey: "test-key", model: "test-model"),
            dataLoader: { _ in
                (Data(), HTTPURLResponse(url: endpoint, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
        )
        do {
            _ = try await emptyService.extract(from: image)
            XCTFail("Expected empty response failure")
        } catch let error as AICalendarServiceError {
            XCTAssertEqual(error, .emptyContent)
        }

        let malformedResponseService = AICalendarService(
            config: AICalendarConfig(endpoint: endpoint.absoluteString, apiKey: "test-key", model: "test-model"),
            dataLoader: { _ in
                (Data("{}".utf8), HTTPURLResponse(url: endpoint, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
        )
        do {
            _ = try await malformedResponseService.extract(from: image)
            XCTFail("Expected malformed response failure")
        } catch let error as AICalendarServiceError {
            XCTAssertEqual(error, .invalidResponse)
        }

        let nonJSONContentService = AICalendarService(
            config: AICalendarConfig(endpoint: endpoint.absoluteString, apiKey: "test-key", model: "test-model"),
            dataLoader: { _ in
                let body = Data(#"{"choices":[{"message":{"content":"not json"}}]}"#.utf8)
                return (body, HTTPURLResponse(url: endpoint, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
        )
        do {
            _ = try await nonJSONContentService.extract(from: image)
            XCTFail("Expected non-JSON model content failure")
        } catch let error as AICalendarServiceError {
            XCTAssertEqual(error, .invalidJSON)
        }
    }

    func testImageEncoderCapsLongestEdgeAndUsesJPEG() throws {
        let image = NSImage(size: NSSize(width: 3000, height: 1000))
        image.lockFocus()
        NSColor.systemBlue.setFill()
        NSRect(origin: .zero, size: image.size).fill()
        image.unlockFocus()

        let data = try AICalendarImageEncoder.jpegData(from: image)
        let representation = try XCTUnwrap(NSBitmapImageRep(data: data))
        XCTAssertEqual(Array(data.prefix(2)), [0xFF, 0xD8])
        XCTAssertEqual(max(representation.pixelsWide, representation.pixelsHigh), 2560)
        XCTAssertEqual(representation.pixelsWide, 2560)
        XCTAssertEqual(representation.pixelsHigh, 853)

        let lowerQuality = try AICalendarImageEncoder.jpegData(from: image, quality: 0.2)
        XCTAssertNotEqual(data.count, lowerQuality.count)
    }

    private func isoDate(_ value: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)!
    }

    private func onePixelImage() throws -> NSImage {
        let image = NSImage(size: NSSize(width: 1, height: 1))
        image.lockFocus()
        NSColor.systemRed.setFill()
        NSRect(x: 0, y: 0, width: 1, height: 1).fill()
        image.unlockFocus()
        return image
    }
}
