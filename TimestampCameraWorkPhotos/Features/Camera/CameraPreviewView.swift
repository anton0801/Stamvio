import AVFoundation
import SwiftUI
import UIKit

/// AVCaptureVideoPreviewLayer host. Shows the whole 3:4 frame (aspect fit) and reports taps for focus.
struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession
    let onLayer: (AVCaptureVideoPreviewLayer) -> Void
    let onTap: (_ devicePoint: CGPoint, _ layerPoint: CGPoint) -> Void

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspect
        view.backgroundColor = .black
        view.onTap = onTap
        view.isAccessibilityElement = true
        view.accessibilityLabel = L("camera.preview.a11y")
        view.accessibilityHint = L("camera.preview.hint")
        DispatchQueue.main.async { onLayer(view.previewLayer) }
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        uiView.onTap = onTap
        if uiView.previewLayer.session !== session { uiView.previewLayer.session = session }
    }

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        // swiftlint:disable:next force_cast
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
        var onTap: ((CGPoint, CGPoint) -> Void)?

        override init(frame: CGRect) {
            super.init(frame: frame)
            addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(handleTap(_:))))
        }

        required init?(coder: NSCoder) {
            super.init(coder: coder)
            addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(handleTap(_:))))
        }

        @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
            let point = recognizer.location(in: self)
            let devicePoint = previewLayer.captureDevicePointConverted(fromLayerPoint: point)
            onTap?(devicePoint, point)
        }
    }
}
