import Testing
@testable import SubmoduleKit

@Test func moduleNameIsSet() {
    #expect(SubmoduleKit.moduleName == "SubmoduleKit")
}
