// SpikeApp.swift — R1/R16 spike, phase A.
//
// The smallest possible swift-cross-ui app: one window, one label,
// one stateful button. Phase A's question is purely "does this
// RESOLVE + BUILD on the Windows snapshot toolchain" (DefaultBackend
// → WinUIBackend there); launching it interactively is a bonus.
// Phase B (separate commit, only if A builds) binds a real
// TaskWindowKit actor view model to probe the R16 ergonomics.

import DefaultBackend
import SwiftCrossUI

@main
struct SpikeApp: App {
    @State var count = 0

    var body: some Scene {
        WindowGroup("Sprig × swift-cross-ui spike") {
            VStack {
                Text("If you can read this, phase A is done.")
                Button("Taps: \(count)") {
                    count += 1
                }
            }
            .padding(20)
        }
    }
}
