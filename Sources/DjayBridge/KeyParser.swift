import Foundation

public struct ParsedKey {
    public let rootNoteIndex: Int  // 0-11 (C=0, C#=1, ..., B=11)
    public let scale: String       // "Major" or "Minor"

    /// Parses a djay Pro key string like "e", "c sharp minor", "e flat" into root note index + scale.
    public static func parse(_ raw: String) -> ParsedKey? {
        let parts = raw.lowercased().split(separator: " ").map(String.init)
        guard let noteName = parts.first, noteName.count == 1 else { return nil }

        let isMinor = parts.contains("minor")

        // Determine semitone from note letter + optional sharp/flat
        let baseNote: Int
        switch noteName {
        case "c": baseNote = 0
        case "d": baseNote = 2
        case "e": baseNote = 4
        case "f": baseNote = 5
        case "g": baseNote = 7
        case "a": baseNote = 9
        case "b": baseNote = 11
        default: return nil
        }

        var semitone = baseNote
        if parts.contains("sharp") { semitone += 1 }
        else if parts.contains("flat") { semitone -= 1 }
        // Wrap around (e.g. "c flat" = B = 11)
        semitone = ((semitone % 12) + 12) % 12

        return ParsedKey(rootNoteIndex: semitone, scale: isMinor ? "Minor" : "Major")
    }
}
