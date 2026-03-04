//
//  VisionManager.swift
//  Propel
//

import Foundation
import Vision
import AVFoundation
import ImageIO
import QuartzCore //  needed for CACurrentMediaTime()

// MARK: - Swift 6 Sendable Box for CVPixelBuffer
final class PixelBufferBox: @unchecked Sendable {
    let value: CVPixelBuffer
    init(_ value: CVPixelBuffer) { self.value = value }
}

/// Runs Vision work off-main, publishes results back on main.
///
///  Improvements in this version:
/// - Faster responsiveness (separate Scan/OCR throttles)
/// - Danger escalates immediately (no delay for Near/VeryClose)
/// - Calming down is stabilized (prevents bouncing)
/// - One unified "best obstacle" output per frame
/// - Central ROI obstacle definition + floor rejection
/// - OCR stability: publishes only when stable OR meaningful change
final class VisionManager: ObservableObject, @unchecked Sendable {
    
    // MARK: - Outputs (called on main)
    var onObstacleDetected: ((Float, ObstacleSeverity) -> Void)?
    var onTextRecognized: ((String) -> Void)?
    
    // MARK: - Internals
    private let visionQueue = DispatchQueue(label: "propel.vision.manager", qos: .userInitiated)
    
    // Separate throttles for speed/feel
    private var lastScanProcessedTime: CFTimeInterval = 0
    private var lastOCRProcessedTime: CFTimeInterval = 0
    
    /// Scan Space should feel fast (≈ 8–12 fps)
    private let scanProcessingInterval: CFTimeInterval = 0.10
    
    /// OCR can be slower (≈ 4–6 fps) to reduce chatter + CPU
    private let ocrProcessingInterval: CFTimeInterval = 0.20
    
    //  Typical for AVCaptureVideoDataOutput portrait/back camera frames
    private let visionOrientation: CGImagePropertyOrientation = .right
    
    // Central ROI for obstacle detection (normalized Vision coords: origin bottom-left)
    private let obstacleROI = CGRect(x: 0.22, y: 0.22, width: 0.56, height: 0.60)
    
    //  Minimum meaningful obstacle size (tiny boxes are noise)
    private let minObstacleArea: CGFloat = 0.06
    
    //  Floor rejection (Vision coords: y=0 bottom)
    private let floorMaxMidY: CGFloat = 0.28
    private let floorMinArea: CGFloat = 0.35
    private let floorMinWidth: CGFloat = 0.75
    
    // ROI overlap requirement (portion of the candidate inside ROI)
    private let minOverlapRatioInsideROI: CGFloat = 0.30
    
    // MARK: - Stability (anti-jitter) — visionQueue only
    
    private var lastVisionSeverity: ObstacleSeverity = .clear
    private var calmDownStableCount: Int = 0
    
    /// Only used when severity is DECREASING (near→far→clear)
    private let requiredStableFramesForCalmDown: Int = 2
    
    /// Optional: call when switching modes to reset stability
    func resetVisionStability() {
        visionQueue.async { [weak self] in
            guard let self else { return }
            self.lastVisionSeverity = .clear
            self.calmDownStableCount = 0
            self.resetOCRStability()
        }
    }
    
    /// Severity ranking: bigger = more dangerous
    private func rank(_ s: ObstacleSeverity) -> Int {
        switch s {
        case .clear:     return 0
        case .far:       return 1
        case .near:      return 2
        case .veryClose: return 3
        case .uncertain: return 1 // treat as "far-ish" (not panic)
        }
    }
    
    ///  Fast + stable logic:
    /// - If danger increases: apply immediately (no delay)
    /// - If danger decreases: require stability frames (prevents bouncing)
    private func stabilizedSeverity(_ newSeverity: ObstacleSeverity) -> ObstacleSeverity {
        
        // If same => reset calm-down counter
        if newSeverity == lastVisionSeverity {
            calmDownStableCount = 0
            return newSeverity
        }
        
        let oldRank = rank(lastVisionSeverity)
        let newRank = rank(newSeverity)
        
        if newRank > oldRank {
            //  Escalation: immediate
            lastVisionSeverity = newSeverity
            calmDownStableCount = 0
            return newSeverity
        }
        
        //  Calm-down: require stability
        calmDownStableCount += 1
        if calmDownStableCount >= requiredStableFramesForCalmDown {
            lastVisionSeverity = newSeverity
            calmDownStableCount = 0
        }
        
        return lastVisionSeverity
    }
    
