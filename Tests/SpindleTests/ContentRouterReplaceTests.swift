import XCTest
@testable import Spindle

/// Re-ripping a disc already in the library replaces its files in place;
/// another disc of the same film joins the folder as an edition; a TV rip
/// from a different disc with the same folder name still gets a " (2)" folder.
final class ContentRouterReplaceTests: XCTestCase {
    private var base = ""
    private var moviesRoot = ""
    private var history: RipHistoryStore!
    private var originalRoot = ""
    private let fm = FileManager.default

    override func setUpWithError() throws {
        base = NSTemporaryDirectory().appending("route-replace-\(UUID().uuidString)")
        moviesRoot = (base as NSString).appendingPathComponent("Movies")
        try fm.createDirectory(atPath: moviesRoot, withIntermediateDirectories: true)
        history = RipHistoryStore(fileURL: URL(fileURLWithPath: base).appendingPathComponent("history.json"))
        originalRoot = SettingsManager.shared.moviesRootDirectory
        SettingsManager.shared.moviesRootDirectory = moviesRoot
    }

    override func tearDown() {
        SettingsManager.shared.moviesRootDirectory = originalRoot
        try? fm.removeItem(atPath: base)
    }

    private func makeRip(_ contents: String) throws -> String {
        let folder = (base as NSString).appendingPathComponent("staging-\(UUID().uuidString)/Film (1985)")
        try fm.createDirectory(atPath: folder, withIntermediateDirectories: true)
        fm.createFile(atPath: folder + "/Film (1985).mkv", contents: Data(contents.utf8))
        return folder
    }

    private func existingLibraryFolder(identity: String) throws -> String {
        let library = (moviesRoot as NSString).appendingPathComponent("Film (1985)")
        try fm.createDirectory(atPath: library, withIntermediateDirectories: true)
        fm.createFile(atPath: library + "/Film (1985).mkv", contents: Data("old".utf8))
        fm.createFile(atPath: library + "/poster.jpg", contents: Data("art".utf8))
        history.record(RipHistoryEntry(discIdentity: identity, volumeName: "FILM", title: "Film (1985)",
                                       settingsFingerprint: [:],
                                       outputLocation: library, completedAt: Date()))
        return library
    }

    func testSameDiscReplacesFilesInPlace() throws {
        let library = try existingLibraryFolder(identity: "FILM#abc")
        let rip = try makeRip("new")
        let dest = try ContentRouter.route(folderPath: rip, to: .movie, discIdentity: "FILM#abc",
                                           history: history)
        XCTAssertEqual(dest, library)
        XCTAssertEqual(try String(contentsOfFile: library + "/Film (1985).mkv"), "new")
        XCTAssertTrue(fm.fileExists(atPath: library + "/poster.jpg"))   // unrelated files kept
        XCTAssertFalse(fm.fileExists(atPath: library + " (2)"))
        XCTAssertFalse(fm.fileExists(atPath: rip))
        XCTAssertTrue(try fm.contentsOfDirectory(atPath: library).allSatisfy { !$0.contains(".partial-") })
    }

    func testDifferentDiscOfAFilmJoinsItsFolderAsAnEdition() throws {
        let library = try existingLibraryFolder(identity: "FILM#abc")
        let rip = try makeRip("other")
        let dest = try ContentRouter.route(folderPath: rip, to: .movie, discIdentity: "OTHER#def",
                                           history: history)
        XCTAssertEqual(dest, library)
        XCTAssertEqual(try String(contentsOfFile: library + "/Film (1985).mkv"), "old")
        XCTAssertEqual(try String(contentsOfFile: library + "/Film (1985) {edition-Version 2}.mkv"), "other")
        XCTAssertFalse(fm.fileExists(atPath: library + " (2)"))
    }

    func testDifferentTVDiscGetsSuffixedFolder() throws {
        let tvRoot = (base as NSString).appendingPathComponent("TV")
        let originalTV = SettingsManager.shared.tvShowsRootDirectory
        SettingsManager.shared.tvShowsRootDirectory = tvRoot
        defer { SettingsManager.shared.tvShowsRootDirectory = originalTV }
        let existing = (tvRoot as NSString).appendingPathComponent("Film (1985)")
        try fm.createDirectory(atPath: existing, withIntermediateDirectories: true)
        let dest = try ContentRouter.route(folderPath: try makeRip("x"), to: .tvShow, history: history)
        XCTAssertEqual(dest, existing + " (2)")
    }
}
