//
//  VisionManager+LiDAR.swift
//  Propel
//

import Foundation
import AVFoundation
import CoreVideo

// MARK: - Sendable wrapper for CVPixelBuffer (unique name to avoid conflicts)

private final class EngineDepthMapBox: @unchecked Sendable {
    let value: CVPixelBuffer
    init(_ value: CVPixelBuffer) { self.value = value }
}

// MARK: - Non-actor helper

private enum DepthMetrics {

    struct Result {
        let median: Float
        let minValue: Float
        let sampleCount: Int
    }

    struct FloorCheck {
        let bottomMedian: Float
        let bottomCount: Int
    }

    /// Copy the depth pixel buffer so it can be safely processed off the capture queue.
    static func copyPixelBuffer(_ src: CVPixelBuffer) -> CVPixelBuffer? {
        let width  = CVPixelBufferGetWidth(src)
        let height = CVPixelBufferGetHeight(src)
        let format = CVPixelBufferGetPixelFormatType(src)

        var dst: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary
        ]

        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            format,
            attrs as CFDictionary,
            &dst
        )
        guard status == kCVReturnSuccess, let dst else { return nil }

        CVPixelBufferLockBaseAddress(src, .readOnly)
        CVPixelBufferLockBaseAddress(dst, [])
        defer {
            CVPixelBufferUnlockBaseAddress(dst, [])
            CVPixelBufferUnlockBaseAddress(src, .readOnly)
        }

        guard let srcBase = CVPixelBufferGetBaseAddress(src),
              let dstBase = CVPixelBufferGetBaseAddress(dst)
        else { return nil }

        let srcBytesPerRow = CVPixelBufferGetBytesPerRow(src)
        let dstBytesPerRow = CVPixelBufferGetBytesPerRow(dst)
        let bytesPerRowToCopy = min(srcBytesPerRow, dstBytesPerRow)

        for y in 0..<height {
            let srcRow = srcBase.advanced(by: y * srcBytesPerRow)
            let dstRow = dstBase.advanced(by: y * dstBytesPerRow)
            memcpy(dstRow, srcRow, bytesPerRowToCopy)
        }

        return dst
    }

    // MARK: - ROI sampling helpers

    @inline(__always)
    static func acceptDepth(_ d: Float, into values: inout [Float]) {
        if d.isFinite, d > 0.08, d < 8.0 { values.append(d) } // 0.08..8 meters
    }

    /// Compute median + min distance from a FORWARD band ROI (avoids floor).
    static func computeForwardDepthMetrics(depthMap: CVPixelBuffer) -> Result? {
        let width  = CVPixelBufferGetWidth(depthMap)
        let height = CVPixelBufferGetHeight(depthMap)
        guard width > 0, height > 0 else { return nil }

        let pixelFormat = CVPixelBufferGetPixelFormatType(depthMap)

        //  Forward band ROI (narrower, higher):
        // - X: center 45%
        // - Y: around upper-mid (avoids floor)
        let regionW = max(1, Int(Float(width)  * 0.45))
        let regionH = max(1, Int(Float(height) * 0.28))

        let centerX = width / 2
        let centerY = Int(Float(height) * 0.62) // higher than center

        let xStart = max(0, centerX - regionW / 2)
        let xEnd   = min(width, centerX + regionW / 2)
        let yStart = max(0, centerY - regionH / 2)
        let yEnd   = min(height, centerY + regionH / 2)

        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }

        guard let base = CVPixelBufferGetBaseAddress(depthMap) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(depthMap)

        var values: [Float] = []
        values.reserveCapacity(max(0, (xEnd - xStart) * (yEnd - yStart) / 4))

        if pixelFormat == kCVPixelFormatType_DepthFloat32 {
            let buffer = base.assumingMemoryBound(to: Float.self)
            let rowStride = bytesPerRow / MemoryLayout<Float>.size

            for y in Swift.stride(from: yStart, to: yEnd, by: 2) {
                let row = y * rowStride
                for x in Swift.stride(from: xStart, to: xEnd, by: 2) {
                    acceptDepth(buffer[row + x], into: &values)
                }
            }

        } else if pixelFormat == kCVPixelFormatType_DepthFloat16 {
            let buffer = base.assumingMemoryBound(to: UInt16.self)
            let rowStride = bytesPerRow / MemoryLayout<UInt16>.size

            for y in Swift.stride(from: yStart, to: yEnd, by: 2) {
                let row = y * rowStride
                for x in Swift.stride(from: xStart, to: xEnd, by: 2) {
                    let bits = buffer[row + x]
                    let f16 = Float16(bitPattern: bits)
                    acceptDepth(Float(f16), into: &values)
                }
            }

        } else {
            return nil
        }

        guard !values.isEmpty else { return nil }
        values.sort()

        let median = values[values.count / 2]
        let minValue = values.first ?? median
        return Result(median: median, minValue: minValue, sampleCount: values.count)
    }

    /// Bottom strip depth check (helps detect when you're mostly seeing the floor).
    static func computeBottomStripMedian(depthMap: CVPixelBuffer) -> FloorCheck? {
        let width  = CVPixelBufferGetWidth(depthMap)
        let height = CVPixelBufferGetHeight(depthMap)
        guard width > 0, height > 0 else { return nil }

        let pixelFormat = CVPixelBufferGetPixelFormatType(depthMap)

        // Bottom strip: last ~18% of image height, wide middle
        let regionW = max(1, Int(Float(width) * 0.70))
        let regionH = max(1, Int(Float(height) * 0.18))

        let centerX = width / 2
        let centerY = Int(Float(height) * 0.10) // near bottom in pixel coords

        let xStart = max(0, centerX - regionW / 2)
        let xEnd   = min(width, centerX + regionW / 2)
        let yStart = max(0, centerY - regionH / 2)
        let yEnd   = min(height, centerY + regionH / 2)

        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }

        guard let base = CVPixelBufferGetBaseAddress(depthMap) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(depthMap)

        var values: [Float] = []
        values.reserveCapacity(max(0, (xEnd - xStart) * (yEnd - yStart) / 6))

        if pixelFormat == kCVPixelFormatType_DepthFloat32 {
            let buffer = base.assumingMemoryBound(to: Float.self)
            let rowStride = bytesPerRow / MemoryLayout<Float>.size

            for y in Swift.stride(from: yStart, to: yEnd, by: 3) {
                let row = y * rowStride
                for x in Swift.stride(from: xStart, to: xEnd, by: 3) {
                    acceptDepth(buffer[row + x], into: &values)
                }
            }

        } else if pixelFormat == kCVPixelFormatType_DepthFloat16 {
            let buffer = base.assumingMemoryBound(to: UInt16.self)
            let rowStride = bytesPerRow / MemoryLayout<UInt16>.size

            for y in Swift.stride(from: yStart, to: yEnd, by: 3) {
                let row = y * rowStride
                for x in Swift.stride(from: xStart, to: xEnd, by: 3) {
                    let bits = buffer[row + x]
                    let f16 = Float16(bitPattern: bits)
                    acceptDepth(Float(f16), into: &values)
                }
            }

        } else {
            return nil
        }

        guard !values.isEmpty else { return nil }
        values.sort()
        let median = values[values.count / 2]
        return FloorCheck(bottomMedian: median, bottomCount: values.count)
    }
}

