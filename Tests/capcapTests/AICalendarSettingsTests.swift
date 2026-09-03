import Foundation
import XCTest
@testable import capcap

final class AICalendarSettingsTests: XCTestCase {
    func testEditedConfigPreservesCalendarIdentifiers() {
        let storedConfig = AICalendarConfig(
            endpoint: "https://old.example.com/v1/chat/completions",
            apiKey: "old-key",
            model: "old-model",
            workCalendarIdentifier: "work-calendar",
            personalCalendarIdentifier: "personal-calendar"
        )

        let editedConfig = AICalendarSettingsPane.makeConfig(
            endpoint: "https://new.example.com/v1/chat/completions",
            apiKey: "new-key",
            model: "new-model",
            preservingCalendarIdentifiersFrom: storedConfig
        )

        XCTAssertEqual(editedConfig.endpoint, "https://new.example.com/v1/chat/completions")
        XCTAssertEqual(editedConfig.apiKey, "new-key")
        XCTAssertEqual(editedConfig.model, "new-model")
        XCTAssertEqual(editedConfig.workCalendarIdentifier, "work-calendar")
        XCTAssertEqual(editedConfig.personalCalendarIdentifier, "personal-calendar")
    }

    func testConnectionRequestUsesPlainTextWithoutImagePayload() throws {
        let config = AICalendarConfig(
            endpoint: "https://example.com/v1/chat/completions",
            apiKey: "test-key",
            model: "test-model"
        )

        let request = try AICalendarSettingsPane.makeConnectionRequest(for: config)

        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertNotNil(request.httpBody)

        let body = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any]
        )
        XCTAssertEqual(body["model"] as? String, "test-model")
        XCTAssertEqual(body["stream"] as? Bool, false)
        XCTAssertNil(body["image_url"])

        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0]["role"] as? String, "user")
        XCTAssertEqual(messages[0]["content"] as? String, "hello")
        XCTAssertFalse(String(data: try XCTUnwrap(request.httpBody), encoding: .utf8)?.contains("test-key") == true)
    }
}
