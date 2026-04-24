import Testing
@testable import ConflictKit

@Test func moduleNameIsSet() {
    #expect(ConflictKit.moduleName == "ConflictKit")
}
