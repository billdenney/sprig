import Testing
@testable import SafetyKit

@Test func moduleNameIsSet() {
    #expect(SafetyKit.moduleName == "SafetyKit")
}
