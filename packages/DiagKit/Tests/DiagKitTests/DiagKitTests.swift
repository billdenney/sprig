@testable import DiagKit
import Testing

@Test("module name is set")

func moduleNameIsSet() {
    #expect(DiagKit.moduleName == "DiagKit")
}
