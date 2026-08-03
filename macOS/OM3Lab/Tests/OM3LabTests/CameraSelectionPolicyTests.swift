import XCTest
@testable import OM3Lab

final class CameraSelectionPolicyTests: XCTestCase {
    private let anker = CameraDeviceDescriptor(id: "anker", name: "Anker")
    private let iPhone = CameraDeviceDescriptor(
        id: "iphone",
        name: "Yiming 的 iPhone Camera"
    )
    private let sameNamedReplacement = CameraDeviceDescriptor(
        id: "iphone-replacement",
        name: "Yiming 的 iPhone Camera"
    )

    func testRememberedExactIDWinsRegardlessOfDiscoveryOrder() {
        XCTAssertEqual(
            CameraSelectionPolicy.rememberedDevice(
                in: [sameNamedReplacement, anker, iPhone],
                rememberedID: iPhone.id
            ),
            iPhone
        )
    }

    func testRememberedNameNeverSubstitutesForMissingExactID() {
        XCTAssertNil(
            CameraSelectionPolicy.rememberedDevice(
                in: [sameNamedReplacement, anker],
                rememberedID: iPhone.id
            )
        )
    }

    func testNoMemoryNeverPreselectsSoleCamera() {
        XCTAssertNil(
            CameraSelectionPolicy.initialSelection(
                from: [anker],
                rememberedID: nil
            )
        )
    }

    func testMissingRememberedCameraNeverFallsBackToSoleOtherCamera() {
        XCTAssertNil(
            CameraSelectionPolicy.initialSelection(
                from: [anker],
                rememberedID: iPhone.id
            )
        )
    }

    func testRememberedCameraIsInitialSelectionWhenPresent() {
        XCTAssertEqual(
            CameraSelectionPolicy.initialSelection(
                from: [anker, iPhone],
                rememberedID: iPhone.id
            ),
            iPhone.id
        )
    }

    func testRunningDeviceMismatchSwitchesToCurrentSelection() {
        XCTAssertEqual(
            CameraSelectionPolicy.runningDeviceAction(
                runningDeviceID: anker.id,
                selectedDeviceID: iPhone.id,
                userStopped: false
            ),
            .switchTo(iPhone.id)
        )
    }

    func testExplicitStopAlwaysStopsRunningDevice() {
        XCTAssertEqual(
            CameraSelectionPolicy.runningDeviceAction(
                runningDeviceID: iPhone.id,
                selectedDeviceID: iPhone.id,
                userStopped: true
            ),
            .stop
        )
    }

    func testRunningDeviceWithoutSelectionMustStop() {
        XCTAssertEqual(
            CameraSelectionPolicy.runningDeviceAction(
                runningDeviceID: anker.id,
                selectedDeviceID: nil,
                userStopped: false
            ),
            .stop
        )
    }

    func testCurrentGenerationAndSelectionAcceptRunningEvent() {
        XCTAssertTrue(
            CameraStartEventPolicy.acceptsRunningEvent(
                generation: 7,
                deviceID: iPhone.id,
                activeGeneration: 7,
                activeDeviceID: iPhone.id,
                selectedDeviceID: iPhone.id
            )
        )
    }

    func testStaleGenerationCannotOverwriteNewSelection() {
        XCTAssertFalse(
            CameraStartEventPolicy.acceptsRunningEvent(
                generation: 6,
                deviceID: anker.id,
                activeGeneration: 7,
                activeDeviceID: iPhone.id,
                selectedDeviceID: iPhone.id
            )
        )
    }

    func testMatchingGenerationCannotPublishWrongDevice() {
        XCTAssertFalse(
            CameraStartEventPolicy.acceptsRunningEvent(
                generation: 7,
                deviceID: anker.id,
                activeGeneration: 7,
                activeDeviceID: iPhone.id,
                selectedDeviceID: iPhone.id
            )
        )
    }

    func testStaleStopCannotCancelNewerStart() {
        XCTAssertFalse(
            CameraStartEventPolicy.acceptsStoppedEvent(
                generation: 6,
                activeGeneration: 7,
                commandGeneration: 7
            )
        )
        XCTAssertTrue(
            CameraStartEventPolicy.acceptsStoppedEvent(
                generation: 8,
                activeGeneration: nil,
                commandGeneration: 8
            )
        )
    }

    func testUntaggedStopCannotCancelInFlightStart() {
        XCTAssertFalse(
            CameraStartEventPolicy.acceptsStoppedEvent(
                generation: nil,
                activeGeneration: 7,
                commandGeneration: 7
            )
        )
    }

    func testStaleErrorCannotOverwriteNewerStart() {
        XCTAssertFalse(
            CameraStartEventPolicy.acceptsErrorEvent(
                generation: 6,
                activeGeneration: 7,
                commandGeneration: 7
            )
        )
        XCTAssertTrue(
            CameraStartEventPolicy.acceptsErrorEvent(
                generation: 7,
                activeGeneration: 7,
                commandGeneration: 7
            )
        )
    }

    func testAutomaticRetryBackoffIsBounded() {
        XCTAssertEqual(
            (1...5).compactMap {
                CameraAutomaticRetryPolicy.delayMilliseconds(afterFailure: $0)
            },
            [500, 1_000, 2_000, 4_000, 8_000]
        )
        XCTAssertNil(CameraAutomaticRetryPolicy.delayMilliseconds(afterFailure: 0))
        XCTAssertNil(CameraAutomaticRetryPolicy.delayMilliseconds(afterFailure: 6))
    }
}
