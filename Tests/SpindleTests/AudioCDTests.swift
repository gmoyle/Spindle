import XCTest
@testable import Spindle

/// Music CDs: the TOC, the MusicBrainz disc ID and lookup, library naming, FLAC.
final class AudioCDTOCTests: XCTestCase {

    /// MusicBrainz's documented example disc: 6 tracks, lead-out 95462 (lead-in included).
    let example = AudioCDTOC(firstTrack: 1, lastTrack: 6,
                             trackOffsets: [0, 15213, 32164, 46442, 63264, 80339], leadout: 95312)

    func testMusicBrainzDiscID() {
        XCTAssertEqual(example.musicBrainzDiscID, "49HHV7Eb8UKF3aQiNmu1GR8vKTY-")
    }

    func testTOCParameterIncludesLeadIn() {
        XCTAssertEqual(example.musicBrainzTOCParameter, "1+6+95462+150+15363+32314+46592+63414+80489")
    }

    func testTrackDurations() {
        XCTAssertEqual(example.trackDurations.first ?? 0, 15213.0 / 75, accuracy: 0.001)
        XCTAssertEqual(example.trackDurations.count, 6)
    }

    private func plist(sessions: [[String: Any]]) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: ["Sessions": sessions], format: .xml, options: 0)
    }

    private func track(_ point: Int, _ start: Int, data: Bool = false) -> [String: Any] {
        ["Point": point, "Start Block": start, "Data": data, "Session Number": 1]
    }

    func testParsesCDDAFSPlist() throws {
        // cddafs's blocks include the 150-sector lead-in: track 1 starts at 150.
        let data = try plist(sessions: [[
            "First Track": 1, "Last Track": 6, "Leadout Block": 95462, "Session Number": 1,
            "Track Array": [150, 15363, 32314, 46592, 63414, 80489].enumerated().map { track($0.offset + 1, $0.element) }
        ]])
        XCTAssertEqual(AudioCDTOC.parse(plistData: data), example)
    }

    func testRealCDGivesItsMusicBrainzDiscID() throws {
        // The .TOC.plist of Adele's 25 (14 tracks), as macOS mounted it.
        let starts = [150, 22312, 39043, 65190, 87008, 105415, 123447, 140354,
                      161800, 178830, 199215, 218092, 232969, 253249]
        let data = try plist(sessions: [[
            "First Track": 1, "Last Track": 14, "Leadout Block": 271166, "Session Number": 1,
            "Track Array": starts.enumerated().map { track($0.offset + 1, $0.element) }
        ]])
        let toc = try XCTUnwrap(AudioCDTOC.parse(plistData: data))
        XCTAssertEqual(toc.musicBrainzDiscID, "TCsIUtUShPnxpAHuTJ7rFRW6k4k-")
        XCTAssertEqual(toc.trackOffsets.first, 0)
    }

    func testEnhancedCDLeavesOutTheDataTrack() throws {
        // Audio session, then a data session: audio ends 11,400 sectors before the data.
        let data = try plist(sessions: [
            ["Leadout Block": 150150, "Track Array": [track(1, 150), track(2, 60150)]],
            ["Leadout Block": 300150, "Track Array": [track(3, 161550, data: true)]]
        ])
        let toc = try XCTUnwrap(AudioCDTOC.parse(plistData: data))
        XCTAssertEqual(toc.lastTrack, 2)
        XCTAssertEqual(toc.leadout, 150000)
    }

    func testRejectsGarbage() {
        XCTAssertNil(AudioCDTOC.parse(plistData: Data("not a plist".utf8)))
    }
}

final class MusicBrainzParsingTests: XCTestCase {

