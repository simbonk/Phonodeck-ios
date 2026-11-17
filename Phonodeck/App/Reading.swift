import Foundation

/// Reading settings the Phonodeck and the Chat tab share, so changing one changes both.
enum Reading {
    /// Text size in points for story passages and chat messages. (The key predates Chat using it.)
    static let textSizeKey = "storyTextSize"
    static let defaultTextSize: Double = 15
    static let minTextSize: Double = 12
    static let maxTextSize: Double = 24

    /// Whether replies are read aloud as they are written, in the Phonodeck and in Chat.
    /// The story engine owns the value (`StoryEngine.narrate`); this reads the stored setting.
    static let readAloudKey = "narrate"
    static var readAloud: Bool { UserDefaults.standard.object(forKey: readAloudKey) as? Bool ?? true }

    /// Optional standing instructions for the Chat tab's assistant.
    static let chatInstructionsKey = "chatSystem"
}
