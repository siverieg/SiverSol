import XCTest
@testable import SiverCore
@testable import SiverNotify

/// The Privacy page says which hosts SiverSol contacts. This keeps that sentence true.
final class NetworkHostTests: XCTestCase {
    func testOnlyListedHostsAreAcceptedAsWebhooks() {
        for host in PermissionGuide.contactedHosts {
            XCTAssertNotNil(WebhookURL("https://\(host)/api/webhooks/123456789012345678/token"), host)
        }
        for other in ["example.com", "discord.com.example.com", "evil-discord.com", "www.roblox.com", "discord.gg", "localhost"] {
            XCTAssertNil(WebhookURL("https://\(other)/api/webhooks/123456789012345678/token"), other)
        }
        XCTAssertNil(WebhookURL("http://discord.com/api/webhooks/123456789012345678/token"), "plain http is refused")
    }
}
