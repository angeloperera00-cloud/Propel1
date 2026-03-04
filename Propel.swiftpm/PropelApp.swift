import SwiftUI

@main
struct PropelApp: App {
    var body: some Scene {
        WindowGroup {
            ScannerView(
                onBack: { },          // not used now (no back button)
                initialMode: .scanSpace
            )
        }
    }
}
