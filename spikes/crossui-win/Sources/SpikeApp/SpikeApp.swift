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

/// Phase B-lite: a stand-in for TaskWindowKit's actor view models —
/// same shape (actor with async verbs and read-back state), none of
/// the root package graph. The R16 probe is whether swift-cross-ui's
/// action closures can hop to an actor and publish the result back
/// into view state the way the real shells will need to.
actor CounterViewModel {
    private(set) var value = 0

    func increment() async -> Int {
        value += 1
        return value
    }
}

@main
struct SpikeApp: App {
    let viewModel = CounterViewModel()
    @State var count = 0

    var body: some Scene {
        WindowGroup("Sprig × swift-cross-ui spike") {
            VStack {
                Text("If you can read this, phase A is done.")
                Button("Actor taps: \(count)") {
                    Task {
                        count = await viewModel.increment()
                    }
                }
            }
            .padding(20)
        }
    }
}
