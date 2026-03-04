//
//  CameraPreviewView.swift
//  PropelWalk
//

import SwiftUI
import AVFoundation
import UIKit

/// Full-screen camera preview that does NOT block touches.
///  FIXED:
/// - Prevents sideways preview rotation.
/// - Allows ONLY Portrait + Portrait Upside Down.
/// - Uses iOS 17 rotationAngle correctly (Portrait = 90°, UpsideDown = 270°).
struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PropelCameraPreviewUIView {
        let view = PropelCameraPreviewUIView()
        view.isUserInteractionEnabled = false
        view.attachSessionIfNeeded(session)
        return view
    }

    func updateUIView(_ uiView: PropelCameraPreviewUIView, context: Context) {
        uiView.attachSessionIfNeeded(session)
        uiView.updateOrientation()
    }
}

final class PropelCameraPreviewUIView: UIView {

    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

    private var previewLayer: AVCaptureVideoPreviewLayer {
        layer as! AVCaptureVideoPreviewLayer
    }

    private var attachedSessionID: ObjectIdentifier?

    override init(frame: CGRect) {
        super.init(frame: frame)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    private func commonInit() {
        previewLayer.videoGravity = .resizeAspectFill
        isOpaque = true
        backgroundColor = .black

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleRefresh),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleRefresh),
            name: UIDevice.orientationDidChangeNotification,
            object: nil
        )
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        DispatchQueue.main.async { [weak self] in
            self?.updateOrientation()
        }
    }

    func attachSessionIfNeeded(_ session: AVCaptureSession) {
        let newID = ObjectIdentifier(session)
        guard attachedSessionID != newID else { return }

        attachedSessionID = newID
        previewLayer.session = session

        DispatchQueue.main.async { [weak self] in
            self?.updateOrientation()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        previewLayer.frame = bounds
        updateOrientation()
    }

    @objc private func handleRefresh() {
        DispatchQueue.main.async { [weak self] in
            self?.updateOrientation()
        }
    }

    ///  Keep ONLY portrait + upside down. Never allow sideways preview.
    func updateOrientation() {
        guard let connection = previewLayer.connection else { return }

        let raw = window?.windowScene?.interfaceOrientation ?? .portrait
        let safe = clampToPortraitModes(raw)

        if #available(iOS 17.0, *) {
            let angle = rotationAngle(for: safe)
            if connection.isVideoRotationAngleSupported(angle) {
                connection.videoRotationAngle = angle
            } else if connection.isVideoOrientationSupported {
                connection.videoOrientation = videoOrientation(for: safe)
            }
        } else {
            if connection.isVideoOrientationSupported {
                connection.videoOrientation = videoOrientation(for: safe)
            }
        }

        // Back camera should NOT be mirrored
        if connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = false
        }
    }

    /// If iOS reports landscape, force portrait so preview never rotates sideways.
    private func clampToPortraitModes(_ o: UIInterfaceOrientation) -> UIInterfaceOrientation {
        switch o {
        case .portraitUpsideDown:
            return .portraitUpsideDown
        case .portrait:
            return .portrait
        case .landscapeLeft, .landscapeRight:
            return .portrait
        default:
            return .portrait
        }
    }

    private func videoOrientation(for interfaceOrientation: UIInterfaceOrientation) -> AVCaptureVideoOrientation {
        switch interfaceOrientation {
        case .portraitUpsideDown:
            return .portraitUpsideDown
        default:
            return .portrait
        }
    }

    @available(iOS 17.0, *)
    private func rotationAngle(for interfaceOrientation: UIInterfaceOrientation) -> CGFloat {
        //  Correct angles for AVCapture preview:
        // Portrait = 90, UpsideDown = 270
        switch interfaceOrientation {
        case .portraitUpsideDown:
            return 270
        default:
            return 90
        }
    }
}
