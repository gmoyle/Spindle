import XCTest
@testable import Spindle

/// The main window's Discs list: discs in the drives and every rip, each with
/// its own Cancel.
final class DiscListTests: XCTestCase {

    private func job(_ title: String, source: String, status: ConversionQueue.JobStatus,
                     added: TimeInterval) -> ConversionQueue.ConversionJob {
        let config = MediaRipper.RippingConfiguration(
            outputDirectory: "/tmp", selectedTitles: [], videoCodec: .h264, audioCodec: .aac,
            quality: .high, includeSubtitles: true, includeChapters: true, mediaType: nil)
        var job = ConversionQueue.ConversionJob(sourcePath: source, outputDirectory: "/tmp",
                                                configuration: config, mediaType: .dvd, discTitle: title)
        job.status = status
        job.addedTime = Date(timeIntervalSince1970: added)
        return job
    }

    func testIdleDiscsComeFirstThenRipsNewestFirst() {
        let drives = [OpticalDrive(mountPoint: "/Volumes/BOFFDEAD", name: "BOFFDEAD", type: .dvd,
                                   devicePath: "/dev/disk4"),
                      OpticalDrive(mountPoint: "/Volumes/ENEMY", name: "ENEMY", type: .dvd,
                                   devicePath: "/dev/disk5")]
        let jobs = [job("Old Film (1990)", source: "/Volumes/OLD", status: .completed, added: 1),
                    job("Enemy of the State (1998)", source: "/Volumes/ENEMY", status: .extracting, added: 2)]
        let rows = DiscListRow.rows(drives: drives, jobs: jobs)

        XCTAssertEqual(rows.map(\.disc), ["BOFFDEAD", "ENEMY", "OLD"], "a disc being ripped is listed once")
        XCTAssertNil(rows[0].jobId)
        XCTAssertFalse(rows[0].canCancel)
        XCTAssertTrue(rows[1].canCancel, "a disc being read can be cancelled")
        XCTAssertEqual(rows[1].title, "Enemy of the State (1998)")
        XCTAssertFalse(rows[2].canCancel, "a finished rip can't")
        XCTAssertEqual(rows[2].progress, "100%")
    }

    func testOnlyQueuedReadingOrEncodingRipsCanBeCancelled() {
        let statuses: [(ConversionQueue.JobStatus, Bool)] = [
            (.pending, true), (.extracting, true), (.extracted, true), (.converting, true),
            (.completed, false), (.cancelled, false), (.failed(ConversionQueueError.sourceNotFound), false)
        ]
        for (status, cancellable) in statuses {
            let row = DiscListRow.rows(drives: [], jobs: [job("A", source: "/Volumes/A", status: status, added: 1)])
            XCTAssertEqual(row.first?.canCancel, cancellable, "\(status)")
        }
    }

    func testAFinishedRipDoesntHideTheDiscStillInTheDrive() {
        let drives = [OpticalDrive(mountPoint: "/Volumes/A", name: "A", type: .dvd, devicePath: "/dev/disk4")]
        let rows = DiscListRow.rows(drives: drives,
                                    jobs: [job("A (2000)", source: "/Volumes/A", status: .completed, added: 1)])
        XCTAssertEqual(rows.count, 2)
        XCTAssertTrue(rows[0].status.hasPrefix("In drive"))
    }
}
