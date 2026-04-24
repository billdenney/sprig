import Testing
@testable import UpdateKit

@Test("module name is set")

func moduleNameIsSet() {
    #expect(UpdateKit.moduleName == "UpdateKit")
}