    // MARK: - OCR stability (visionQueue only)
    
    private var lastPublishedOCR: String = ""
    private var ocrStableCount: Int = 0
    private let requiredOCRStableFrames: Int = 2
    
    private func resetOCRStability() {
        lastPublishedOCR = ""
        ocrStableCount = 0
    }
    
    private func shouldPublishOCR(_ text: String) -> Bool {
        // Publish immediately if first time
        if lastPublishedOCR.isEmpty {
            lastPublishedOCR = text
            ocrStableCount = 0
            return true
        }
        
        if text == lastPublishedOCR {
            // Same as last published, skip (prevents repeats)
            return false
        }
        
        // If very similar to last published, require stability a few frames
        let sim = similarity(lastPublishedOCR, text)
        if sim >= 0.90 {
            ocrStableCount += 1
            if ocrStableCount >= requiredOCRStableFrames {
                lastPublishedOCR = text
                ocrStableCount = 0
                return true
            }
            return false
        } else {
            // Big change: publish immediately (new label/object)
            lastPublishedOCR = text
            ocrStableCount = 0
            return true
        }
    }
    
    // MARK: - Public API
    
    func processFrame(_ pixelBuffer: CVPixelBuffer, mode: AppMode) {
        // Swift 6 fix: do NOT capture CVPixelBuffer directly inside @Sendable closure
        let box = PixelBufferBox(pixelBuffer)
        
        visionQueue.async { [weak self, box] in
            guard let self else { return }
            
            let now = CACurrentMediaTime()
            
            switch mode {
            case .scanSpace:
                guard now - self.lastScanProcessedTime >= self.scanProcessingInterval else { return }
                self.lastScanProcessedTime = now
                self.detectObstacles(in: box.value)
                
            case .readLabel:
                guard now - self.lastOCRProcessedTime >= self.ocrProcessingInterval else { return }
                self.lastOCRProcessedTime = now
                self.recognizeText(in: box.value)
            }
        }
    }
    
    func publishObstacle(distance: Float, severity: ObstacleSeverity) {
        DispatchQueue.main.async { [weak self] in
            self?.onObstacleDetected?(distance, severity)
        }
    }
    
    // MARK: - Vision-only obstacle detection (visionQueue only)
    
    func detectObstacles(in pixelBuffer: CVPixelBuffer) {
        
        var candidateBoxes: [CGRect] = []
        
        let saliencyRequest = VNGenerateAttentionBasedSaliencyImageRequest { request, error in
            if let error {
                print("Saliency detection error: \(error)")
                return
            }
            
            guard let results = request.results as? [VNSaliencyImageObservation],
                  let observation = results.first,
                  let salientObjects = observation.salientObjects,
                  !salientObjects.isEmpty else {
                return
            }
            
            for obj in salientObjects {
                candidateBoxes.append(obj.boundingBox)
            }
        }
        
        let rectangleRequest = VNDetectRectanglesRequest { request, error in
            if let error {
                print("Rectangle detection error: \(error)")
                return
            }
            guard let rectangles = request.results as? [VNRectangleObservation], !rectangles.isEmpty else { return }
            for r in rectangles {
                candidateBoxes.append(r.boundingBox)
            }
        }
        
        rectangleRequest.minimumAspectRatio = 0.3
        rectangleRequest.maximumAspectRatio = 1.0
        rectangleRequest.minimumSize = 0.18
        
        let handler = VNImageRequestHandler(
            cvPixelBuffer: pixelBuffer,
            orientation: visionOrientation,
            options: [:]
        )
        
        do {
            try handler.perform([saliencyRequest, rectangleRequest])
            evaluateAndPublishBestObstacle(from: candidateBoxes)
        } catch {
            print("Vision request error: \(error)")
            publishObstacle(distance: 0, severity: .uncertain)
        }
    }
    
