import XCTest
@testable import RoamttyCore

final class HostConnectionIdentityTests: XCTestCase {
    func testNameAndDisplaySettingsDoNotInvalidateLogin() {
        let host = Host(id: "host", name: "Before", address: "Example.COM.", username: "deploy")
        var edited = host
        edited.name = "After"; edited.address = "example.com"; edited.mode = .shell
        edited.system = "LINUX"; edited.plugins = ["tmux"]; edited.keyLabel = "renamed key"
        XCTAssertTrue(host.hasSameLoginIdentity(as: edited))
    }

    func testEndpointUserOrAuthenticationChangesInvalidateLogin() {
        let host = Host(id: "host", name: "Fixture", address: "old.example", username: "deploy")
        for field in ["address", "port", "user", "auth", "id"] {
            var edited = host
            switch field {
            case "address": edited.address = "new.example"
            case "port": edited.port = 2222
            case "user": edited.username = "root"
            case "auth": edited.auth = .key
            default: edited.id = "different-host"
            }
            XCTAssertFalse(host.hasSameLoginIdentity(as: edited), field)
        }
    }
}
