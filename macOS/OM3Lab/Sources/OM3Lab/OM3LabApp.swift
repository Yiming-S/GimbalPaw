import SwiftUI

@main
struct OM3LabApp: App {
    @StateObject private var bluetooth: OM3BluetoothController
    @StateObject private var camera: CameraController
    @StateObject private var tracking: PersonTrackingCoordinator
    @StateObject private var calibration: GimbalRangeCalibrationCoordinator

    init() {
        let bluetooth = OM3BluetoothController()
        let camera = CameraController()
        _bluetooth = StateObject(wrappedValue: bluetooth)
        _camera = StateObject(wrappedValue: camera)
        let tracking = PersonTrackingCoordinator(
            bluetooth: bluetooth,
            camera: camera
        )
        _tracking = StateObject(wrappedValue: tracking)
        _calibration = StateObject(
            wrappedValue: GimbalRangeCalibrationCoordinator(
                bluetooth: bluetooth,
                camera: camera,
                tracking: tracking
            )
        )
    }

    var body: some Scene {
        Window("OM3 Lab", id: "main") {
            ContentView(
                bluetooth: bluetooth,
                camera: camera,
                tracking: tracking,
                calibration: calibration
            )
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 1220, height: 780)
        .windowResizability(.contentMinSize)
    }
}
