@testable import StatusKit
import Testing

@Test("module name is set")

func moduleNameIsSet() {
    #expect(StatusKit.moduleName == "StatusKit")
}
