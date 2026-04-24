import Testing
@testable import UpdateKit

@Test func moduleNameIsSet() {
    #expect(UpdateKit.moduleName == "UpdateKit")
}
