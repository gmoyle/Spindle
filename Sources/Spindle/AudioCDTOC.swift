import Foundation
import CryptoKit

/// An audio CD's table of contents: where each audio track starts and where the
/// audio ends. macOS's CD filesystem (cddafs) exposes it as a hidden `.TOC.plist`
/// at the root of the mounted CD. Sector offsets here are LBAs, without the
/// 150-sector (2 s) lead-in that MusicBrainz adds.
struct AudioCDTOC: Equatable {
    let firstTrack: Int
    let lastTrack: Int
    /// Start sector of each audio track, in track order.
    let trackOffsets: [Int]
    /// First sector after the last audio track.
    let leadout: Int

    static let leadIn = 150
    static let sectorsPerSecond = 75
    /// Gap between the audio session and a data session on an enhanced CD.
    static let enhancedCDGap = 11_400

    var trackCount: Int { trackOffsets.count }

    /// Length of each track in seconds.
    var trackDurations: [Double] {
        zip(trackOffsets, trackOffsets.dropFirst() + [leadout]).map {
            Double($1 - $0) / Double(Self.sectorsPerSecond)
        }
    }

    /// The MusicBrainz disc ID: base64 (with ".", "_", "-" for "+", "/", "=") of the
    /// SHA-1 of the first and last track numbers, the lead-out, and 99 track
    /// offsets, as upper-case hex, with the lead-in added.
    var musicBrainzDiscID: String {
        var text = String(format: "%02X%02X", firstTrack, lastTrack)
        text += String(format: "%08X", leadout + Self.leadIn)
        for index in 0..<99 {
            let offset = index < trackOffsets.count ? trackOffsets[index] + Self.leadIn : 0
            text += String(format: "%08X", offset)
        }
        let digest = Insecure.SHA1.hash(data: Data(text.utf8))
        return Data(digest).base64EncodedString()
            .replacingOccurrences(of: "+", with: ".")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "-")
    }

    /// MusicBrainz's `toc` parameter: "first last leadout offset1 offset2 ...",
    /// lead-in included. Lets MusicBrainz find near matches for an unknown disc ID.
    var musicBrainzTOCParameter: String {
        ([firstTrack, lastTrack, leadout + Self.leadIn] + trackOffsets.map { $0 + Self.leadIn })
            .map(String.init).joined(separator: "+")
    }

    // MARK: - Reading `.TOC.plist`

    static func read(fromVolumeAt path: String) -> AudioCDTOC? {
        let url = URL(fileURLWithPath: path).appendingPathComponent(".TOC.plist")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return parse(plistData: data)
    }

    /// Parse cddafs's `.TOC.plist`. Its "Start Block" and "Leadout Block" values
    /// already include the 150-sector lead-in (track 1 starts at 150), so it's
    /// taken off here. Data tracks (an enhanced CD's second session) aren't audio:
    /// they're left out, and the audio then ends 11,400 sectors before the data
    /// track starts, as MusicBrainz expects.
    static func parse(plistData: Data) -> AudioCDTOC? {
        guard let plist = try? PropertyListSerialization.propertyList(from: plistData, format: nil),
              let root = plist as? [String: Any],
              let sessions = root["Sessions"] as? [[String: Any]], !sessions.isEmpty else { return nil }

        var audio: [(number: Int, start: Int)] = []
        var firstDataStart: Int?
        var lastLeadout: Int?
        for session in sessions {
            if let leadout = intValue(session["Leadout Block"]) { lastLeadout = leadout }
            for track in session["Track Array"] as? [[String: Any]] ?? [] {
                guard let number = intValue(track["Point"]), (1...99).contains(number),
                      let start = intValue(track["Start Block"]) else { continue }
                if track["Data"] as? Bool == true {
                    if firstDataStart == nil || start < firstDataStart! { firstDataStart = start }
                } else {
                    audio.append((number, start))
                }
            }
        }
        audio.sort { $0.number < $1.number }
        guard let first = audio.first, let last = audio.last else { return nil }

        let leadout: Int
        if let dataStart = firstDataStart, dataStart > last.start {
            leadout = dataStart - enhancedCDGap
        } else if let sessionLeadout = intValue(sessions[0]["Leadout Block"]) {
            leadout = sessionLeadout
        } else if let anyLeadout = lastLeadout {
            leadout = anyLeadout
        } else {
            return nil
        }
        guard leadout > last.start else { return nil }
        return AudioCDTOC(firstTrack: first.number, lastTrack: last.number,
                          trackOffsets: audio.map { $0.start - leadIn }, leadout: leadout - leadIn)
    }

    private static func intValue(_ value: Any?) -> Int? {
        (value as? NSNumber)?.intValue ?? (value as? Int)
    }
}
