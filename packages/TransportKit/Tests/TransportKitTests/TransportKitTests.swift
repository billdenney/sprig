import Testing
@testable import TransportKit

@Test func moduleNameIsSet() {
    #expect(TransportKit.moduleName == "TransportKit")
}
