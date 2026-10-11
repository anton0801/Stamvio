import AVFoundation
import Foundation
import UIKit

struct CameraZoomOption: Identifiable, Equatable {
    /// Factor shown to the user (0.5×, 1×, 3×).
    let displayFactor: CGFloat
    /// `videoZoomFactor` of the device that produces it.
    let deviceFactor: CGFloat

    var id: CGFloat { deviceFactor }

    var label: String {
        let rounded = (displayFactor * 10).rounded() / 10
        if rounded == rounded.rounded() { return "\(Int(rounded))×" }
        return String(format: "%.1f×", rounded).replacingOccurrences(of: ".", with: AppLanguage.current.formattingLocale.decimalSeparator ?? ".")
    }
}

/// What the current camera really supports. Unsupported controls are not shown.
struct CameraCapabilities: Equatable {
    var position: AVCaptureDevice.Position = .back
    var flashModes: [AVCaptureDevice.FlashMode] = []
    var zoomOptions: [CameraZoomOption] = []
    var canSwitchCamera = false
    var supportsFocusPoint = false

    var hasFlash: Bool { flashModes.contains(.on) || flashModes.contains(.auto) }
}

struct CapturedPhoto {
    let data: Data
    let format: ImageFormat
}

enum CameraAuthorization: Equatable {
    case notDetermined
    case authorized
    case denied
    case restricted
}

enum CameraEvent {
    case interrupted
    case interruptionEnded
    case runtimeError
}

