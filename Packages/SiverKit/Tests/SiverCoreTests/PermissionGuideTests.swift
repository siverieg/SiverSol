import XCTest
@testable import SiverCore

final class PermissionGuideTests: XCTestCase {
    func testEveryTopicHasAllFiveParts() {
        XCTAssertFalse(PermissionGuide.topics.isEmpty)
        for topic in PermissionGuide.topics {
            let parts = topic.parts
            XCTAssertEqual(parts.map(\.id), ["why", "never", "without", "off", "settings"], topic.id)
            for part in parts {
                XCTAssertFalse(part.heading.trimmingCharacters(in: .whitespaces).isEmpty, "\(topic.id) \(part.id)")
                XCTAssertGreaterThan(part.text.count, 20, "\(topic.id) \(part.id) needs real text")
            }
            XCTAssertNotNil(URL(string: topic.settingsURL), topic.id)
            XCTAssertTrue(topic.settingsURL.hasPrefix("x-apple.systempreferences:"), "\(topic.id) must open System Settings")
        }
        XCTAssertEqual(Set(PermissionGuide.topics.map(\.id)).count, PermissionGuide.topics.count, "ids are unique")
    }

    func testExactlyTwoPermissionPrompts() {
        // Hard rule 12: Screen Recording and Accessibility, nothing else.
        XCTAssertEqual(PermissionGuide.prompts.map(\.id), ["screen-recording", "accessibility"])
        XCTAssertTrue(PermissionGuide.notRequested.contains("Input Monitoring"))
        XCTAssertTrue(PermissionGuide.notRequested.contains("Notifications"))
    }

    func testReadmeTextComesFromTheSameData() {
        let md = PermissionGuide.markdown(sourceURL: "https://example.invalid/repo")
        for topic in PermissionGuide.topics {
            XCTAssertTrue(md.contains(topic.why)); XCTAssertTrue(md.contains(topic.never))
            XCTAssertTrue(md.contains(topic.withoutIt)); XCTAssertTrue(md.contains(topic.turnOff))
        }
        for note in PermissionGuide.notes { XCTAssertTrue(md.contains(note.text)) }
    }

    func testTheReadmeCarriesTheSameSection() throws {
        // README.md at the repository root must contain the generated section word for word
        // (`siversolctl privacy-md` prints it). Skipped when the tests run from a copy without the README.
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let readme = root.appendingPathComponent("README.md")
        guard let text = try? String(contentsOf: readme, encoding: .utf8) else { throw XCTSkip("no README.md next to the package") }
        XCTAssertTrue(text.contains(PermissionGuide.markdown(sourceURL: SiverSol.sourceURL)),
                      "README.md is out of date: paste the output of `siversolctl privacy-md` into its Privacy & Permissions section")
    }

    func testNetworkNoteListsExactlyTheHostsAWebhookMayUse() {
        // The hosts in the note are the hosts WebhookURL accepts; SiverNotifyTests checks the other direction.
        XCTAssertEqual(PermissionGuide.contactedHosts.sorted(), ["canary.discord.com", "discord.com", "discordapp.com", "ptb.discord.com"])
    }
}

final class MerchantNameTests: XCTestCase {
    func testAMisreadLetterIsStillTheSameMerchant() {
        // Seen live: the chat said Mari, text recognition read "Marf", and a second alert went out.
        XCTAssertEqual(LogLineParser.merchantName(in: "[Merchant]: Marf has arrived on the island..."), "Mari")
        XCTAssertEqual(LogLineParser.merchantName(in: "[Merchant]: Mari has arrived on the island..."), "Mari")
        XCTAssertEqual(LogLineParser.merchantName(in: "Merchant]: Jestr has arrived on the island"), "Jester")
        XCTAssertEqual(LogLineParser.merchantName(in: "[Merchant]: Rim has arrived"), "Rin")
        // A genuinely new merchant (two or more letters away from every known name) still gets its own name, with the tag.
        XCTAssertEqual(LogLineParser.merchantName(in: "[Merchant]: Orla has arrived on the island..."), "Orla")
        // Without the tag, an unknown word is not a merchant, and neither is ordinary chat.
        XCTAssertNil(LogLineParser.merchantName(in: "my friend Orla has arrived"))
        XCTAssertTrue(LogLineParser.oneLetterApart("mari", "marf")); XCTAssertTrue(LogLineParser.oneLetterApart("jester", "jestr"))
        XCTAssertFalse(LogLineParser.oneLetterApart("mari", "mari")); XCTAssertFalse(LogLineParser.oneLetterApart("mari", "orla"))
    }
}