    /// Trimmed from a real /ws/2/discid response for the example disc.
    let response = """
    {"id": "49HHV7Eb8UKF3aQiNmu1GR8vKTY-", "releases": [{"id": "d3dc4be9-9749-4959-99e5-133d0cb467fe", "title": "Ettella Diamant", "date": "2004", "status": "Official", "artist-credit": [{"name": "Ettella Diamant", "joinphrase": ""}], "media": [{"position": 1, "format": "CD", "track-count": 6, "discs": [{"id": "49HHV7Eb8UKF3aQiNmu1GR8vKTY-"}], "tracks": [{"position": 1, "number": "1", "title": "Rysperdal Gstp", "length": 202840, "recording": {"id": "9b743096-62a0-493f-9d8a-bdde49ca0669"}, "artist-credit": [{"name": "Ettella Diamant", "joinphrase": ""}]}, {"position": 2, "number": "2", "title": "Nicotine", "length": 226013, "recording": {"id": "34c82fdc-463f-4879-b3d1-c30452870ea9"}, "artist-credit": [{"name": "Ettella Diamant", "joinphrase": ""}]}, {"position": 3, "number": "3", "title": "Genius", "length": 190373, "recording": {"id": "b51bb757-bac7-4ef5-9b96-aadc0ea7cb89"}, "artist-credit": [{"name": "Ettella Diamant", "joinphrase": ""}]}, {"position": 4, "number": "4", "title": "Twilight", "length": 224293, "recording": {"id": "af76f7ba-228e-4c9b-b118-5c686450a037"}, "artist-credit": [{"name": "Ettella Diamant", "joinphrase": ""}]}, {"position": 5, "number": "5", "title": "Dunkelheit", "length": 227666, "recording": {"id": "b822f6f9-d3ec-4641-8e2c-d0b22f13056b"}, "artist-credit": [{"name": "Ettella Diamant", "joinphrase": ""}]}, {"position": 6, "number": "6", "title": "Smog", "length": 199640, "recording": {"id": "ebc7c849-5192-4a7b-8710-0b22998dee2a"}, "artist-credit": [{"name": "Ettella Diamant", "joinphrase": ""}]}]}]}]}
    """

    func testParsesRelease() throws {
        let album = try XCTUnwrap(MusicBrainzProvider.parseDiscIDResponse(
            Data(response.utf8), discID: "49HHV7Eb8UKF3aQiNmu1GR8vKTY-", trackDurations: Array(repeating: 0, count: 6)))
        XCTAssertEqual(album.title, "Ettella Diamant")
        XCTAssertEqual(album.artist, "Ettella Diamant")
        XCTAssertEqual(album.year, "2004")
        XCTAssertEqual(album.tracks.count, 6)
        XCTAssertEqual(album.tracks[0].title, "Rysperdal Gstp")
        XCTAssertEqual(album.discNumber, 1)
        XCTAssertEqual(album.discCount, 1)
        XCTAssertEqual(album.musicBrainzReleaseID, "d3dc4be9-9749-4959-99e5-133d0cb467fe")
    }

    func testPicksTheMediumWithThisDisc() throws {
        // A two-CD set: this disc is medium 2.
        let json = """
        {"releases":[{"id":"r1","title":"Double","date":"1999-05-01","status":"Official",
          "artist-credit":[{"name":"Band","joinphrase":""}],
          "media":[
            {"position":1,"track-count":1,"discs":[{"id":"other"}],"tracks":[{"position":1,"title":"A"}]},
            {"position":2,"track-count":1,"discs":[{"id":"this"}],"tracks":[{"position":1,"title":"B",
              "artist-credit":[{"name":"Band","joinphrase":" feat. "},{"name":"Guest","joinphrase":""}]}]}
          ]}]}
        """
        let album = try XCTUnwrap(MusicBrainzProvider.parseDiscIDResponse(Data(json.utf8), discID: "this", trackDurations: [60]))
        XCTAssertEqual(album.discNumber, 2)
        XCTAssertEqual(album.discCount, 2)
        XCTAssertEqual(album.tracks[0].title, "B")
        XCTAssertEqual(album.tracks[0].artist, "Band feat. Guest")
        XCTAssertEqual(album.year, "1999")
    }

