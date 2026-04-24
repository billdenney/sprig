import Testing
@testable import TransportKit

@Test("module name is set")

func moduleNameIsSet() {
    #expect(TransportKit.moduleName == "TransportKit")
}
