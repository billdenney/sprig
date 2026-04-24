import Testing
@testable import WatcherKit

@Test("module name is set")

func moduleNameIsSet() {
    #expect(WatcherKit.moduleName == "WatcherKit")
}
