import XCTest
import ImageIO
import UniformTypeIdentifiers
@testable import Spindle

/// A temporary folder per test, removed afterwards.
class TempFolderTestCase: XCTestCase {
    var base = ""
    let fm = FileManager.default

    override func setUpWithError() throws {
        base = NSTemporaryDirectory().appending("spindle-\(type(of: self))-\(UUID().uuidString)")
        try fm.createDirectory(atPath: base, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? fm.removeItem(atPath: base)
    }

    func path(_ relative: String) -> String { (base as NSString).appendingPathComponent(relative) }

    @discardableResult
    func write(_ relative: String, _ contents: String) throws -> String {
        let file = path(relative)
        try fm.createDirectory(atPath: (file as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: URL(fileURLWithPath: file))
        return file
    }

    /// A small JPEG with an EXIF capture date ("2004:07:14 15:32:10").
    @discardableResult
    func writeJPEG(_ relative: String, takenAt exifDate: String?, shade: UInt8 = 128) throws -> String {
        let file = path(relative)
        try fm.createDirectory(atPath: (file as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        let width = 8, height = 8
        var pixels = [UInt8](repeating: shade, count: width * height * 4)
        let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8,
                                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        let image = try XCTUnwrap(context?.makeImage())
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(
            URL(fileURLWithPath: file) as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        var properties: [CFString: Any] = [:]
        if let date = exifDate {
            properties[kCGImagePropertyExifDictionary] = [kCGImagePropertyExifDateTimeOriginal: date]
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return file
    }
}

final class VerifiedCopyTests: TempFolderTestCase {

    func testCopyReturnsHashAndKeepsDates() throws {
        let source = try write("disc/a.txt", "hello")
        let old = Date(timeIntervalSince1970: 1_089_820_000)
        try fm.setAttributes([.modificationDate: old], ofItemAtPath: source)
        let target = path("staging/deep/a.txt")
        let hash = try VerifiedCopy.copy(source, to: target)
        XCTAssertEqual(hash, try VerifiedCopy.sha256(of: source))
        XCTAssertEqual(try String(contentsOfFile: target), "hello")
        let copied = try XCTUnwrap(fm.attributesOfItem(atPath: target)[.modificationDate] as? Date)
        XCTAssertEqual(copied.timeIntervalSince1970, old.timeIntervalSince1970, accuracy: 1)
    }

    func testMissingSourceThrowsAndLeavesNothing() {
        let target = path("staging/missing.txt")
        XCTAssertThrowsError(try VerifiedCopy.copy(path("nope.txt"), to: target))
        XCTAssertFalse(fm.fileExists(atPath: target))
    }
}

final class LibraryFilesTests: TempFolderTestCase {

    func testPlaceFileAddsSuffixUnlessReplacing() throws {
        let existing = try write("lib/a.jpg", "old")
        let placed = try LibraryFiles.placeFile(try write("in/a.jpg", "new"), at: existing, replacing: false)
        XCTAssertEqual(placed, path("lib/a (2).jpg"))
        XCTAssertEqual(try String(contentsOfFile: existing), "old")
        let replaced = try LibraryFiles.placeFile(try write("in/b.jpg", "newer"), at: existing, replacing: true)
        XCTAssertEqual(replaced, existing)
        XCTAssertEqual(try String(contentsOfFile: existing), "newer")
    }

    func testFileFolderMergesReImportOfSameDisc() throws {
        let history = RipHistoryStore(fileURL: URL(fileURLWithPath: path("history.json")))
        let root = path("Imported Discs")
        let library = (root as NSString).appendingPathComponent("BACKUP")
        try write("Imported Discs/BACKUP/docs/a.txt", "old")
        try write("Imported Discs/BACKUP/mine.txt", "keep")
        history.record(RipHistoryEntry(discIdentity: "BACKUP#1", volumeName: "BACKUP", title: "BACKUP",
                                       settingsFingerprint: [:], outputLocation: library, completedAt: Date()))
        try write("staging/BACKUP/docs/a.txt", "new")
        let dest = try LibraryFiles.fileFolder(path("staging/BACKUP"), into: root, discIdentity: "BACKUP#1",
                                               history: history)
        XCTAssertEqual(dest, library)
        XCTAssertEqual(try String(contentsOfFile: library + "/docs/a.txt"), "new")
        XCTAssertTrue(fm.fileExists(atPath: library + "/mine.txt"))

        try write("staging2/BACKUP/x.txt", "other disc")
        let other = try LibraryFiles.fileFolder(path("staging2/BACKUP"), into: root, discIdentity: "BACKUP#2",
                                                history: history)
        XCTAssertEqual(other, library + " (2)")
    }
}

final class PhotoMediaTests: TempFolderTestCase {

    func testParseEXIFDate() throws {
        let date = try XCTUnwrap(PhotoMedia.parseEXIFDate("2004:07:14 15:32:10"))
        let parts = Calendar.current.dateComponents([.year, .month, .day, .hour], from: date)
        XCTAssertEqual([parts.year, parts.month, parts.day, parts.hour], [2004, 7, 14, 15])
        XCTAssertNil(PhotoMedia.parseEXIFDate("0000:00:00 00:00:00"))
        XCTAssertNil(PhotoMedia.parseEXIFDate("garbage"))
    }

    func testCaptureDateFromEXIFThenFileDate() throws {
        let withExif = try writeJPEG("a.jpg", takenAt: "2004:07:14 15:32:10")
        let date = try XCTUnwrap(PhotoMedia.captureDate(of: withExif))
        XCTAssertEqual(PhotoLibraryNaming.folder(for: date, in: "/P"), "/P/2004/2004-07-14")

        let noExif = try writeJPEG("b.jpg", takenAt: nil)
        try fm.setAttributes([.modificationDate: try XCTUnwrap(PhotoMedia.parseEXIFDate("2001:02:03 10:00:00"))],
                             ofItemAtPath: noExif)
        XCTAssertEqual(PhotoLibraryNaming.folder(for: PhotoMedia.captureDate(of: noExif), in: "/P"),
                       "/P/2001/2001-02-03")
        XCTAssertEqual(PhotoLibraryNaming.folder(for: nil, in: "/P"), "/P/Undated")
    }

    func testFilesSkipsHiddenThumbnailsAndOtherFiles() throws {
        try write("DCIM/100CANON/IMG_0001.JPG", "x")
        try write("DCIM/100CANON/MVI_0002.MOV", "x")
        try write("DCIM/100CANON/.hidden.jpg", "x")
        try write("PICTURES/THUMBS/IMG_0001.JPG", "x")
        try write("autorun.inf", "x")
        let (media, skipped) = PhotoMedia.files(under: base)
        XCTAssertEqual(media.map { ($0 as NSString).lastPathComponent }, ["IMG_0001.JPG", "MVI_0002.MOV"])
        XCTAssertEqual(skipped.map { ($0 as NSString).lastPathComponent }, ["autorun.inf"])
    }
}

final class PhotoFilingTests: TempFolderTestCase {
    private var index: PhotoIndex!
    private var root = ""

    override func setUpWithError() throws {
        try super.setUpWithError()
        index = PhotoIndex(fileURL: URL(fileURLWithPath: path("index.json")))
        root = path("Photos")
    }

    private func staged(_ name: String, _ contents: String, date: String? = "2004:07:14 10:00:00")
        throws -> MediaRipper.StagedPhoto {
        let file = try write("staging/\(UUID().uuidString)/\(name)", contents)
        return MediaRipper.StagedPhoto(path: file, hash: try VerifiedCopy.sha256(of: file),
                                       date: date.flatMap(PhotoMedia.parseEXIFDate))
    }

    func testFilesByDateAndRemembersThem() throws {
        let a = try staged("IMG_1.JPG", "one")
        let b = try staged("IMG_2.JPG", "two", date: nil)
        let result = try MediaRipper.filePhotos([a, b], destination: .folder, root: root, index: index)
        XCTAssertEqual(result.files, [root + "/2004/2004-07-14/IMG_1.JPG", root + "/Undated/IMG_2.JPG"])
        XCTAssertEqual(result.location, root)
        XCTAssertTrue(index.isInFolder(a.hash))
        XCTAssertTrue(MediaRipper.isAlreadyImported(a.hash, destination: .folder, index: index))
        XCTAssertFalse(MediaRipper.isAlreadyImported(a.hash, destination: .both, index: index))

        // The index survives a relaunch.
        XCTAssertTrue(PhotoIndex(fileURL: URL(fileURLWithPath: path("index.json"))).isInFolder(b.hash))
    }

    func testSameNameDifferentPhotoGetsSuffixButSameContentIsSkipped() throws {
        try write("Photos/2004/2004-07-14/IMG_1.JPG", "already there")
        let same = try staged("IMG_1.JPG", "already there")
        let other = try staged("IMG_1.JPG", "a different photo")
        let result = try MediaRipper.filePhotos([same, other], destination: .folder, root: root, index: index)
        XCTAssertEqual(result.files, [root + "/2004/2004-07-14/IMG_1 (2).JPG"])
        XCTAssertTrue(index.isInFolder(same.hash))
    }

    func testApplePhotosOnly() throws {
        let a = try staged("IMG_1.JPG", "one")
        var imported: [String] = []
        let result = try MediaRipper.filePhotos([a], destination: .applePhotos, root: root, index: index,
                                                importToApplePhotos: { imported += $0 })
        XCTAssertEqual(imported, [a.path])
        XCTAssertEqual(result.files, [])
        XCTAssertEqual(result.location, "Apple Photos")
        XCTAssertTrue(index.isInApplePhotos(a.hash))
        XCTAssertFalse(fm.fileExists(atPath: root))
    }

    func testApplePhotosRefusedFallsBackToFolder() throws {
        let a = try staged("IMG_1.JPG", "one")
        let result = try MediaRipper.filePhotos([a], destination: .applePhotos, root: root, index: index,
                                                importToApplePhotos: { _ in
            throw ApplePhotosImporter.ImportError.notAllowed
        })
        XCTAssertEqual(result.files, [root + "/2004/2004-07-14/IMG_1.JPG"])
        XCTAssertTrue(result.summary.contains("instead"))
        XCTAssertFalse(index.isInApplePhotos(a.hash))
    }

    func testBothDestinations() throws {
        let a = try staged("IMG_1.JPG", "one")
        var imported = 0
        let result = try MediaRipper.filePhotos([a], destination: .both, root: root, index: index,
                                                importToApplePhotos: { imported += $0.count })
        XCTAssertEqual(imported, 1)
        XCTAssertEqual(result.files.count, 1)
        XCTAssertTrue(MediaRipper.isAlreadyImported(a.hash, destination: .both, index: index))
    }
}

/// Collects what a ripper reports.
private final class RecordingRipperDelegate: MediaRipperDelegate {
    var statuses: [String] = []
    func mediaRipperDidStart() {}
    func mediaRipperDidUpdateStatus(_ status: String) { statuses.append(status) }
    func mediaRipperDidUpdateProgress(_ progress: Double, currentItem: MediaRipper.MediaItem?, totalItems: Int) {}
    func mediaRipperDidComplete() {}
    func mediaRipperDidFail(with error: Error) {}
}

final class CopyOnlyImportTests: TempFolderTestCase {

    private func configuration(_ kind: DiscKind, output: String,
                               photos: PhotoDestination? = nil) -> MediaRipper.RippingConfiguration {
        MediaRipper.RippingConfiguration(
            outputDirectory: output, selectedTitles: [], videoCodec: .h264, audioCodec: .aac, quality: .high,
            includeSubtitles: false, includeChapters: false, mediaType: kind, photoDestination: photos)
    }

    func testPhotoDiscImportSkipsDuplicatesAndFilesByDate() throws {
        let disc = path("PHOTOS_2004")
        try writeJPEG("PHOTOS_2004/DCIM/100CANON/IMG_0001.JPG", takenAt: "2004:07:14 15:32:10", shade: 10)
        try writeJPEG("PHOTOS_2004/DCIM/100CANON/IMG_0002.JPG", takenAt: "2004:07:15 09:00:00", shade: 200)
        // The same photo twice on one disc is imported once.
        try fm.createDirectory(atPath: path("PHOTOS_2004/BACKUP"), withIntermediateDirectories: true)
        try fm.copyItem(atPath: path("PHOTOS_2004/DCIM/100CANON/IMG_0001.JPG"),
                        toPath: path("PHOTOS_2004/BACKUP/IMG_0001.JPG"))
        try write("PHOTOS_2004/readme.txt", "not a photo")

        let ripper = MediaRipper()
        let delegate = RecordingRipperDelegate()
        ripper.delegate = delegate
        let photos = configuration(.photoDisc, output: path("Photos"))
        try ripper.performPhotoDiscImport(discPath: disc, configuration: photos)
        let result = try XCTUnwrap(ripper.postEjectWork)()
        ripper.removeStagingDirectories()

        XCTAssertEqual(result.files.sorted(), [path("Photos/2004/2004-07-14/IMG_0001.JPG"),
                                               path("Photos/2004/2004-07-15/IMG_0002.JPG")])
        XCTAssertTrue(delegate.statuses.contains { $0.contains("1 already imported") && $0.contains("1 other file") })
        XCTAssertTrue(fm.fileExists(atPath: disc + "/DCIM/100CANON/IMG_0001.JPG"), "the disc is never changed")

        // The same disc again brings nothing new.
        let again = MediaRipper()
        try again.performPhotoDiscImport(discPath: disc, configuration: photos)
        XCTAssertEqual(try XCTUnwrap(again.postEjectWork)().files, [])
        again.removeStagingDirectories()
    }

    func testDataDiscIsCopiedAsIs() throws {
        let disc = path("BACKUP_2010")
        try write("BACKUP_2010/Documents/letter.txt", "Dear")
        try write("BACKUP_2010/Music/song.mp3", "la")
        try write("BACKUP_2010/.fseventsd/junk", "x")
        try write("BACKUP_2010/System Volume Information/x", "x")

        let ripper = MediaRipper()
        try ripper.performDataDiscImport(discPath: disc, configuration: configuration(.dataDisc,
                                                                                      output: path("Imported")))
        let result = try XCTUnwrap(ripper.postEjectWork)()
        ripper.removeStagingDirectories()

        let folder = path("Imported/BACKUP_2010")
        XCTAssertEqual(result.location, folder)
        XCTAssertEqual(try String(contentsOfFile: folder + "/Documents/letter.txt"), "Dear")
        XCTAssertTrue(fm.fileExists(atPath: folder + "/Music/song.mp3"))
        XCTAssertFalse(fm.fileExists(atPath: folder + "/System Volume Information"))
        XCTAssertFalse(fm.fileExists(atPath: folder + "/.fseventsd"))
    }

    func testDataDiscFilesList() throws {
        try write("d/a.txt", "1234")
        try write("d/sub/b.txt", "12")
        try write("d/$RECYCLE.BIN/c.txt", "1")
        let (files, bytes) = MediaRipper.dataDiscFiles(under: path("d"))
        XCTAssertEqual(files, ["a.txt", "sub/b.txt"])
        XCTAssertEqual(bytes, 6)
    }

    func testSettingsFingerprints() {
        XCTAssertEqual(ConversionQueue.settingsFingerprint(of: configuration(.dataDisc, output: "/x")),
                       ["format": "copy"])
        XCTAssertEqual(ConversionQueue.settingsFingerprint(of: configuration(.photoDisc, output: "/x",
                                                                             photos: .both)),
                       ["format": "photos", "destination": "both"])
    }

    func testEveryRecognizedKindIsImportable() {
        XCTAssertTrue(DiscKind.photoDisc.isImportSupported)
        XCTAssertTrue(DiscKind.dataDisc.isImportSupported)
        XCTAssertFalse(DiscKind.unknown.isImportSupported)
    }

    func testDataDiscsWithTheSameLabelHaveDifferentIdentities() throws {
        try write("one/CDROM/a.txt", "short")
        try write("two/CDROM/a.txt", "a longer file")
        XCTAssertNotEqual(DiscIdentity.compute(forDiscAt: path("one/CDROM")),
                          DiscIdentity.compute(forDiscAt: path("two/CDROM")))
        XCTAssertTrue(DiscIdentity.compute(forDiscAt: path("one/CDROM")).hasPrefix("CDROM#"))
    }
}

final class HomeVideoTests: XCTestCase {

    func testRecordableMedia() {
        for type in ["DVD-R", "DVD+R", "DVD-RW", "DVD+RW", "DVD-RAM", "DVD+R DL"] {
            XCTAssertTrue(HomeVideoDetector.isRecordable(opticalMediaType: type), type)
        }
        for type in ["DVD-ROM", "CD-ROM", "BD-ROM", ""] {
            XCTAssertFalse(HomeVideoDetector.isRecordable(opticalMediaType: type), type)
        }
        XCTAssertFalse(HomeVideoDetector.isRecordable(opticalMediaType: nil))
        XCTAssertTrue(HomeVideoDetector.isHomeVideo(kind: .dvd, opticalMediaType: "DVD-R"))
        XCTAssertFalse(HomeVideoDetector.isHomeVideo(kind: .dvd, opticalMediaType: "DVD-ROM"))
        XCTAssertFalse(HomeVideoDetector.isHomeVideo(kind: .bluray, opticalMediaType: "BD-R"))
    }

    func testLabels() {
        XCTAssertNil(HomeVideoDetector.displayLabel("DVD_VIDEO"))
        XCTAssertNil(HomeVideoDetector.displayLabel("Untitled"))
        XCTAssertEqual(HomeVideoDetector.displayLabel("BIRTHDAY_PARTY"), "Birthday Party")
        XCTAssertEqual(HomeVideoDetector.displayLabel("Summer at Gran's"), "Summer at Gran's")
        XCTAssertNotNil(HomeVideoDetector.date(fromLabel: "2004_07_14"))
        XCTAssertNotNil(HomeVideoDetector.date(fromLabel: "20040714"))
        XCTAssertNil(HomeVideoDetector.date(fromLabel: "DISC_2004"))
        XCTAssertNil(HomeVideoDetector.date(fromLabel: "12345678"))
    }

    func testNaming() throws {
        let date = try XCTUnwrap(HomeVideoDetector.date(fromLabel: "2004-07-14"))
        let named = HomeVideoInfo(date: date, label: "Birthday Party")
        XCTAssertEqual(named.folderName, "2004-07-14 Birthday Party")
        XCTAssertEqual(named.fileName(index: 0, total: 1), "2004-07-14 Birthday Party.mkv")
        XCTAssertEqual(named.fileName(index: 1, total: 3), "2004-07-14 Birthday Party - 02.mkv")
        XCTAssertEqual(HomeVideoInfo(date: date, label: nil).folderName, "2004-07-14 Home Video")
    }

    func testTitlesToRip() {
        // Three recordings, a duplicate of the first, a 2 s menu loop, and "play all".
        let durations: [Double] = [600, 300, 900, 600, 2, 1800]
        let cells = ["1|a", "1|b", "1|c", "1|a", "2|m", "1|abc"]
        XCTAssertEqual(HomeVideoDetector.titlesToRip(durations: durations, cellKeys: cells), [0, 1, 2])
        // One or two recordings are kept as they are.
        XCTAssertEqual(HomeVideoDetector.titlesToRip(durations: [600, 600], cellKeys: ["a", "b"]), [0, 1])
    }
}
