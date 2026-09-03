import AppKit
import XCTest
@testable import capcap

final class ToolbarLayoutTests: XCTestCase {
    func testDefaultPlacesSpotlightBetweenMarkerAndMosaic() throws {
        let primary = ToolbarLayout.default.primary
        let markerIndex = try XCTUnwrap(primary.firstIndex(of: .marker))
        let spotlightIndex = try XCTUnwrap(primary.firstIndex(of: .spotlight))
        let mosaicIndex = try XCTUnwrap(primary.firstIndex(of: .mosaic))

        XCTAssertEqual(spotlightIndex, markerIndex + 1)
        XCTAssertEqual(mosaicIndex, spotlightIndex + 1)
    }

    func testOlderPersistedLayoutAddsSpotlightAfterMarker() throws {
        let oldLayout = ToolbarLayout(
            primary: [.rectangle, .marker, .mosaic],
            side: [.save, .confirm],
            hidden: ToolbarLayout.canonicalOrder.filter {
                ![.rectangle, .marker, .spotlight, .mosaic, .save, .confirm].contains($0)
            }
        )

        let normalized = oldLayout.normalized()
        let markerIndex = try XCTUnwrap(normalized.primary.firstIndex(of: .marker))
        let spotlightIndex = try XCTUnwrap(normalized.primary.firstIndex(of: .spotlight))
        let mosaicIndex = try XCTUnwrap(normalized.primary.firstIndex(of: .mosaic))

        XCTAssertEqual(spotlightIndex, markerIndex + 1)
        XCTAssertEqual(mosaicIndex, spotlightIndex + 1)
    }

    func testSpotlightToolbarSymbolExistsOnSupportedmacOS() {
        XCTAssertNotNil(
            NSImage(
                systemSymbolName: ToolbarItemID.spotlight.symbolName,
                accessibilityDescription: nil
            )
        )
    }

    func testAICalendarIsMomentaryAndUsesCalendarBadgeSymbol() {
        XCTAssertEqual(ToolbarItemID.aiCalendar.kind, .momentary)
        XCTAssertEqual(ToolbarItemID.aiCalendar.symbolName, "calendar.badge.plus")
        XCTAssertEqual(ToolbarItemID.aiCalendar.rawValue, "aiCalendar")
    }

    func testDefaultSideToolbarStartsWithAICalendar() throws {
        let side = ToolbarLayout.default.side
        XCTAssertEqual(side.first, .aiCalendar)
        let scrollIndex = try XCTUnwrap(side.firstIndex(of: .scrollCapture))
        XCTAssertEqual(scrollIndex, 1)
    }

    func testNormalizedOlderLayoutInsertsAICalendarBeforeScrollCaptureInSameBucket() {
        let oldPrimary: [ToolbarItemID] = [.rectangle, .moveSelection]
        let oldSide: [ToolbarItemID] = [.save, .scrollCapture, .close]
        let oldHidden = ToolbarLayout.canonicalOrder.filter {
            !oldPrimary.contains($0) && !oldSide.contains($0) && $0 != .aiCalendar
        }
        let normalized = ToolbarLayout(
            primary: oldPrimary,
            side: oldSide,
            hidden: oldHidden
        ).normalized()

        XCTAssertEqual(normalized.primary, oldPrimary)
        XCTAssertEqual(normalized.side, [.save, .aiCalendar, .scrollCapture, .close])
        XCTAssertEqual(normalized.hidden, oldHidden)
    }

    func testNormalizedOlderLayoutWithoutScrollCaptureKeepsExistingBuckets() {
        let oldPrimary: [ToolbarItemID] = [.rectangle, .moveSelection]
        let oldSide: [ToolbarItemID] = [.save, .close]
        let oldHidden = ToolbarLayout.canonicalOrder.filter {
            !oldPrimary.contains($0) && !oldSide.contains($0) && $0 != .aiCalendar && $0 != .scrollCapture
        }
        let normalized = ToolbarLayout(
            primary: oldPrimary,
            side: oldSide,
            hidden: oldHidden
        ).normalized()

        let newlyIntroduced: Set<ToolbarItemID> = [.aiCalendar, .scrollCapture]
        XCTAssertEqual(normalized.primary.filter { !newlyIntroduced.contains($0) }, oldPrimary)
        XCTAssertEqual(normalized.side.filter { !newlyIntroduced.contains($0) }, oldSide)
        XCTAssertEqual(normalized.hidden.filter { !newlyIntroduced.contains($0) }, oldHidden)
        XCTAssertEqual(Set(normalized.primary + normalized.side + normalized.hidden), Set(ToolbarLayout.canonicalOrder))
    }
}
