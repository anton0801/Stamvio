import AVFoundation
import Foundation
import Observation
import SwiftUI

/// UI state of the camera (S02). AVFoundation work happens in `CameraService` on its own queue.
@MainActor
@Observable
final class CameraViewModel {
    enum Status: Equatable {
        case idle
        case needsPermission
        case requesting
        case denied
        case restricted
        case unavailable
        case configuring
        case running
        case interrupted
        case failed(AppErrorCode)
    }

    let service = CameraService()
    private(set) var status: Status = .idle
    private(set) var capabilities = CameraCapabilities()
    var flashMode: AVCaptureDevice.FlashMode = .auto
    private(set) var zoomFactor: CGFloat?
    private(set) var isCapturing = false
    private(set) var lastPhotoID: UUID?
    var toast: ToastMessage?
    private(set) var focusIndicator: CGPoint?
    /// Angles from the rotation coordinator (degrees).
    private(set) var previewAngle: CGFloat = 90
    private(set) var captureAngle: CGFloat = 90

    private var device: AVCaptureDevice?
    private weak var previewLayer: AVCaptureVideoPreviewLayer?
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var observations: [NSKeyValueObservation] = []
    private var isActive = false
    private var position: AVCaptureDevice.Position = .back

    init() {
        service.onEvent = { [weak self] event in
            guard let self else { return }
            switch event {
            case .interrupted:
                if self.status == .running { self.status = .interrupted }
            case .interruptionEnded:
                if self.status == .interrupted { self.status = .running }
            case .runtimeError:
                // Keep what was saved; try to restart the session.
                if self.isActive { self.service.start() }
            }
        }
    }

    func activate() {
        isActive = true
        // No camera at all (e.g. Simulator): never ask for a permission that cannot be used.
        guard CameraService.isCameraHardwareAvailable else {
            status = .unavailable
            return
        }
        switch CameraService.authorization {
        case .notDetermined:
            status = .needsPermission
        case .denied:
            status = .denied
        case .restricted:
            status = .restricted
        case .authorized:
            Task { await configureAndStart() }
        }
    }

    func deactivate() {
        isActive = false
        service.stop()
        if status == .running || status == .interrupted { status = .idle }
    }

    /// The system prompt is shown once, after our explanation (S03). No repeated prompts after a refusal.
    func requestPermission() async {
        status = .requesting
        let granted = await CameraService.requestAccess()
        if granted {
            await configureAndStart()
        } else {
            status = .denied
        }
    }

    private func configureAndStart() async {
        guard CameraService.isCameraHardwareAvailable else {
            status = .unavailable
            return
        }
        status = .configuring
        do {
            let (capabilities, device) = try await service.configure(position: position)
            self.capabilities = capabilities
            self.device = device
            if !capabilities.hasFlash { flashMode = .off }
            zoomFactor = capabilities.zoomOptions.first(where: { $0.displayFactor == 1 })?.deviceFactor
            setUpRotation()
            guard isActive else { return }
            service.start()
            status = .running
        } catch {
            let code = (error as? AppError)?.code ?? .cameraConfigurationFailed
            ErrorLog.shared.record(code)
            status = code == .cameraUnavailable ? .unavailable : .failed(code)
        }
    }

    func attach(previewLayer: AVCaptureVideoPreviewLayer) {
        self.previewLayer = previewLayer
        setUpRotation()
    }

    private func setUpRotation() {
        guard let device, let previewLayer else { return }
        observations.removeAll()
        let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: previewLayer)
        rotationCoordinator = coordinator
        previewAngle = coordinator.videoRotationAngleForHorizonLevelPreview
        captureAngle = coordinator.videoRotationAngleForHorizonLevelCapture
        if let connection = previewLayer.connection, connection.isVideoRotationAngleSupported(previewAngle) {
            connection.videoRotationAngle = previewAngle
        }
        observations.append(coordinator.observe(\.videoRotationAngleForHorizonLevelPreview, options: [.new]) { [weak self] coordinator, _ in
            let angle = coordinator.videoRotationAngleForHorizonLevelPreview
            Task { @MainActor in self?.applyPreviewAngle(angle) }
        })
        observations.append(coordinator.observe(\.videoRotationAngleForHorizonLevelCapture, options: [.new]) { [weak self] coordinator, _ in
            let angle = coordinator.videoRotationAngleForHorizonLevelCapture
            Task { @MainActor in self?.captureAngle = angle }
        })
    }

    private func applyPreviewAngle(_ angle: CGFloat) {
        if let connection = previewLayer?.connection, connection.isVideoRotationAngleSupported(angle) {
            connection.videoRotationAngle = angle
        }
        previewAngle = angle
    }

    func switchCamera() async {
        guard capabilities.canSwitchCamera, !isCapturing else { return }
        position = position == .back ? .front : .back
        await configureAndStart()
    }

    func setZoom(_ option: CameraZoomOption) {
        zoomFactor = option.deviceFactor
        service.setZoom(option.deviceFactor)
    }

    func focus(devicePoint: CGPoint, layerPoint: CGPoint) {
        guard capabilities.supportsFocusPoint else { return }
        service.focus(at: devicePoint)
        focusIndicator = layerPoint
        Task {
            try? await Task.sleep(nanoseconds: 900_000_000)
            if self.focusIndicator == layerPoint { self.focusIndicator = nil }
        }
    }

    func cycleFlash() {
        let modes: [AVCaptureDevice.FlashMode] = [.auto, .on, .off].filter { capabilities.flashModes.contains($0) }
        guard !modes.isEmpty else { return }
        let index = modes.firstIndex(of: flashMode) ?? -1
        flashMode = modes[(index + 1) % modes.count]
    }

    /// One capture at a time; the shutter is disabled until the previous one is saved.
    func capture(projectID: UUID?, env: AppEnvironment, manualLocation: String?) async {
        guard !isCapturing, status == .running, let repository = env.repository, let coordinator = env.capture else { return }
        isCapturing = true
        defer { isCapturing = false }
        let shutter = Date()
        let locationEnabled = env.location.isEnabled
        let context = CaptureContext(captureID: UUID(), shutter: shutter, timeZone: .current, projectID: projectID,
                                     stamp: repository.preferences().defaultStamp, locationEnabled: locationEnabled,
                                     immediateFix: locationEnabled ? env.location.currentFreshFix(at: shutter) : nil,
                                     manualLocationLabel: manualLocation)
        do {
            let photo = try await service.capture(flashMode: capabilities.hasFlash ? flashMode : .off, rotationAngle: captureAngle)
            let record = try await coordinator.saveCapture(photo, context: context)
            lastPhotoID = record.id
            toast = ToastMessage(text: L("camera.saved"), kind: .success)
        } catch {
            let appError = AppError.wrap(error, default: .captureSaveFailed)
            ErrorLog.shared.record(appError.code)
            toast = ToastMessage(text: appError.displayMessage, kind: .error)
            Haptics.error()
        }
    }

    func setLastPhoto(_ id: UUID?) {
        lastPhotoID = id
    }
}
