import XCTest
@testable import Spindle

/// Metadata written beside and into rips, for media servers that prefer local
/// metadata: a film's poster, and a home video's title and date.
final class LocalMetadataTests: XCTestCase {

    func testIMDbIDFromALibraryName() {
        XCTAssertEqual(MoviePoster.imdbID(inLibraryName: "Die Hard (1988) {imdb-tt0095016}"), "tt0095016")
        XCTAssertNil(MoviePoster.imdbID(inLibraryName: "Die Hard (1988)"))
        XCTAssertNil(MoviePoster.imdbID(inLibraryName: "Die Hard (1988) {tmdb-562}"))
    }

    func testPosterURLFromOMDb() {
        let found = Data(#"{"Response":"True","Poster":"https://m.media-amazon.com/images/x.jpg"}"#.utf8)
        XCTAssertEqual(MoviePoster.posterURL(inOMDbResponse: found)?.host, "m.media-amazon.com")
        XCTAssertNil(MoviePoster.posterURL(inOMDbResponse: Data(#"{"Response":"True","Poster":"N/A"}"#.utf8)))
        XCTAssertNil(MoviePoster.posterURL(inOMDbResponse: Data(#"{"Response":"False"}"#.utf8)))
    }

    func testPosterIsWrittenWholeAndReplaced() throws {
        let folder = (NSTemporaryDirectory() as NSString).appendingPathComponent("poster-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let path = (folder as NSString).appendingPathComponent(MoviePoster.fileName)

        XCTAssertTrue(MoviePoster.write(Data([1, 2]), to: path))
        XCTAssertTrue(MoviePoster.write(Data([3]), to: path))
        XCTAssertEqual(FileManager.default.contents(atPath: path), Data([3]))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder), [MoviePoster.fileName],
                       "no temporary file left behind")
        XCTAssertFalse(MoviePoster.write(Data([1]), to: "/nonexistent-\(UUID().uuidString)/poster.jpg"))
    }

    func testAnEditionKeepsTheFolderPoster() throws {
        let root = (NSTemporaryDirectory() as NSString).appendingPathComponent("ed-\(UUID().uuidString)")
        let source = (root as NSString).appendingPathComponent("new")
        let destination = (root as NSString).appendingPathComponent("film")
        for dir in [source, destination] {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: (dir as NSString).appendingPathComponent("poster.jpg"),
                                           contents: Data(dir.utf8))
        }
        defer { try? FileManager.default.removeItem(atPath: root) }
        try LibraryFiles.mergeKeepingBoth(from: source, into: destination)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination), ["poster.jpg"])
    }

    func testHomeVideoTags() {
        let info = HomeVideoInfo(date: Date(timeIntervalSince1970: 1_089_806_400), label: "Birthday")  // 2004-07-14
        let day = HomeVideoInfo.dayFormatter.string(from: info.date)
        XCTAssertEqual(info.metadataArguments(title: "\(day) Birthday - 02"),
                       ["-metadata", "title=\(day) Birthday - 02", "-metadata", "date=\(day)",
                        "-metadata", "creation_time=\(day)T12:00:00Z"])
    }
}