    func testNoReleasesIsUnknown() {
        XCTAssertNil(MusicBrainzProvider.parseDiscIDResponse(Data(#"{"error":"Not Found"}"#.utf8), discID: "x", trackDurations: [1, 2, 3]))
    }

    private func nearMatch(lengthsMs: [Int]) -> Data {
        let tracks = lengthsMs.enumerated().map { #"{"position":\#($0.offset + 1),"title":"T","length":\#($0.element)}"# }
        return Data(#"{"releases":[{"id":"r","title":"Some Compilation","status":"Official","#
            .appending(#""artist-credit":[{"name":"Various Artists"}],"#)
            .appending(#""media":[{"position":1,"track-count":\#(lengthsMs.count),"discs":[{"id":"someone-else"}],"#)
            .appending(#""tracks":[\#(tracks.joined(separator: ","))]}]}]}"#).utf8)
    }

    func testNearMatchWithDifferentTrackLengthsIsRejected() {
        // The same track count isn't enough: a different album came back for Adele's 25.
        XCTAssertNil(MusicBrainzProvider.parseDiscIDResponse(
            nearMatch(lengthsMs: [200_000, 180_000]), discID: "mine", trackDurations: [295, 223]))
    }

    func testNearMatchWithTheSameTrackLengthsIsAccepted() {
        let album = MusicBrainzProvider.parseDiscIDResponse(
            nearMatch(lengthsMs: [295_400, 222_100]), discID: "mine", trackDurations: [295, 223])
        XCTAssertEqual(album?.title, "Some Compilation")
    }
}

final class MusicLibraryNamingTests: XCTestCase {

    let album = AlbumRelease(title: "Hits: Vol. 1?", artist: "AC/DC", year: "1980", discNumber: 2, discCount: 2,
                             tracks: [.init(number: 3, title: "Back in Black", artist: "AC/DC"),
                                      .init(number: 4, title: "Duet", artist: "Guest")])

    func testFolderLayout() {
        XCTAssertEqual(MusicLibraryNaming.albumFolder(for: album, in: "/Volumes/Media/Music"),
                       "/Volumes/Media/Music/AC_DC/Hits_ Vol. 1_ (1980)")
        XCTAssertEqual(MusicLibraryNaming.discFolder(for: album, in: "/M"), "/M/AC_DC/Hits_ Vol. 1_ (1980)/Disc 2")
    }

    func testTrackFileNames() {
        XCTAssertEqual(MusicLibraryNaming.trackFileName(album.tracks[0], of: album), "03 - Back in Black.flac")
        XCTAssertEqual(MusicLibraryNaming.trackFileName(album.tracks[1], of: album), "04 - Guest - Duet.flac")
    }

    func testUnknownAlbumsStayApart() {
        let first = AlbumRelease.unknown(trackCount: 3, discID: "AAAAAAAAxyz")
        XCTAssertEqual(first.title, "Unknown Album (AAAAAAAA)")
        XCTAssertEqual(first.tracks.map(\.title), ["Track 01", "Track 02", "Track 03"])
    }

    func testCDSettingsIgnoreVideoSettings() {
        func config(_ codec: MediaRipper.RippingConfiguration.VideoCodec) -> MediaRipper.RippingConfiguration {
            MediaRipper.RippingConfiguration(outputDirectory: "/tmp", selectedTitles: [], videoCodec: codec,
                                             audioCodec: .aac, quality: .high, includeSubtitles: true,
                                             includeChapters: true, mediaType: .audioCD)
        }
        XCTAssertEqual(ConversionQueue.settingsFingerprint(of: config(.h264)),
                       ConversionQueue.settingsFingerprint(of: config(.h265)))
    }

    func testFindsTrackFilesInOrder() throws {
        let volume = FileManager.default.temporaryDirectory.appendingPathComponent("cd-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: volume, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: volume) }
        for name in ["10 Audio Track.aiff", "2 Audio Track.aiff", "1 Audio Track.aiff", ".TOC.plist"] {
            try Data([0]).write(to: volume.appendingPathComponent(name))
        }
        XCTAssertEqual(MediaRipper.audioTrackFiles(inVolumeAt: volume.path).map(\.number), [1, 2, 10])
    }
}

/// Runs the real ffmpeg on a short tone to check the FLAC comes out tagged and
/// with the cover embedded. Skipped where Homebrew's ffmpeg isn't installed.
final class FLACEncodeTests: XCTestCase {

    func testEncodesTaggedFLACWithCover() throws {
        let ffmpeg = "/opt/homebrew/bin/ffmpeg", ffprobe = "/opt/homebrew/bin/ffprobe"
        guard FileManager.default.isExecutableFile(atPath: ffmpeg),
              FileManager.default.isExecutableFile(atPath: ffprobe) else { throw XCTSkip("no ffmpeg") }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("flac-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let aiff = dir.appendingPathComponent("01.aiff").path
        let cover = dir.appendingPathComponent("cover.jpg").path
        let flac = dir.appendingPathComponent("01.flac").path
        XCTAssertEqual(run(ffmpeg, ["-v", "error", "-f", "lavfi", "-i", "sine=duration=1", "-ac", "2", "-ar", "44100", aiff]).status, 0)
        XCTAssertEqual(run(ffmpeg, ["-v", "error", "-f", "lavfi", "-i", "color=red:s=64x64", "-frames:v", "1", cover]).status, 0)

        let album = AlbumRelease(title: "Album", artist: "Artist", year: "1985", discNumber: 1, discCount: 1,
                                 tracks: [.init(number: 1, title: "Song", artist: "Artist", musicBrainzRecordingID: "rec-1")],
                                 musicBrainzReleaseID: "rel-1")
        let args = MediaRipper.flacEncodeArguments(input: aiff, cover: cover, output: flac,
                                                   track: album.tracks[0], album: album)
        XCTAssertEqual(run(ffmpeg, ["-v", "error"] + args).status, 0)

        let probe = run(ffprobe, ["-v", "error", "-show_entries", "stream=codec_name:format_tags", "-of", "default", flac]).output
        XCTAssertTrue(probe.contains("codec_name=flac"))
        XCTAssertTrue(probe.contains("codec_name=mjpeg"), "cover should be embedded")
        for tag in ["TITLE=Song", "ALBUM=Album", "ARTIST=Artist", "DATE=1985", "track=1", "MUSICBRAINZ_ALBUMID=rel-1"] {
            XCTAssertTrue(probe.localizedCaseInsensitiveContains(tag), "missing \(tag) in:\n\(probe)")
        }
    }

    private func run(_ exe: String, _ args: [String]) -> (status: Int32, output: String) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: exe)
        task.arguments = args
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        task.standardInput = FileHandle.nullDevice
        guard (try? task.run()) != nil else { return (-1, "") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return (task.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }
}

/// The whole CD path on a fake CD volume: tracks copied to staging, encodes
/// queued, then run, landing as tagged FLACs in Music/Artist/Album (Year)/.
final class AudioCDImportPipelineTests: XCTestCase {

    func testRipsFakeCDIntoMusicLibrary() throws {
        let ffmpeg = "/opt/homebrew/bin/ffmpeg"
        guard FileManager.default.isExecutableFile(atPath: ffmpeg) else { throw XCTSkip("no ffmpeg") }
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("cdpipe-\(UUID().uuidString)")
        let volume = base.appendingPathComponent("Audio CD")
        let music = base.appendingPathComponent("Music")
        try fm.createDirectory(at: volume, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }

        for number in 1...2 {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: ffmpeg)
            task.arguments = ["-v", "error", "-f", "lavfi", "-i", "sine=duration=1", "-ac", "2", "-ar", "44100",
                              volume.appendingPathComponent("\(number) Audio Track.aiff").path]
            task.standardOutput = FileHandle.nullDevice
            task.standardError = FileHandle.nullDevice
            try task.run()
            task.waitUntilExit()
        }
        let toc: [String: Any] = ["Sessions": [["Leadout Block": 300, "Track Array": [
            ["Point": 1, "Start Block": 150, "Data": false], ["Point": 2, "Start Block": 225, "Data": false]]]]]
        try PropertyListSerialization.data(fromPropertyList: toc, format: .xml, options: 0)
            .write(to: volume.appendingPathComponent(".TOC.plist"))

        let album = AlbumRelease(title: "Fake", artist: "Tester", year: "2026", discNumber: 1, discCount: 1,
                                 tracks: [.init(number: 1, title: "One", artist: "Tester"),
                                          .init(number: 2, title: "Two", artist: "Tester")])
        var config = MediaRipper.RippingConfiguration(
            outputDirectory: music.path, selectedTitles: [], videoCodec: .h264, audioCodec: .aac,
            quality: .high, includeSubtitles: true, includeChapters: true, mediaType: .audioCD)
        config.album = album

        let ripper = MediaRipper()
        try ripper.performAudioCDRipping(cdPath: volume.path, configuration: config)
        XCTAssertEqual(ripper.pendingEncodes.count, 2)
        for encode in ripper.pendingEncodes {
            XCTAssertTrue(ripper.runEncode(encode))
            try fm.moveItem(atPath: encode.stagingPath, toPath: encode.outputPath)
        }
        ripper.removeStagingDirectories()

        let folder = music.appendingPathComponent("Tester/Fake (2026)")
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: folder.path).sorted(), ["01 - One.flac", "02 - Two.flac"])
        XCTAssertTrue(ripper.stagingDirectoriesToRemove.isEmpty)
    }
}
