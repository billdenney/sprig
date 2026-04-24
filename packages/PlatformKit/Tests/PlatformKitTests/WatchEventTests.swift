import Foundation
@testable import PlatformKit
import Testing

@Suite("WatchEvent + WatchEventKind")
struct WatchEventTests {
    @Test("WatchEvent is Hashable and equates on (path, kind, timestamp)")
    func eventHashable() {
        let t = Date(timeIntervalSince1970: 100)
        let a = WatchEvent(path: URL(fileURLWithPath: "/x"), kind: .modified, timestamp: t)
        let b = WatchEvent(path: URL(fileURLWithPath: "/x"), kind: .modified, timestamp: t)
        let c = WatchEvent(path: URL(fileURLWithPath: "/y"), kind: .modified, timestamp: t)
        #expect(a == b)
        #expect(a != c)
        #expect(Set([a, b, c]).count == 2)
    }

    @Test("priority ordering: overflow > removed > renamed > created > modified > unknown")
    func priorityOrder() {
        let ordered: [WatchEventKind] = [.unknown, .modified, .created, .renamed, .removed, .overflow]
        let priorities = ordered.map(\.priority)
        #expect(priorities == priorities.sorted())
        // strictly increasing
        for pair in zip(priorities, priorities.dropFirst()) {
            #expect(pair.0 < pair.1)
        }
    }

    @Test("all kinds have distinct priority values")
    func prioritiesAreDistinct() {
        let all = WatchEventKind.allCases.map(\.priority)
        #expect(Set(all).count == all.count)
    }
}
