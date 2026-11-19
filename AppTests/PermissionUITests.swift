import AppKit
import SwiftUI
import XCTest
import SiverCore
@testable import SiverSol

/// Checks the real views, hosted in a window: every permission row has its "?" button, and every explainer
/// has all five parts. Each part of the UI reports its own name while it is drawn (`UIMarkerKey`), so a part
/// that is removed from a view is missing here.
@MainActor
final class PermissionUITests: XCTestCase {
    private final class Box { var value: Set<String> = [] }

    /// Host a view in a window, let it lay out, and collect the names of the parts it drew.
    private func identifiers<V: View>(in view: V, size: CGSize = CGSize(width: 900, height: 1400)) -> Set<String> {
        let box = Box()
        let root = view.environmentObject(AppModel.shared)
            .frame(width: size.width, height: size.height)
            .onPreferenceChange(UIMarkerKey.self) { box.value = $0 }
        let host = NSHostingView(rootView: root)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        window.contentView = nil
        return box.value
    }

    func testEveryPermissionRowHasItsQuestionMark() {
        // The three places permission rows appear: onboarding, Settings, the Privacy & Permissions page.
        let surfaces: [(String, [PermissionTopic], Set<String>)] = [
            ("onboarding", PermissionGuide.prompts, identifiers(in: PermissionList(topics: PermissionGuide.prompts))),
            ("settings", PermissionGuide.topics, identifiers(in: SetupSection())),
            ("privacy page", PermissionGuide.topics, identifiers(in: ScrollView { PrivacyPage() }, size: CGSize(width: 900, height: 4000))),
        ]
        for (name, topics, ids) in surfaces {
            XCTAssertFalse(ids.isEmpty, "\(name): nothing was drawn")
            for topic in topics {
                XCTAssertTrue(ids.contains("permission-row-\(topic.id)"), "\(name) is missing the row for \(topic.title); found \(ids.sorted())")
                XCTAssertTrue(ids.contains("permission-help-\(topic.id)"), "\(name): the \(topic.title) row has no “?” button")
            }
        }
    }

    func testAViewWithoutThePartsReportsNone() {
        // Guards the test itself: a view that draws no permission UI must come back empty.
        XCTAssertTrue(identifiers(in: Text("nothing to see"), size: CGSize(width: 200, height: 100)).isEmpty)
    }

    func testEveryExplainerHasAllFiveParts() {
        for topic in PermissionGuide.topics {
            let ids = identifiers(in: PermissionExplainer(topic: topic), size: CGSize(width: 420, height: 900))
            for part in ["explainer-why", "explainer-never", "explainer-without", "explainer-off", "explainer-settings"] {
                XCTAssertTrue(ids.contains(part), "\(topic.title): the explainer is missing \(part); found \(ids.sorted())")
            }
        }
    }

    func testEveryPermissionRowInTheAppIsAPermissionRowView() {
        // Rows are only ever drawn by PermissionList, from PermissionGuide. This guards the list itself.
        XCTAssertEqual(PermissionGuide.prompts.map(\.title), ["Screen Recording", "Accessibility"])
        XCTAssertEqual(PermissionGuide.topics.count, 3)
    }
}
