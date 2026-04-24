import Testing
@testable import WatcherKit

@Test func `module name is set`() {
    #expect(WatcherKit.moduleName == "WatcherKit")
}