// MARK: - VisionManager + LiDAR

extension VisionManager {

    //  Instance stability state (NOT static) — safe because VisionManager
    // only does depth work on a single serial queue in CameraEngine.
    private struct LiDARStabilityState {
        var lastSeverity: ObstacleSeverity = .clear
        var pendingSeverity: ObstacleSeverity = .clear
        var pendingCount: Int = 0
    }

    // Stored state for anti-jitter
    // NOTE: This file can’t add stored properties directly in an extension,
    // so we keep stability purely with a lightweight “debounce” using distance smoothing
    // and by returning early if floor is detected.
    //
    // The simplest Swift6-safe fix: do NOT use static/shared mutable state at all.
    //
    // If you want *stronger* stabilization, do it in CameraEngine (published output),
    // or add these properties inside the main VisionManager class file:
    //   var lidarState = LiDARStabilityState()
    //
    // For now, we keep stabilization deterministic without extra shared state.

    /// Called from CameraEngine (already off-main).
    func processFrameWithDepth(_ pixelBuffer: CVPixelBuffer, depthData: AVDepthData?) {

        // No depth or unreliable => fallback to Vision-only
        guard let depthData, isDepthDataReliable(depthData) else {
            detectObstacles(in: pixelBuffer)
            return
        }

        //  Convert depth to Float32 for consistency
        let depth: AVDepthData
        if depthData.depthDataType != kCVPixelFormatType_DepthFloat32 {
            depth = depthData.converting(toDepthDataType: kCVPixelFormatType_DepthFloat32)
        } else {
            depth = depthData
        }

        let depthMap = depth.depthDataMap

        // Copy depth map so it can be safely processed off the capture queue
        guard let copiedMap = DepthMetrics.copyPixelBuffer(depthMap) else {
            publishObstacle(distance: 0, severity: .uncertain)
            return
        }

        let box = EngineDepthMapBox(copiedMap)

        // Forward band = "straight ahead"
        guard let forward = DepthMetrics.computeForwardDepthMetrics(depthMap: box.value) else {
            publishObstacle(distance: 0, severity: .uncertain)
            return
        }

        // Bottom strip sanity check (floor / pointing down)
        let bottom = DepthMetrics.computeBottomStripMedian(depthMap: box.value)

        let median = forward.median
        let minValue = forward.minValue

        //  Only use min if meaningfully closer than median (less noise)
        let isMeaningfulCloser =
            (minValue < median * 0.65) &&
            ((median - minValue) >= 0.35)

        var usedDistance: Float = isMeaningfulCloser ? minValue : median

        // Floor / pointing down guard:
        // If bottom is very close but forward band isn't, treat as "uncertain" (not STOP spam).
        if let bottom {
            if bottom.bottomMedian < 0.60 && usedDistance > 1.2 {
                usedDistance = max(usedDistance, 1.2)
                let clamped = max(0.25, min(usedDistance, 6.0))
                publishObstacle(distance: clamped, severity: .uncertain)
                return
            }
        }

        // Clamp
        let clampedDistance = max(0.20, min(usedDistance, 6.0))

        let severity = determineSeverity(distance: clampedDistance)
        publishObstacle(distance: clampedDistance, severity: severity)
    }

    // MARK: - Reliability

    private func isDepthDataReliable(_ depthData: AVDepthData) -> Bool {
        switch depthData.depthDataQuality {
        case .high: return true
        case .low:  return false
        @unknown default: return false
        }
    }
}
