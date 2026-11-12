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
            ? words.map(capitalizedWord).joined(separator: " ")
            : words.joined(separator: " ")
        return name.isEmpty ? nil : name
    }

    /// "BIRTHDAY" → "Birthday", "5THGRADE2016" → "5thgrade2016": only a
    /// leading letter is capitalized (`capitalized` would give "5Thgrade2016").
    private static func capitalizedWord(_ word: Substring) -> String {
        let lower = word.lowercased()
        guard let first = lower.first, first.isLetter else { return lower }
        return first.uppercased() + lower.dropFirst()
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

@_silgen_name("dvdcss_is_scrambled")
func dvdcss_is_scrambled(_ dvdcss: OpaquePointer!) -> Int32

/// Home-made DVDs that report as pressed (DVD-ROM): school and event videos
/// from a duplication service, discs burned with the DVD-ROM book type. Films
/// are copy-protected (CSS) and region-locked; home-made discs are neither.
enum HomeMadeDiscCheck {

    /// What a disc says about itself.
    struct Signs: Equatable {
        /// CSS copy protection; nil if the drive couldn't say.
        let scrambled: Bool?
        /// The regions the disc won't play in (VIDEO_TS.IFO), one bit each for
        /// regions 1–8; 0 plays everywhere.
        let regionMask: UInt8?

        /// Plays in every region where discs are sold (1–6). Region 7 is
        /// reserved and 8 is for planes and ships, so authoring tools often
        /// block them on discs that are otherwise region-free (mask 0x40).
        var isRegionFree: Bool { regionMask.map { $0 & 0x3F == 0 } ?? false }

        /// No copy protection and no region lock.
        var looksHomeMade: Bool { scrambled == false && isRegionFree }
    }

    /// Read both signs. Opens the drive briefly, so it runs with no MakeMKV
    /// drive scan in progress (`DiscReads`); call before the disc's rip starts.
    static func signs(mountPoint: String, devicePath: String) -> Signs {
        let region = regionMask(ifoAt: (mountPoint as NSString).appendingPathComponent("VIDEO_TS/VIDEO_TS.IFO"))
        let raw = devicePath.replacingOccurrences(of: "/dev/disk", with: "/dev/rdisk")
        let scrambled = DiscReads.shared.enumerating { isScrambled(rawDevice: raw) }
        return Signs(scrambled: scrambled, regionMask: region)
    }

    /// The region mask of a DVD's VIDEO_TS.IFO (byte 0x23), or nil if it isn't one.
    static func regionMask(ifoAt path: String) -> UInt8? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        return regionMask(ifoHeader: handle.readData(ofLength: 0x24))
    }

    static func regionMask(ifoHeader data: Data) -> UInt8? {
        let bytes = [UInt8](data)
        guard bytes.count >= 0x24, String(bytes: bytes[0..<12], encoding: .ascii) == "DVDVIDEO-VMG" else { return nil }
        return bytes[0x23]
    }

    /// Whether libdvdcss finds CSS on the disc; nil if the drive won't open.
    static func isScrambled(rawDevice: String) -> Bool? {
        guard let handle = dvdcss_open(rawDevice) else { return nil }
        defer { _ = dvdcss_close(handle) }
        return dvdcss_is_scrambled(handle) != 0
    }
}

/// Filing a finished rip as a home video: chosen in the "Which film is this?"
/// window or in Review Rips after the disc ripped as a film.
enum HomeVideoFiler {

    /// disc_info.json's record of when the disc was made.
    static let discCreatedKey = "disc_created"

    /// The home video a rip of the disc labelled `label` is: dated from the
    /// label, else from when the disc was made (disc_info.json), else `fallback`.
    static func info(forRipIn folder: String, label: String, fallback: Date = Date()) -> HomeVideoInfo {
        if let date = HomeVideoDetector.date(fromLabel: label) { return HomeVideoInfo(date: date, label: nil) }
        return HomeVideoInfo(date: discCreated(in: folder) ?? fallback, label: HomeVideoDetector.displayLabel(label))
    }

    static func discCreated(in folder: String) -> Date? {
        let path = (folder as NSString).appendingPathComponent("disc_info.json")
        guard let data = FileManager.default.contents(atPath: path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = json[discCreatedKey] as? String else { return nil }
        return ISO8601DateFormatter().date(from: text)
    }

    /// Move `folder` into `root` as `info`'s folder, its videos named the home
    /// video way ("2016-11-30 5th Grade.mkv", numbered when there are several,
    /// in disc order). A film's nfo is dropped. The rip history and Review Rips
    /// follow the move. Returns the new folder.
    @discardableResult
    static func file(folder: String, as info: HomeVideoInfo, into root: String,
                     history: RipHistoryStore = .shared, pending: PendingRoutingQueue = .shared,
                     fileManager: FileManager = .default) throws -> String {
        let names = try fileManager.contentsOfDirectory(atPath: folder)
        for name in names where name.lowercased().hasSuffix(".nfo") {
            try fileManager.removeItem(atPath: (folder as NSString).appendingPathComponent(name))
        }
        let videos = names.filter { $0.lowercased().hasSuffix(".mkv") }.sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
        // Through temporary names, so a new name never lands on an old one.
        var staged: [String] = []
        for (index, name) in videos.enumerated() {
            let temporary = ".home-\(index)-\(UUID().uuidString).mkv"
            try fileManager.moveItem(atPath: (folder as NSString).appendingPathComponent(name),
                                     toPath: (folder as NSString).appendingPathComponent(temporary))
            staged.append(temporary)
        }
        for (index, temporary) in staged.enumerated() {
            try fileManager.moveItem(atPath: (folder as NSString).appendingPathComponent(temporary),
                                     toPath: (folder as NSString).appendingPathComponent(
                                        info.fileName(index: index, total: staged.count)))
        }
        try fileManager.createDirectory(atPath: root, withIntermediateDirectories: true)
        let wanted = (root as NSString).appendingPathComponent(info.folderName)
        let destination = fileManager.fileExists(atPath: wanted)
            ? LibraryFiles.uniqueFolderPath(wanted, fileManager: fileManager) : wanted
        try LibraryFiles.moveFolder(folder, to: destination, fileManager: fileManager)
        history.updateOutputLocation(from: folder, to: destination)
        pending.updateFolder(from: folder, to: destination)
        return destination
    }
}
