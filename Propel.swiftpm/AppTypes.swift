import Foundation

// MARK: - Scan State (UI state)
enum ScanState: Equatable {
    case clear
    case caution
    case stop
}

// MARK: - App Mode (UI mode)
enum AppMode: Equatable {
    case scanSpace
    case readLabel
}

// MARK: - Obstacle Severity (from Vision/LiDAR)
enum ObstacleSeverity: Equatable {
    case clear
    case far
    case near
    case veryClose
    case uncertain
}
