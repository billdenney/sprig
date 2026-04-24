@testable import ConflictKit
import Testing

@Test("module name is set")

func moduleNameIsSet() {
    #expect(ConflictKit.moduleName == "ConflictKit")
}
