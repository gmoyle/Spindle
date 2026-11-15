import XCTest
@testable import Spindle

/// Import Media: what a picked folder holds, and that imports never reach a
/// real device.
final class MediaImportTests: XCTestCase {

    private var root: String!
    private let fm = FileManager.default

    override func setUp() {
        super.setUp()
        root = NSTemporaryDirectory() + "MediaImportTests-\(UUID().uuidString)"
        try? fm.createDirectory(atPath: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? fm.removeItem(atPath: root)
        super.tearDown()
    }

    private func file(_ relative: String) {
        let path = root + "/" + relative
        try? fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        fm.createFile(atPath: path, contents: Data("x".utf8))
    }

    func testADriveOfCopiedDiscsImagesAndPhotos() {
        file("Movies/Heat (1995)/VIDEO_TS/VIDEO_TS.IFO")
        file("Movies/Heat (1995)/VIDEO_TS/VTS_01_1.VOB")
        file("Movies/Dune/BDMV/index.bdmv")
        file("Movies/Alien.iso")
        file("Movies/notes.txt")
        file("Pictures/2004/IMG_0001.JPG")
        file("Pictures/2004/IMG_0002.JPG")
        file("Documents/taxes.pdf")

        let result = MediaImportScanner.scan(root)

        let movies: String = root + "/Movies"
        let expected: [ImportUnit] = [
            .files(path: root + "/Documents", kind: .dataDisc),
            .image(path: movies + "/Alien.iso"),
            .disc(path: movies + "/Dune", kind: .bluray),
            .disc(path: movies + "/Heat (1995)", kind: .dvd),
            .files(path: root + "/Pictures", kind: .photoDisc)
        ]
        XCTAssertEqual(result.units, expected)
        XCTAssertEqual(result.looseFiles, 1, "notes.txt beside the discs is left alone")
        XCTAssertEqual(MediaImportScanner.summary(of: result.units),
                       "1 folder of other files, 1 disc image, 1 Blu-ray, 1 DVD and 1 folder of photos")
    }

    func testPickingTheVideoTSFolderImportsItsDisc() {
        file("HEAT/VIDEO_TS/VIDEO_TS.IFO")
        XCTAssertEqual(MediaImportScanner.scan(root + "/HEAT/VIDEO_TS").units,
                       [.disc(path: root + "/HEAT", kind: .dvd)])
    }

    func testAnImageFileOrAPlainFolder() {
        file("Alien.iso")
        file("Camera/DSC_1.jpg")
        file("Camera/DSC_2.nef")
        file("Camera/readme.txt")
        XCTAssertEqual(MediaImportScanner.scan(root + "/Alien.iso").units, [.image(path: root + "/Alien.iso")])
        XCTAssertEqual(MediaImportScanner.scan(root + "/Camera").units,
                       [.files(path: root + "/Camera", kind: .photoDisc)])
        XCTAssertEqual(MediaImportScanner.scan(root + "/missing").units, [])
    }

    func testSummaryCountsLikeThings() {
        let units: [ImportUnit] = [.disc(path: "/a", kind: .dvd), .disc(path: "/b", kind: .dvd),
                                   .files(path: "/c", kind: .photoDisc), .files(path: "/d", kind: .photoDisc)]
        XCTAssertEqual(MediaImportScanner.summary(of: units), "2 DVDs and 2 folders of photos")
    }

    func testTheConfirmationListsWhatWasFoundAndWhatIsLeft() {
        let found = MediaImportScanner.Result(units: [.disc(path: "/x/Heat (1995)", kind: .dvd)], looseFiles: 2)
        let text = MainViewController.importDetails(found)
        XCTAssertTrue(text.hasPrefix("• Heat (1995) (DVD)"))
        XCTAssertTrue(text.contains("2 other files beside them won't be imported"))
    }

    // MARK: Never a real device

    func testAnImportedFolderOpensAsFilesAndHasNoDevice() {
        let folder = root + "/HEAT"
        file("HEAT/VIDEO_TS/VIDEO_TS.IFO")
        let source = ImportSources.Source(mountPoint: folder, devicePath: ImportSources.folderDevicePrefix + "1",
                                          imagePath: nil)
        ImportSources.shared.add(source)
        defer { ImportSources.shared.remove(folder) }

        XCTAssertEqual(ImportSources.shared.makeMKVSpec(for: folder), "file:\(folder)")
        XCTAssertTrue(ImportSources.shared.isFolder(folder))
        XCTAssertNil(MediaRipper().findRawDVDDevice(dvdPath: folder),
                     "diskutil would name the disk the folder is on")
        XCTAssertEqual(ImportSources.shared.source(forDevice: source.devicePath), source)
        XCTAssertNil(ImportSources.shared.makeMKVSpec(for: "/Volumes/HEAT"), "a real disc isn't an import")
    }

    func testAMountedImageReadsItsOwnDevice() {
        let mount = ImportSources.mountRoot + "/u/HEAT"
        ImportSources.shared.add(ImportSources.Source(mountPoint: mount, devicePath: "/dev/disk20",
                                                      imagePath: "/x/HEAT.iso"))
        defer { ImportSources.shared.remove(mount) }
        XCTAssertEqual(MediaRipper().findRawDVDDevice(dvdPath: mount), "/dev/rdisk20")
        XCTAssertFalse(ImportSources.shared.isFolder(mount))
        XCTAssertTrue(ImportSources.isImportMount(mount), "the drive detector ignores it")
    }

    func testAnImportedFolderOfFilesIsADataDiscNotUnknown() {
        file("Docs/a.pdf")
        let folder = root + "/Docs"
        XCTAssertEqual(DiscClassifier.classify(volumeAt: folder, isOpticalMedia: { _ in false }), .unknown)
        ImportSources.shared.add(ImportSources.Source(mountPoint: folder, devicePath: "import:2", imagePath: nil))
        defer { ImportSources.shared.remove(folder) }
        XCTAssertEqual(DiscClassifier.classify(volumeAt: folder), .dataDisc)
    }

    func testParsesHdiutilAttach() throws {
        let plist: [String: Any] = ["system-entities": [
            ["dev-entry": "/dev/disk20", "content-hint": "GUID_partition_scheme"],
            ["dev-entry": "/dev/disk20s1", "mount-point": "/tmp/m/HEAT"]
        ]]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        XCTAssertEqual(DiskImageMount.parseAttach(data),
                       DiskImageMount.Mounted(mountPoint: "/tmp/m/HEAT", devicePath: "/dev/disk20"))
        XCTAssertNil(DiskImageMount.parseAttach(Data("not a plist".utf8)))
    }
}
