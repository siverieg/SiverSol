import Foundation

/// What SiverSol asks macOS for, and the honest answers to "why", in one place.
///
/// Every permission row in the app (onboarding, Settings, the Privacy & Permissions page) is drawn from this
/// list, and every "?" popover shows the same five parts: why, never, without it, how to turn it off, and a
/// button that opens the right page of System Settings. The README section is the same text.
///
/// Each "never" sentence is a statement about the code. When the code changes, change the sentence:
/// - Screen Recording: the only capture calls are `WindowCapture.capture(windowId:)` (still pictures) and
///   `MomentRecorder.record` (Moments clips, off until the user turns them on), both with the Roblox window's id
///   and neither with sound. Every picture that is uploaded goes through `ProofShot.masked` first, and every
///   frame of a clip through `MomentRecorder.copyMasked`.
/// - Screen Recording: the window is identified by the owning process's bundle id (`RobloxWindowFinder.ownedByRoblox`).
/// - Accessibility: keys go to the Roblox process (`postToPid`) or, for anything sent through the system input
///   path, only while Roblox is the front app (`LiveMacroOutput.mayPostToFrontApp`, `InputDriver.post` and `click`).
///   Idle time comes from `UserActivity.secondsSinceLastInput` (a number of seconds, nothing else).
///   The event tap exists only while a recording, a mouse macro or the auto clicker is running, and the recorder
///   drops every event made while Roblox is not in front.
public struct PermissionTopic: Identifiable, Equatable, Sendable {
    public enum Kind: String, Sendable { case required, optional }

    /// Stable id, also used for accessibility identifiers ("permission-row-<id>", "permission-help-<id>").
    public let id: String
    public let title: String
    public let symbol: String
    public let kind: Kind
    /// One line for the row itself.
    public let summary: String
    public let why: String
    public let never: String
    public let withoutIt: String
    public let turnOff: String
    /// The page of System Settings where this is switched on or off.
    public let settingsURL: String
    public let settingsButton: String

    /// The five parts, in the order they are always shown. The last one is the button.
    public var parts: [(id: String, heading: String, text: String)] {
        [("why", "Why SiverSol asks", why),
         ("never", "What it never does", never),
         ("without", "What still works without it", withoutIt),
         ("off", "How to turn it off", turnOff),
         ("settings", settingsButton, settingsURL)]
    }
}

/// Things that are not permission prompts, but that people reasonably ask about.
public struct PrivacyNote: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let symbol: String
    public let text: String
}

public enum PermissionGuide {
    public static let screenRecording = PermissionTopic(
        id: "screen-recording", title: "Screen Recording", symbol: "rectangle.dashed.badge.record", kind: .required,
        summary: "Pictures of the Roblox window, to read on-screen text, for proof shots and, if you turn them on, Moments clips.",
        why: "It lets SiverSol take still pictures of the Roblox window, and only that window. It reads the text in them (the Play button, merchant notices in chat, the safety check before every key press), compares them to notice a frozen game, and uses them for the proof shots you choose to send to your own Discord. If you turn on Moments, it also records short video clips of that window: a roll's cutscene, and 12 seconds when a rare biome starts. Recent versions of macOS ask you to confirm this again from time to time, with a box that says SiverSol “is requesting to bypass the system private window picker”. That is this same permission, not a new one.",
        never: "It never records sound, never records video unless you turn on Moments, and never captures another app's window or the whole screen. To find the Roblox window it asks macOS for the list of open windows and uses only the one that belongs to the Roblox app. A picture is only uploaded to a webhook you added yourself, and the chat and the player list are covered first. Moments clips have the same two areas covered in every frame; they stay on this Mac in Movies/SiverSol Moments (the oldest are removed when the folder passes the size you set) and are only posted to Discord if you turn that on as well. Proof shots stay in SiverSol's own folder on this Mac; ones older than a week are deleted each time SiverSol starts watching. The test screenshot from Settings is kept there too, uncovered, and is never uploaded.",
        withoutIt: "Biome detection and Discord alerts still work, because they come from the Roblox log. Proof shots, Moments and merchant reading stop. So does everything that presses a key or clicks (anti-AFK, the Play button after a rejoin, macros): SiverSol does not press anything it cannot check on screen first.",
        turnOff: "System Settings → Privacy & Security → Screen & System Audio Recording, then switch SiverSol off. (On older macOS the page is called Screen Recording.)",
        settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture",
        settingsButton: "Open System Settings")

    public static let accessibility = PermissionTopic(
        id: "accessibility", title: "Accessibility", symbol: "accessibility", kind: .required,
        summary: "Key presses and clicks inside Roblox, and recording your own macros.",
        why: "It lets SiverSol press keys and click inside Roblox: the anti-AFK key, the Play button after a rejoin, one press of Escape if a purchase dialog shows up, and the macros you make. It is also what lets SiverSol bring Roblox to the front before a click, and what lets the recorder see your keys and mouse while you record a macro.",
        never: "It never presses a key or clicks unless Roblox is the front app, or the key is sent straight to the Roblox process. (Letting go is the one exception: a key or button SiverSol is holding is always released, wherever that lands, so nothing stays stuck.) It never records anything unless you press Record, and while recording it throws away every key and click made in another app. Outside a recording, a mouse macro or the auto clicker, it does not see your keys or mouse at all: it only hears its own five shortcuts, and it can ask macOS how many seconds the Mac has been idle. One thing to know: a recording keeps the keys you press inside Roblox, so do not type a password while the red ● is on.",
        withoutIt: "Detection and Discord alerts still work. Auto-rejoin can still reopen your private server. There is no anti-AFK, no click on the Play button, and no macros or auto clicker.",
        turnOff: "System Settings → Privacy & Security → Accessibility, then switch SiverSol off.",
        settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
        settingsButton: "Open System Settings")

