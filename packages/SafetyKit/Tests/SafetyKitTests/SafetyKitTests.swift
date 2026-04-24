@testable import SafetyKit
import Testing

@Test("module name is set")

func moduleNameIsSet() {
    #expect(SafetyKit.moduleName == "SafetyKit")
}
