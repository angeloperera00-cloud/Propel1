//
//  CameraEngine.swift
//  PropelWalk
//

@preconcurrency import AVFoundation
import CoreVideo
import Foundation
import SwiftUI
import QuartzCore   // CACurrentMediaTime()
import UIKit

// MARK: - Sendable Boxes (Swift 6)

final class EnginePixelBufferBox: @unchecked Sendable {
    let value: CVPixelBuffer
    init(_ value: CVPixelBuffer) { self.value = value }
}

final class EngineDepthDataBox: @unchecked Sendable {
    let value: AVDepthData
    init(_ value: AVDepthData) { self.value = value }
}

// MARK: - CameraEngine

final class CameraEngine: NSObject,
                          ObservableObject,
                          AVCaptureVideoDataOutputSampleBufferDelegate,
                          AVCaptureDepthDataOutputDelegate,
                          @unchecked Sendable {

    // Published (UI reads on main)
    @Published var scanState: ScanState = .clear
    @Published var recognizedText: String = ""
    @Published var mode: AppMode = .scanSpace

    @Published var obstacleDistanceMeters: Float = 0
    @Published var obstacleSeverity: ObstacleSeverity? = nil

    // Preview attaches to this
    let session = AVCaptureSession()

    // Queues (SERIAL)
    private let sessionQ = DispatchQueue(label: "propel.session", qos: .userInitiated)
    private let visionQ  = DispatchQueue(label: "propel.vision", qos: .userInitiated)

    // Outputs
    private let videoOutput = AVCaptureVideoDataOutput()
    private let depthOutput = AVCaptureDepthDataOutput()

    // Latest depth (ONLY touch on sessionQ)
    private var latestDepthData: AVDepthData?

    // MARK: - Frame Throttling (separate per mode)

    private var lastScanFrameTime: CFTimeInterval = 0
    private var lastOCRFrameTime: CFTimeInterval = 0

    private let scanFrameInterval: CFTimeInterval = 1.0 / 8.0   // 8 fps
    private let ocrFrameInterval: CFTimeInterval  = 1.0 / 3.0   // 3 fps

    // Session state
    private var didConfigureSession = false
    private var isConfiguringSession = false

    // Mode backing store (ONLY touch on sessionQ)
    private var modeValue: AppMode = .scanSpace

    // Vision manager
    private let visionManager = VisionManager()

    // MARK: - OCR Publish Control

    private var nextAllowedOCRPublishTime: CFTimeInterval = 0
    private let ocrPublishCooldown: CFTimeInterval = 0.6

    private var lastPublishedOCR: String = ""
    private let minOCRChangeRatioToPublish: Double = 0.12

    // MARK: - Torch / Auto Light

    private var videoDevice: AVCaptureDevice?
    private var torchEnabled: Bool = false
    private var autoTorchEnabled: Bool = true

    private let torchOnLuma: Float = 0.14
    private let torchOffLuma: Float = 0.55

    private var lastTorchEvalTime: CFTimeInterval = 0
    private let torchEvalInterval: CFTimeInterval = 0.35

    private var darkCount: Int = 0
    private var brightCount: Int = 0
    private let requiredStableCounts: Int = 4

    private var lastTorchToggleTime: CFTimeInterval = 0
    private let minTorchOnDuration: CFTimeInterval = 4.0
    private let minTorchOffDuration: CFTimeInterval = 1.5

    // MARK: - Orientation ( FIXED)

    /// Cached interface orientation. Only portrait / upside-down are used.
    /// Landscape is ignored.
    private var cachedInterfaceOrientation: UIInterfaceOrientation = .portrait

    // MARK: - Init / Deinit

    override init() {
        super.init()

        // App active → refresh orientation + connections
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppBecameActive),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )

        // Obstacle callbacks
        visionManager.onObstacleDetected = { [weak self] distance, severity in
            guard let self else { return }
            DispatchQueue.main.async {
                self.obstacleDistanceMeters = distance
                self.obstacleSeverity = severity
                self.scanState = Self.mapSeverityToScanState(severity)
            }
        }

        // OCR callbacks
        visionManager.onTextRecognized = { [weak self] text in
            guard let self else { return }
            self.sessionQ.async { [weak self] in
                guard let self else { return }
                self.handleOCRResult(text)
            }
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Public API

    func start() {
        requestPermissionThenBuild()
    }

    func stop() {
        sessionQ.async { [weak self] in
            guard let self else { return }
            self.setTorch(false)
            if self.session.isRunning {
                self.session.stopRunning()
            }
        }
    }

    func setMode(_ newMode: AppMode) {
        sessionQ.async { [weak self] in
            guard let self else { return }
            self.modeValue = newMode

            self.nextAllowedOCRPublishTime = 0
            self.lastPublishedOCR = ""
            self.lastOCRFrameTime = 0
            self.lastScanFrameTime = 0

            self.visionManager.resetVisionStability()
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.mode = newMode
            self.scanState = .clear
            self.recognizedText = ""
            self.obstacleDistanceMeters = 0
            self.obstacleSeverity = nil
        }
    }

    func setAutoTorchEnabled(_ enabled: Bool) {
        sessionQ.async { [weak self] in
            guard let self else { return }
            self.autoTorchEnabled = enabled
            self.darkCount = 0
            self.brightCount = 0
            if !enabled { self.setTorch(false) }
        }
    }

    ///  Main-thread-safe way to update capture orientation.
    /// Call from UI onAppear AND when app becomes active.
    func updateInterfaceOrientationFromUI() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }

            let scenes = UIApplication.shared.connectedScenes
            let windowScene = scenes.compactMap { $0 as? UIWindowScene }.first
            let io = windowScene?.interfaceOrientation ?? .portrait

            // Ignore sideways
            let lockedIO: UIInterfaceOrientation = (io == .portraitUpsideDown) ? .portraitUpsideDown : .portrait

            self.sessionQ.async { [weak self] in
                guard let self else { return }
                self.cachedInterfaceOrientation = lockedIO
                self.applyConnectionsOrientation()
            }
        }
    }

    // MARK: - Orientation refresh

    @objc private func handleAppBecameActive() {
        updateInterfaceOrientationFromUI()
    }

    /// Apply orientation to output connections.
    private func applyConnectionsOrientation() {
        let desired = desiredCaptureOrientation(from: cachedInterfaceOrientation)

        if let conn = videoOutput.connection(with: .video) {
            if conn.isVideoOrientationSupported {
                conn.videoOrientation = desired
            }
            if conn.isVideoMirroringSupported {
                conn.automaticallyAdjustsVideoMirroring = false
                conn.isVideoMirrored = false
            }
        }

        if let depthConn = depthOutput.connection(with: .depthData) {
            if depthConn.isVideoOrientationSupported {
                depthConn.videoOrientation = desired
            }
        }
    }

    private func desiredCaptureOrientation(from io: UIInterfaceOrientation) -> AVCaptureVideoOrientation {
        switch io {
        case .portraitUpsideDown:
            return .portraitUpsideDown
        default:
            return .portrait
        }
    }

    // MARK: - Permission + Setup

    private func requestPermissionThenBuild() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            sessionQ.async { [weak self] in self?.buildAndStartSession() }

        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                guard let self, granted else {
                    print("[CameraEngine] Camera permission denied.")
                    return
                }
                self.sessionQ.async { [weak self] in self?.buildAndStartSession() }
            }

        default:
            print("[CameraEngine] Camera permission denied.")
        }
    }

    private func buildAndStartSession() {
        guard !isConfiguringSession else { return }
        isConfiguringSession = true

        if didConfigureSession {
            //  refresh orientation safely
            updateInterfaceOrientationFromUI()
            if !session.isRunning { session.startRunning() }
            isConfiguringSession = false
            return
        }

        didConfigureSession = true

        session.beginConfiguration()

        session.inputs.forEach { session.removeInput($0) }
        session.outputs.forEach { session.removeOutput($0) }

        session.sessionPreset = .medium

        let device =
            AVCaptureDevice.default(.builtInLiDARDepthCamera, for: .video, position: .back)
            ?? AVCaptureDevice.default(.builtInDualWideCamera, for: .video, position: .back)
            ?? AVCaptureDevice.default(.builtInDualCamera, for: .video, position: .back)
            ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)

        guard let cam = device,
              let input = try? AVCaptureDeviceInput(device: cam),
              session.canAddInput(input) else {
            session.commitConfiguration()
            isConfiguringSession = false
            print("[CameraEngine] Failed to create input.")
            return
        }

        self.videoDevice = cam
        self.darkCount = 0
        self.brightCount = 0
        self.lastTorchToggleTime = 0
        self.torchEnabled = (cam.hasTorch && cam.torchMode != .off)

        session.addInput(input)

        // Video output
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String:
                kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        ]
        videoOutput.setSampleBufferDelegate(self, queue: sessionQ)

        guard session.canAddOutput(videoOutput) else {
            session.commitConfiguration()
            isConfiguringSession = false
            print("[CameraEngine] Cannot add video output.")
            return
        }
        session.addOutput(videoOutput)

        // Depth output if supported
        let supportsDepth = !cam.activeFormat.supportedDepthDataFormats.isEmpty
        if supportsDepth, session.canAddOutput(depthOutput) {
            depthOutput.isFilteringEnabled = true
            depthOutput.setDelegate(self, callbackQueue: sessionQ)
            session.addOutput(depthOutput)

            if let float32 = cam.activeFormat.supportedDepthDataFormats.first(where: {
                CMFormatDescriptionGetMediaSubType($0.formatDescription) == kCVPixelFormatType_DepthFloat32
            }) {
                do {
                    try cam.lockForConfiguration()
                    cam.activeDepthDataFormat = float32
                    cam.unlockForConfiguration()
                } catch {
                    print("[CameraEngine] Could not set depth format: \(error)")
                }
            }
        } else {
            latestDepthData = nil
        }

        session.commitConfiguration()
        isConfiguringSession = false

        // Start
        if !session.isRunning {
            session.startRunning()
        }

        //  After start, apply orientation safely
        updateInterfaceOrientationFromUI()
    }

    // MARK: - Delegates

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {

        let now = CACurrentMediaTime()
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        autoTorchIfNeeded(pixelBuffer: pb)

        let currentMode = modeValue

        switch currentMode {
        case .scanSpace:
            guard now - lastScanFrameTime >= scanFrameInterval else { return }
            lastScanFrameTime = now

            let pixelBox = EnginePixelBufferBox(pb)
            visionQ.async { [weak self, pixelBox] in
                guard let self else { return }
                self.visionManager.processFrame(pixelBox.value, mode: .scanSpace)
            }

        case .readLabel:
            guard now - lastOCRFrameTime >= ocrFrameInterval else { return }
            lastOCRFrameTime = now

            if now < nextAllowedOCRPublishTime { return }

            let pixelBox = EnginePixelBufferBox(pb)
            visionQ.async { [weak self, pixelBox] in
                guard let self else { return }
                self.visionManager.processFrame(pixelBox.value, mode: .readLabel)
            }
        }
    }

    func depthDataOutput(_ output: AVCaptureDepthDataOutput,
                         didOutput depthData: AVDepthData,
                         timestamp: CMTime,
                         connection: AVCaptureConnection) {

        let converted: AVDepthData
        if depthData.depthDataType != kCVPixelFormatType_DepthFloat32 {
            converted = depthData.converting(toDepthDataType: kCVPixelFormatType_DepthFloat32)
        } else {
            converted = depthData
        }
        latestDepthData = converted
    }

    // MARK: - OCR publish

    private func handleOCRResult(_ text: String) {
        let now = CACurrentMediaTime()

        guard modeValue == .readLabel else { return }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        guard now >= nextAllowedOCRPublishTime else { return }

        if !lastPublishedOCR.isEmpty {
            let change = changeRatio(from: lastPublishedOCR, to: trimmed)
            if change < minOCRChangeRatioToPublish { return }
        }

        lastPublishedOCR = trimmed
        nextAllowedOCRPublishTime = now + ocrPublishCooldown

        DispatchQueue.main.async { [weak self] in
            self?.recognizedText = trimmed
        }
    }

    private func changeRatio(from a: String, to b: String) -> Double {
        if a == b { return 0.0 }
        let setA = Set(a.lowercased())
        let setB = Set(b.lowercased())
        let union = setA.union(setB).count
        if union == 0 { return 0.0 }
        let inter = setA.intersection(setB).count
        return 1.0 - (Double(inter) / Double(union))
    }

    // MARK: - Torch Helpers

    private func setTorch(_ on: Bool) {
        guard let device = videoDevice, device.hasTorch else { return }
        if on == torchEnabled { return }

        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }

            if on {
                let level = min(1.0, AVCaptureDevice.maxAvailableTorchLevel)
                try device.setTorchModeOn(level: level)
                torchEnabled = true
            } else {
                device.torchMode = .off
                torchEnabled = false
            }
        } catch {
            print("[Torch] error: \(error)")
        }
    }

    private func estimateLuma(_ pixelBuffer: CVPixelBuffer) -> Float {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
        let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
        guard width > 0, height > 0 else { return 1.0 }

        guard let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) else { return 1.0 }
        let bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)

        let stepX = max(1, width / 20)
        let stepY = max(1, height / 20)

        let x0 = width / 4
        let x1 = (width * 3) / 4
        let y0 = height / 4
        let y1 = (height * 3) / 4

        var sum = 0
        var count = 0

        for y in stride(from: y0, to: y1, by: stepY) {
            let row = base.advanced(by: y * bytesPerRow).assumingMemoryBound(to: UInt8.self)
            for x in stride(from: x0, to: x1, by: stepX) {
                sum += Int(row[x])
                count += 1
            }
        }

        guard count > 0 else { return 1.0 }
        return (Float(sum) / Float(count)) / 255.0
    }

    private func autoTorchIfNeeded(pixelBuffer: CVPixelBuffer) {
        guard autoTorchEnabled else { return }
        guard (videoDevice?.hasTorch == true) else { return }

        let now = CACurrentMediaTime()
        guard now - lastTorchEvalTime >= torchEvalInterval else { return }
        lastTorchEvalTime = now

        let sinceToggle = now - lastTorchToggleTime
        if torchEnabled, sinceToggle < minTorchOnDuration { return }
        if !torchEnabled, sinceToggle < minTorchOffDuration { return }

        let luma = estimateLuma(pixelBuffer)

        if luma < torchOnLuma {
            darkCount += 1
            brightCount = 0
        } else if luma > torchOffLuma {
            brightCount += 1
            darkCount = 0
        } else {
            darkCount = max(0, darkCount - 1)
            brightCount = max(0, brightCount - 1)
            return
        }

        if !torchEnabled, darkCount >= requiredStableCounts {
            setTorch(true)
            lastTorchToggleTime = now
            darkCount = 0
            brightCount = 0
        } else if torchEnabled, brightCount >= requiredStableCounts {
            setTorch(false)
            lastTorchToggleTime = now
            darkCount = 0
            brightCount = 0
        }
    }

    // MARK: - Helpers

    private static func mapSeverityToScanState(_ severity: ObstacleSeverity) -> ScanState {
        switch severity {
        case .veryClose: return .stop
        case .near:      return .caution
        case .far, .clear, .uncertain:
            return .clear
        }
    }
}
