@testable import SubtreeKit
import Testing

@Test("module name is set")

func moduleNameIsSet() {
    #expect(SubtreeKit.moduleName == "SubtreeKit")
}