    private func evaluateAndPublishBestObstacle(from boxes: [CGRect]) {
        
        let valid = boxes.filter { isValidObstacleCandidate($0) }
        
        guard !valid.isEmpty else {
            let stable = stabilizedSeverity(.clear)
            publishObstacle(distance: 5.0, severity: stable)
            return
        }
        
        let roiCenter = CGPoint(x: obstacleROI.midX, y: obstacleROI.midY)
        
        func score(_ box: CGRect) -> CGFloat {
            let area = box.width * box.height
            let overlap = box.intersection(obstacleROI)
            let overlapArea = max(0, overlap.width * overlap.height)
            let overlapRatio = overlapArea / max(area, 0.0001)
            
            let d = distance(box.center, roiCenter)
            let centerFactor = max(0.0, 1.0 - d)
            
            return overlapRatio * 0.75 + centerFactor * 0.25
        }
        
        guard let best = valid.max(by: { score($0) < score($1) }) else {
            let stable = stabilizedSeverity(.clear)
            publishObstacle(distance: 5.0, severity: stable)
            return
        }
        
        let estimatedDistance = estimateDistance(from: best)
        let rawSeverity = determineSeverity(distance: estimatedDistance)
        let stableSeverity = stabilizedSeverity(rawSeverity)
        
        publishObstacle(distance: estimatedDistance, severity: stableSeverity)
    }
    
    // MARK: - OCR / Read Label (visionQueue only)
    
    func recognizeText(in pixelBuffer: CVPixelBuffer) {
        
        let request = VNRecognizeTextRequest { [weak self] request, error in
            guard let self else { return }
            if let error {
                print("Text recognition error: \(error)")
                return
            }
            
            guard let observations = request.results as? [VNRecognizedTextObservation] else { return }
            
            let filtered = observations.filter { obs in
                let box = obs.boundingBox
                let area = box.width * box.height
                return area >= 0.012 && box.height >= 0.03
            }
            
            let strings = filtered.compactMap { $0.topCandidates(1).first?.string }
            let fullText = strings.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            
            guard !fullText.isEmpty else { return }
            
            let shouldPublish = self.shouldPublishOCR(fullText)
            guard shouldPublish else { return }
            
            DispatchQueue.main.async { [weak self] in
                self?.onTextRecognized?(fullText)
            }
        }
        
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.regionOfInterest = CGRect(x: 0.10, y: 0.18, width: 0.80, height: 0.72)
        
        let handler = VNImageRequestHandler(
            cvPixelBuffer: pixelBuffer,
            orientation: visionOrientation,
            options: [:]
        )
        
        do {
            try handler.perform([request])
        } catch {
            print("Text recognition handler error: \(error)")
        }
    }
    
    // MARK: - Obstacle rules
    
    private func isValidObstacleCandidate(_ box: CGRect) -> Bool {
        
        let area = box.width * box.height
        guard area >= minObstacleArea else { return false }
        
        if isLikelyFloor(box) { return false }
        
        let overlap = box.intersection(obstacleROI)
        guard !overlap.isNull else { return false }
        
        let overlapArea = overlap.width * overlap.height
        let overlapRatio = overlapArea / max(area, 0.0001)
        
        guard overlapRatio >= minOverlapRatioInsideROI else { return false }
        return true
    }
    
    private func isLikelyFloor(_ box: CGRect) -> Bool {
        let area = box.width * box.height
        return (box.midY <= floorMaxMidY) &&
        (area >= floorMinArea) &&
        (box.width >= floorMinWidth)
    }
    
    // MARK: - Distance estimation
    
    private func estimateDistance(from box: CGRect) -> Float {
        
        let area = box.width * box.height
        let yPos = box.midY
        
        var distance: Float = 5.0
        if area > 0.55 { distance = 0.35 }
        else if area > 0.35 { distance = 0.9 }
        else if area > 0.18 { distance = 1.8 }
        else if area > 0.10 { distance = 2.7 }
        else { distance = 3.8 }
        
        let verticalFactor = Float(yPos)
        distance *= (1.0 + (verticalFactor - 0.5) * 0.6)
        
        return max(0.25, min(distance, 5.0))
    }
    
    func determineSeverity(distance: Float) -> ObstacleSeverity {
        switch distance {
        case 0..<0.5:   return .veryClose
        case 0.5..<1.5: return .near
        case 1.5..<3.0: return .far
        default:        return .clear
        }
    }
    
    // MARK: - Helpers
    
    private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = a.x - b.x
        let dy = a.y - b.y
        return sqrt(dx * dx + dy * dy)
    }
    
    private func similarity(_ a: String, _ b: String) -> Double {
        let setA = Set(a.lowercased())
        let setB = Set(b.lowercased())
        let union = setA.union(setB).count
        guard union > 0 else { return 0 }
        let inter = setA.intersection(setB).count
        return Double(inter) / Double(union)
    }
}

private extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}
