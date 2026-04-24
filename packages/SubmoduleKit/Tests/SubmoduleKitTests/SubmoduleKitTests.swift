@testable import SubmoduleKit
import Testing

@Test("module name is set")

func moduleNameIsSet() {
    #expect(SubmoduleKit.moduleName == "SubmoduleKit")
}
