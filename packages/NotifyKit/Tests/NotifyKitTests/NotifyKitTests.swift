@testable import NotifyKit
import Testing

@Test("module name is set")

func moduleNameIsSet() {
    #expect(NotifyKit.moduleName == "NotifyKit")
}
