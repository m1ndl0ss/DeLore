import Foundation

/// Decodes Instagram "Download your information" message files (JSON format).
///
/// Message text is never materialised: the decoder only checks which keys are present to
/// classify a message, so content never becomes a Swift value we could leak or persist.
enum InstagramExportFormat {
    struct Participant: Decodable {
        let name: String?
    }

    struct ParticipantsOnly: Decodable {
        let participants: [Participant]?
    }

    struct ThreadFile: Decodable {
        let participants: [Participant]?
        let title: String?
        let messages: [Message]?
    }

    struct Message: Decodable {
        let senderName: String?
        let timestampMs: Int64?
        let kind: MessageKind
        /// Calls, unsent placeholders and similar entries that can't be unsent.
        let isSystemEntry: Bool

        private enum CodingKeys: String, CodingKey {
            case senderName = "sender_name"
            case timestampMs = "timestamp_ms"
            case content, photos, videos, gifs, sticker, share
            case audioFiles = "audio_files"
            case callDuration = "call_duration"
            case isUnsent = "is_unsent"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            senderName = try container.decodeIfPresent(String.self, forKey: .senderName)
            timestampMs = try container.decodeIfPresent(Int64.self, forKey: .timestampMs)
            let isUnsent = (try? container.decodeIfPresent(Bool.self, forKey: .isUnsent)) ?? false
            isSystemEntry = isUnsent || container.contains(.callDuration)

            if container.contains(.audioFiles) {
                kind = .voice
            } else if container.contains(.photos) || container.contains(.videos)
                        || container.contains(.gifs) || container.contains(.sticker) {
                kind = .media
            } else if container.contains(.share) {
                kind = .link
            } else if container.contains(.content) {
                kind = .text
            } else {
                kind = .other
            }
        }
    }

    /// Matches `…/messages/inbox/<thread>/message_<n>.json` in current and older layouts.
    static func threadLocation(of path: String) -> (thread: String, fileNumber: Int)? {
        let components = path.split(separator: "/").map(String.init)
        guard components.count >= 4 else { return nil }
        let file = components[components.count - 1]
        let thread = components[components.count - 2]
        let box = components[components.count - 3]
        let messages = components[components.count - 4]
        guard messages == "messages", box == "inbox", file.hasPrefix("message_"), file.hasSuffix(".json") else { return nil }
        let number = Int(file.dropFirst("message_".count).dropLast(".json".count)) ?? 0
        return (thread, number)
    }

    /// Instagram exports write UTF-8 bytes as individual `\u00XX` escapes. Re-decode when every
    /// scalar fits in a byte and the result is valid UTF-8.
    static func repairingMojibake(_ text: String) -> String {
        let scalars = text.unicodeScalars
        guard scalars.contains(where: { $0.value >= 0x80 }), scalars.allSatisfy({ $0.value <= 0xFF }) else { return text }
        let bytes = scalars.map { UInt8($0.value) }
        return String(bytes: bytes, encoding: .utf8) ?? text
    }

    static func participantID(forName name: String) -> ParticipantID {
        ParticipantID("name:" + name)
    }
}
