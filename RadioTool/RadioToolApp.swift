import SwiftUI

@main
struct RadioToolApp: App {
    var body: some Scene {
        WindowGroup {
            LibraryView()
                #if os(macOS)
                .frame(minWidth: 900, minHeight: 560)
                #endif
        }
        #if os(macOS)
        .defaultSize(width: 1100, height: 700)
        #endif
    }
}
