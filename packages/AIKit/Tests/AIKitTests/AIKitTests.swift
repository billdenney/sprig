@testable import AIKit
import Testing

@Test("module name is set")

func moduleNameIsSet() {
    #expect(AIKit.moduleName == "AIKit")
}