    public static let launchAtLogin = PermissionTopic(
        id: "launch-at-login", title: "Launch at login", symbol: "power", kind: .optional,
        summary: "Starts SiverSol after a restart so an AFK session carries on.",
        why: "It opens SiverSol when you log in to this Mac, so a restart or an overnight update does not end your AFK session. It is off until you turn it on. macOS does not ask for permission; it shows its usual notice that a login item was added.",
        never: "It never installs a hidden helper or a background service. It is the app itself in your Login Items list, nothing more, and it does not start the macro unless you also turned on “Start when SiverSol opens”.",
        withoutIt: "Everything works. You open SiverSol yourself.",
        turnOff: "Turn the switch off in SiverSol's Settings, or remove SiverSol in System Settings → General → Login Items & Extensions.",
        settingsURL: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension",
        settingsButton: "Open System Settings")

    /// Every row that gets a "?" button, in display order.
    public static let topics: [PermissionTopic] = [screenRecording, accessibility, launchAtLogin]

    /// The two macOS asks for. Hard rule: there are exactly two.
    public static let prompts: [PermissionTopic] = [screenRecording, accessibility]

    public static func topic(_ id: String) -> PermissionTopic? { topics.first { $0.id == id } }

    /// Permissions SiverSol does not ask for. Shown on the Privacy page so the absence is explicit.
    public static let notRequested = ["Input Monitoring", "Notifications", "Automation (controlling other apps)", "Full Disk Access",
                                      "Location", "Camera", "Microphone", "Contacts", "Files and Folders"]

    /// Every host SiverSol itself opens a connection to. Checked against `WebhookURL`, the only gate requests pass.
    public static let contactedHosts = ["discord.com", "discordapp.com", "ptb.discord.com", "canary.discord.com"]

    public static let notes: [PrivacyNote] = [
        PrivacyNote(id: "logs", title: "Roblox logs", symbol: "doc.text.magnifyingglass",
                    text: "SiverSol reads the log files Roblox writes in ~/Library/Logs/Roblox. That needs no permission, and SiverSol only reads them; it never changes or deletes them. Raw log lines are never uploaded and never shown. Each line is turned into named facts first (a biome, an aura, a join), and your username, user ID, join tickets and IP addresses are left out of everything shown or sent."),
        PrivacyNote(id: "secrets", title: "Your webhook and private server link", symbol: "key.horizontal",
                    text: "Both are kept in this Mac's Keychain, not in a plain file. The webhook URL is only used to talk to Discord. The private server link is put into the messages SiverSol posts to the webhooks you added (the Join button, a Private server line on rare-biome and merchant alerts, and the link field hunt bots read), so a hunt server you added does receive it: that is how hunters join you. It is also handed to Roblox, or to your browser, to reopen your server. Neither goes anywhere else, and neither is written to SiverSol's files or logs."),
        PrivacyNote(id: "network", title: "Network", symbol: "network",
                    text: "SiverSol itself connects to one place: Discord, at the host in your webhook URL (\(contactedHosts.joined(separator: ", "))). When it rejoins, it asks macOS to open your private server link; Roblox, or your browser at www.roblox.com, makes that connection. It also watches whether the Mac is online, which sends nothing. Open channel and the GitHub link open your browser or Discord; SiverSol does not load those pages itself. There are no analytics, no crash reports, no update checks and no accounts."),
        PrivacyNote(id: "roblox", title: "Roblox itself", symbol: "gamecontroller",
                    text: "SiverSol does not touch Roblox's cookies, Keychain items, cache or app files, does not read its memory and injects nothing. It sees what you would see (the log folder and the window), reads how much memory and CPU the Roblox process uses, and presses what you could press. To rejoin it quits Roblox the normal way and opens your private server link."),
        PrivacyNote(id: "files", title: "What is stored on this Mac", symbol: "folder",
                    text: "~/Library/Application Support/SiverSol holds the timeline of biomes and auras, the queue of unsent messages, the ids of the Discord messages it posted (needed to edit and link them), the action log, your macros and recent proof shots. Moments clips, if you turned them on, are in ~/Movies/SiverSol Moments. Deleting the first folder resets SiverSol; the Keychain entry is removed separately in Keychain Access.")
    ]

    /// The same text as a Markdown section, for the README. Kept next to the data so the two cannot drift apart.
    public static func markdown(sourceURL: String) -> String {
        var out = ["## Privacy & Permissions", "",
                   "SiverSol asks macOS for exactly two permissions. Both can be switched off again at any time.", ""]
        for t in topics {
            out += ["### \(t.title)\(t.kind == .optional ? " (optional)" : "")", "",
                    "- **Why SiverSol asks:** \(t.why)", "- **What it never does:** \(t.never)",
                    "- **What still works without it:** \(t.withoutIt)", "- **How to turn it off:** \(t.turnOff)", ""]
        }
        out += ["SiverSol does **not** ask for: \(notRequested.joined(separator: ", ")).", ""]
        for n in notes { out += ["### \(n.title)", "", n.text, ""] }
        out += ["**Verify it yourself:** the source code is at \(sourceURL)."]
        return out.joined(separator: "\n")
    }
}
