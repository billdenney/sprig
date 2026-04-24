import Testing
@testable import DiagKit

@Test func moduleNameIsSet() {
    #expect(DiagKit.moduleName == "DiagKit")
}
