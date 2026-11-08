import Foundation

/// A home-made video DVD (from a camcorder or a DVD recorder): ripped into the
/// Home Videos library as `Home Videos/2004-07-14 Birthday/2004-07-14 Birthday.mkv`.
struct HomeVideoInfo: Equatable {
    /// When it was recorded (from the label, else the disc's creation date).
    let date: Date
    /// The disc's own name, unless it's a generic one ("DVD_VIDEO").
    let label: String?

    var folderName: String {
        let day = Self.dayFormatter.string(from: date)
        return MusicLibraryNaming.safe(label.map { "\(day) \($0)" } ?? "\(day) Home Video")
    }

    /// "2004-07-14 Birthday.mkv" for a disc with one recording, numbered when
    /// there are several.
    func fileName(index: Int, total: Int) -> String {
        total <= 1 ? "\(folderName).mkv" : "\(folderName) - " + String(format: "%02d", index + 1) + ".mkv"
    }

    static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}

enum HomeVideoDetector {

    /// Labels camcorders, recorders and burning apps give a disc by default.
    static let genericLabels: Set<String> = [
        "DVD", "DVD_VIDEO", "DVDVIDEO", "DVD VIDEO", "VIDEO_TS", "VIDEO", "DVD_VR", "DVDVR", "UNTITLED",
        "NO_NAME", "NO NAME", "MY_DVD", "MYDVD", "MY DVD", "NEW_DISC", "NEW DISC", "DVD_ROM", "DVDROM",
        "DVD-R", "DVD+R", "DVD_R", "DVD_RW", "HOME_VIDEO", "HOMEVIDEO", "CAMCORDER", "DISC", "DVDDISC"
    ]

    /// A recordable disc (DVD±R, DVD±RW, DVD-RAM) rather than a pressed one
    /// (DVD-ROM). Commercial films are pressed; camcorder and recorder discs
    /// are recordable. `mediaType` is diskutil's "OpticalMediaType".
    static func isRecordable(opticalMediaType mediaType: String?) -> Bool {
        guard let type = mediaType?.uppercased(), !type.hasSuffix("ROM") else { return false }
        return type.contains("-R") || type.contains("+R") || type.contains("RAM")
    }

    /// A video DVD on recordable media is a home video. (A burned copy of a
    /// film lands in Home Videos too; move it if so.)
    static func isHomeVideo(kind: DiscKind, opticalMediaType: String?) -> Bool {
        kind == .dvd && isRecordable(opticalMediaType: opticalMediaType)
    }

    static func info(forDiscAt mountPoint: String, fileManager: FileManager = .default) -> HomeVideoInfo {
        let label = (mountPoint as NSString).lastPathComponent
        if let date = date(fromLabel: label) {
            return HomeVideoInfo(date: date, label: nil)
        }
        let url = URL(fileURLWithPath: mountPoint)
        let ifo = (mountPoint as NSString).appendingPathComponent("VIDEO_TS/VIDEO_TS.IFO")
        let date = (try? url.resourceValues(forKeys: [.volumeCreationDateKey]))?.volumeCreationDate
            ?? (try? fileManager.attributesOfItem(atPath: ifo))?[.modificationDate] as? Date
            ?? Date()
        return HomeVideoInfo(date: date, label: displayLabel(label))
    }

    /// The label as a name ("BIRTHDAY_PARTY" → "Birthday Party"), or nil if
    /// it's generic.
    static func displayLabel(_ label: String) -> String? {
        let trimmed = label.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !genericLabels.contains(trimmed.uppercased()) else { return nil }
        let words = trimmed.replacingOccurrences(of: "_", with: " ").split(separator: " ")
        // All-caps labels (the ISO 9660 norm) read better capitalized.
        let name = trimmed == trimmed.uppercased()
            ? words.map { $0.capitalized }.joined(separator: " ")
            : words.joined(separator: " ")
        return name.isEmpty ? nil : name
    }

    /// Recorder labels that are just a date: "2004_07_14", "20040714", "2004-07-14".
    static func date(fromLabel label: String) -> Date? {
        let digits = label.filter(\.isNumber)
        let separators = label.filter { !$0.isNumber }
        guard digits.count == 8, separators.allSatisfy({ "_-. ".contains($0) }) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd"
        guard let date = formatter.date(from: digits) else { return nil }
        let year = Calendar.current.component(.year, from: date)
        return (1980...2100).contains(year) ? date : nil
    }

    /// The recordings to rip: every title of 5 seconds or more, without
    /// duplicates (titles that play the same cells) or a "play all" title that
    /// joins the others. Indices into `titles`, in disc order.
    static func titlesToRip(durations: [Double], cellKeys: [String]) -> [Int] {
        var seen = Set<String>()
        var kept: [Int] = []
        for index in durations.indices where durations[index] >= 5 {
            if seen.insert(cellKeys[index]).inserted { kept.append(index) }
        }
        guard kept.count >= 3 else { return kept }
        return kept.filter { index in
            let others = kept.filter { $0 != index }.reduce(0) { $0 + durations[$1] }
            return abs(durations[index] - others) > max(others * 0.03, 2)
        }
    }
}

extension DriveDetector {
    /// diskutil's "OpticalMediaType" for a mounted disc ("DVD-ROM", "DVD+R",
    /// "CD-R"...). Reads IOKit properties only, never the disc.
    static func opticalMediaType(at mountPoint: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        process.arguments = ["info", "-plist", mountPoint]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        return info["OpticalMediaType"] as? String
    }
}
