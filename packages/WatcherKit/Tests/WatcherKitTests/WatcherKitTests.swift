import Testing
@testable import WatcherKit

@Test func moduleNameIsSet() {
    #expect(WatcherKit.moduleName == "WatcherKit")
}
