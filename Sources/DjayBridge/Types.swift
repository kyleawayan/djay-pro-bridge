import Foundation

public struct DeckInfo {
    public var key: String?
    public var title: String?
    public var artist: String?
    public var bpm: String?
    public var elapsedTime: String?
    public var remainingTime: String?
    public var bpmPercent: String?
    public var isPlaying: Bool

    public init(
        key: String? = nil, title: String? = nil, artist: String? = nil,
        bpm: String? = nil, elapsedTime: String? = nil, remainingTime: String? = nil,
        bpmPercent: String? = nil, isPlaying: Bool = false
    ) {
        self.key = key
        self.title = title
        self.artist = artist
        self.bpm = bpm
        self.elapsedTime = elapsedTime
        self.remainingTime = remainingTime
        self.bpmPercent = bpmPercent
        self.isPlaying = isPlaying
    }
}

public struct ElementInfo {
    public var label: String?
    public var role: String?
    public var value: String?
    public var subrole: String?

    public init(label: String? = nil, role: String? = nil, value: String? = nil, subrole: String? = nil) {
        self.label = label
        self.role = role
        self.value = value
        self.subrole = subrole
    }
}
