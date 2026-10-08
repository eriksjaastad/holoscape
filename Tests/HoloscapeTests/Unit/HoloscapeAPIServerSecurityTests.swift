import Network
import XCTest
@testable import Holoscape

final class HoloscapeAPIServerSecurityTests: XCTestCase {
    func testListenerParametersRequireLoopbackInterface() {
        let parameters = HoloscapeAPIServer.listenerParameters()

        XCTAssertEqual(parameters.requiredInterfaceType, .loopback)
    }
}
