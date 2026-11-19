import Foundation

public enum AuraName {
    /// "SeekerOfTheCrimsonMoon" -> "Seeker Of The Crimson Moon". Used when auras.json has no entry (F5).
    public static func display(_ internalName: String) -> String {
        var out = ""
        let chars = Array(internalName.replacingOccurrences(of: "_", with: " "))
        for (i, ch) in chars.enumerated() {
            if i > 0, ch.isUppercase || (ch.isNumber && !chars[i - 1].isNumber) {
                let prev = chars[i - 1]
                let nextIsLower = i + 1 < chars.count && chars[i + 1].isLowercase
                // Break before a capital that starts a word: aB, or the last capital of an acronym (ABc -> A Bc).
                if prev.isLowercase || (prev.isNumber && ch.isUppercase) || (prev.isUppercase && ch.isUppercase && nextIsLower)
                    || (ch.isNumber && prev.isLetter) {
                    if prev != " " { out.append(" ") }
                }
            }
            out.append(ch)
        }
        return out.split(separator: " ").joined(separator: " ")
    }
}
