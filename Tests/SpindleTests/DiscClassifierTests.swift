import XCTest
@testable import Spindle

/// A disc's kind is decided from what's on it.
final class DiscClassifierTests: XCTestCase {

    private var volume: URL!

    override func setUpWithError() throws {
        volume = FileManager.default.temporaryDirectory.appendingPathComponent("disc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: volume, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: volume)
    }

    private func make(_ paths: String...) throws {
        for path in paths {
            let url = volume.appendingPathComponent(path)
            if path.hasSuffix("/") {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            } else {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                try Data([0]).write(to: url)
            }
        }
    }

    private func classify(optical: Bool = true) -> DiscKind {
        DiscClassifier.classify(volumeAt: volume.path, isOpticalMedia: { _ in optical })
    }

    func testVideoDiscs() throws {
        try make("VIDEO_TS/VIDEO_TS.IFO")
        XCTAssertEqual(classify(), .dvd)
    }

    func testBluRay() throws {
        try make("BDMV/index.bdmv")
        XCTAssertEqual(classify(), .bluray)
    }

    func testHDDVD() throws {
        try make("HVDVD_TS/")
        XCTAssertEqual(classify(), .hddvd)
    }

    func testVideoDiscIsRecognizedEvenWhenNotOptical() throws {
        // A mounted disc image isn't optical media but should still rip.
        try make("VIDEO_TS/VIDEO_TS.IFO")
        XCTAssertEqual(classify(optical: false), .dvd)
    }

    func testAudioCDByTOC() throws {
        try make(".TOC.plist", "1 Audio Track.aiff", "2 Audio Track.aiff")
        XCTAssertEqual(classify(), .audioCD)
    }

    func testAudioCDByTracksAlone() throws {
        try make("1 Audio Track.aiff", "2 Audio Track.aiff")
        XCTAssertEqual(classify(), .audioCD)
    }

    func testPhotoDiscByCameraFolder() throws {
        try make("DCIM/100CANON/IMG_0001.CR2", "readme.txt", "setup.exe")
        XCTAssertEqual(classify(), .photoDisc)
    }

    func testPhotoDiscByShareOfPhotos() throws {
        try make("Vacation/a.jpg", "Vacation/b.JPEG", "Vacation/c.heic", "notes.txt")
        XCTAssertEqual(classify(), .photoDisc)
    }

    func testDataDiscWhenFewPhotos() throws {
        try make("installer.pkg", "manual.pdf", "logo.png", "license.txt")
        XCTAssertEqual(classify(), .dataDisc)
    }

    func testPhotosOnAUSBDriveAreIgnored() throws {
        // Only optical media counts: a camera card or USB stick isn't imported.
        try make("DCIM/100CANON/IMG_0001.JPG")
        XCTAssertEqual(classify(optical: false), .unknown)
    }

    func testEmptyVolumeIsUnknown() {
        XCTAssertEqual(classify(), .unknown)
    }

    func testOnlyVideoKindsAreImportableForNow() {
        XCTAssertTrue(DiscKind.dvd.isImportSupported)
        XCTAssertTrue(DiscKind.bluray4K.isImportSupported)
        XCTAssertFalse(DiscKind.audioCD.isImportSupported)
        XCTAssertFalse(DiscKind.photoDisc.isImportSupported)
        XCTAssertFalse(DiscKind.dataDisc.isImportSupported)
    }

    func testKindsMapToLibraries() {
        XCTAssertEqual(DiscKind.audioCD.library, .music)
        XCTAssertEqual(DiscKind.photoDisc.library, .photos)
        XCTAssertEqual(DiscKind.dataDisc.library, .importedDiscs)
        XCTAssertNil(DiscKind.dvd.library, "video discs are split into Movies or TV after the rip")
    }
}

final class LibraryRootTests: XCTestCase {
    func testNewLibrariesDefaultNextToMovies() {
        XCTAssertEqual(SettingsManager.defaultLibraryRoot(.music, moviesRoot: "/Volumes/Media/Movies"),
                       "/Volumes/Media/Music")
        XCTAssertEqual(SettingsManager.defaultLibraryRoot(.importedDiscs, moviesRoot: "/Volumes/Media/Movies"),
                       "/Volumes/Media/Imported Discs")
    }

    func testVideoClassificationPicksLibrary() {
        XCTAssertEqual(LibraryKind(contentType: .movie), .movies)
        XCTAssertEqual(LibraryKind(contentType: .tvShow), .tvShows)
    }
}

final class MovieMetadataTests: XCTestCase {
    func testSearchTermsFromVolumeLabel() {
        XCTAssertEqual(DiscTitleQuery.candidates(fromVolumeName: "THE_GOONIES_WS"), ["THE GOONIES", "THE GOONIES WS"])
        XCTAssertEqual(DiscTitleQuery.candidates(fromVolumeName: "Hangmen"), ["Hangmen"])
    }

    func testExactTitleBeatsFirstHit() {
        let matches = [MovieMatch(title: "The Goonies 2", year: "2027"), MovieMatch(title: "The Goonies", year: "1985")]
        XCTAssertEqual(DiscTitleQuery.bestMatch(for: "the goonies", in: matches)?.displayName, "The Goonies (1985)")
        XCTAssertEqual(DiscTitleQuery.bestMatch(for: "goonies", in: matches)?.title, "The Goonies 2")
    }

    func testParsesOMDbSearch() {
        let json = #"{"Search":[{"Title":"The Goonies","Year":"1985","Type":"movie"}],"Response":"True"}"#
        XCTAssertEqual(OMDbProvider.parseSearchResponse(Data(json.utf8)), [MovieMatch(title: "The Goonies", year: "1985")])
        XCTAssertEqual(OMDbProvider.parseSearchResponse(Data(#"{"Response":"False"}"#.utf8)), [])
    }
}
