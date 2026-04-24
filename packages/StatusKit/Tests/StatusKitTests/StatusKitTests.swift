import Testing
@testable import StatusKit

@Test func moduleNameIsSet() {
    #expect(StatusKit.moduleName == "StatusKit")
}