/// AVFoundation capture session. All session work runs on a private serial queue; results are
/// returned through async calls. The UI never touches AVFoundation objects except the preview layer.
final class CameraService: NSObject, @unchecked Sendable {
    let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "workphotos.camera.session", qos: .userInitiated)
    private let photoOutput = AVCapturePhotoOutput()
    private var input: AVCaptureDeviceInput?
    private var isConfigured = false
    /// Accessed only on `sessionQueue`.
    private var processors: [Int64: PhotoCaptureProcessor] = [:]
    private var observers: [NSObjectProtocol] = []

    /// Delivered on the main queue.
    var onEvent: ((CameraEvent) -> Void)?

    override init() {
        super.init()
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVCaptureSession.wasInterruptedNotification, object: session, queue: .main) { [weak self] _ in
            self?.onEvent?(.interrupted)
        })
        observers.append(center.addObserver(forName: AVCaptureSession.interruptionEndedNotification, object: session, queue: .main) { [weak self] _ in
            self?.onEvent?(.interruptionEnded)
        })
        observers.append(center.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: .main) { [weak self] _ in
            self?.onEvent?(.runtimeError)
        })
    }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    // MARK: Authorization

    static var authorization: CameraAuthorization {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return .authorized
        case .notDetermined: return .notDetermined
        case .restricted: return .restricted
        default: return .denied
        }
    }

    static func requestAccess() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .video)
    }

    static var isCameraHardwareAvailable: Bool {
        AVCaptureDevice.default(for: .video) != nil
    }

    // MARK: Configuration

    /// Configures (once) and returns the capabilities and the active device.
    func configure(position: AVCaptureDevice.Position) async throws -> (CameraCapabilities, AVCaptureDevice) {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(CameraCapabilities, AVCaptureDevice), Error>) in
            sessionQueue.async {
                do {
                    let result = try self.configureOnQueue(position: position)
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func configureOnQueue(position: AVCaptureDevice.Position) throws -> (CameraCapabilities, AVCaptureDevice) {
        guard let device = Self.bestDevice(for: position) else { throw AppError(.cameraUnavailable) }
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        if !isConfigured {
            session.sessionPreset = .photo
        }
        if let current = input {
            session.removeInput(current)
            input = nil
        }
        let newInput: AVCaptureDeviceInput
        do {
            newInput = try AVCaptureDeviceInput(device: device)
        } catch {
            throw AppError(.cameraConfigurationFailed)
        }
        guard session.canAddInput(newInput) else { throw AppError(.cameraConfigurationFailed) }
        session.addInput(newInput)
        input = newInput

        if !isConfigured {
            guard session.canAddOutput(photoOutput) else { throw AppError(.cameraConfigurationFailed) }
            session.addOutput(photoOutput)
            photoOutput.maxPhotoQualityPrioritization = .balanced
            isConfigured = true
        }
        if let dimensions = device.activeFormat.supportedMaxPhotoDimensions.last {
            photoOutput.maxPhotoDimensions = dimensions
        }

        let zoomOptions = Self.zoomOptions(for: device)
        if let standard = zoomOptions.first(where: { $0.displayFactor == 1 }) {
            setZoomOnQueue(device: device, factor: standard.deviceFactor)
        }
        let canSwitch = Self.bestDevice(for: position == .back ? .front : .back) != nil
        let capabilities = CameraCapabilities(position: position,
                                              flashModes: photoOutput.supportedFlashModes,
                                              zoomOptions: zoomOptions.count > 1 ? zoomOptions : [],
                                              canSwitchCamera: canSwitch,
                                              supportsFocusPoint: device.isFocusPointOfInterestSupported)
        return (capabilities, device)
    }

    func start() {
        sessionQueue.async {
            guard self.isConfigured, !self.session.isRunning else { return }
            self.session.startRunning()
        }
    }

    func stop() {
        sessionQueue.async {
            guard self.session.isRunning else { return }
            self.session.stopRunning()
        }
    }

    var isRunning: Bool { session.isRunning }

    // MARK: Device controls

    func setZoom(_ factor: CGFloat) {
        sessionQueue.async {
            guard let device = self.input?.device else { return }
            self.setZoomOnQueue(device: device, factor: factor)
        }
    }

    private func setZoomOnQueue(device: AVCaptureDevice, factor: CGFloat) {
        let clamped = min(max(factor, device.minAvailableVideoZoomFactor), device.maxAvailableVideoZoomFactor)
        do {
            try device.lockForConfiguration()
            device.videoZoomFactor = clamped
            device.unlockForConfiguration()
        } catch {
            // Zoom is optional; keep the current factor.
        }
    }

    /// `devicePoint` in the capture device coordinate space (0…1).
    func focus(at devicePoint: CGPoint) {
        sessionQueue.async {
            guard let device = self.input?.device else { return }
            do {
                try device.lockForConfiguration()
                if device.isFocusPointOfInterestSupported, device.isFocusModeSupported(.autoFocus) {
                    device.focusPointOfInterest = devicePoint
                    device.focusMode = .autoFocus
                }
                if device.isExposurePointOfInterestSupported, device.isExposureModeSupported(.autoExpose) {
                    device.exposurePointOfInterest = devicePoint
                    device.exposureMode = .autoExpose
                }
                device.isSubjectAreaChangeMonitoringEnabled = true
                device.unlockForConfiguration()
            } catch {
                // Focus is best effort.
            }
        }
    }

    // MARK: Capture

    /// Captures one photo. `rotationAngle` comes from the rotation coordinator so the file has the
    /// physical orientation of the phone. Front-camera files are never mirrored.
    func capture(flashMode: AVCaptureDevice.FlashMode, rotationAngle: CGFloat?) async throws -> CapturedPhoto {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CapturedPhoto, Error>) in
            sessionQueue.async {
                guard self.isConfigured, self.session.isRunning else {
                    continuation.resume(throwing: AppError(.cameraUnavailable))
                    return
                }
                let useHEVC = self.photoOutput.availablePhotoCodecTypes.contains(.hevc)
                let settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: useHEVC ? AVVideoCodecType.hevc : AVVideoCodecType.jpeg])
                if self.photoOutput.supportedFlashModes.contains(flashMode) { settings.flashMode = flashMode }
                settings.photoQualityPrioritization = .balanced
                settings.maxPhotoDimensions = self.photoOutput.maxPhotoDimensions
                if let connection = self.photoOutput.connection(with: .video) {
                    if let angle = rotationAngle, connection.isVideoRotationAngleSupported(angle) {
                        connection.videoRotationAngle = angle
                    }
                    if connection.isVideoMirroringSupported {
                        connection.automaticallyAdjustsVideoMirroring = false
                        connection.isVideoMirrored = false
                    }
                }
                let uniqueID = settings.uniqueID
                let processor = PhotoCaptureProcessor(format: useHEVC ? .heic : .jpeg) { [weak self] result in
                    self?.sessionQueue.async { self?.processors[uniqueID] = nil }
                    continuation.resume(with: result)
                }
                self.processors[uniqueID] = processor
                self.photoOutput.capturePhoto(with: settings, delegate: processor)
            }
        }
    }

    // MARK: Devices

    static func bestDevice(for position: AVCaptureDevice.Position) -> AVCaptureDevice? {
        let types: [AVCaptureDevice.DeviceType] = position == .back
            ? [.builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera, .builtInWideAngleCamera]
            : [.builtInTrueDepthCamera, .builtInWideAngleCamera]
        let discovery = AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: position)
        for type in types {
            if let device = discovery.devices.first(where: { $0.deviceType == type }) { return device }
        }
        return nil
    }

    /// Only lenses that really exist on this device (virtual device switch-over points).
    static func zoomOptions(for device: AVCaptureDevice) -> [CameraZoomOption] {
        let switchOvers = device.virtualDeviceSwitchOverVideoZoomFactors.map { CGFloat(truncating: $0) }
        switch device.deviceType {
        case .builtInTripleCamera, .builtInDualWideCamera:
            // Device factor 1.0 = ultra wide (0.5×); the first switch-over is the wide lens (1×).
            guard let wide = switchOvers.first, wide > 0 else { return [] }
            var options = [CameraZoomOption(displayFactor: 1 / wide, deviceFactor: 1),
                           CameraZoomOption(displayFactor: 1, deviceFactor: wide)]
            for factor in switchOvers.dropFirst() {
                options.append(CameraZoomOption(displayFactor: factor / wide, deviceFactor: factor))
            }
            return options
        case .builtInDualCamera:
            guard let tele = switchOvers.first, tele > 1 else { return [] }
            return [CameraZoomOption(displayFactor: 1, deviceFactor: 1),
                    CameraZoomOption(displayFactor: tele, deviceFactor: tele)]
        default:
            return []
        }
    }
}

/// One capture. Completes exactly once, after `didFinishCaptureFor` (repeated callbacks are ignored).
private final class PhotoCaptureProcessor: NSObject, AVCapturePhotoCaptureDelegate {
    private let format: ImageFormat
    private let completion: (Result<CapturedPhoto, Error>) -> Void
    private var data: Data?
    private var error: Error?
    private var completed = false

    init(format: ImageFormat, completion: @escaping (Result<CapturedPhoto, Error>) -> Void) {
        self.format = format
        self.completion = completion
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        if let error {
            self.error = error
            return
        }
        if data == nil { data = photo.fileDataRepresentation() }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
        guard !completed else { return }
        completed = true
        if let data, error == nil, self.error == nil {
            completion(.success(CapturedPhoto(data: data, format: format)))
        } else {
            completion(.failure(AppError(.captureFailed)))
        }
    }
}
