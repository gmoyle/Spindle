import Foundation

/// Discs macOS renames while they're in the drive. A music CD mounts as
/// "Audio CD" and is renamed to its album a few seconds later, and its track
/// files with it, so a rip that began under the first name can't go on.
extension MainViewController {

    /// Earlier mount points of the disc on `device`, other than `mountPoint`.
    static func staleMounts(ofDevice device: String, renamedTo mountPoint: String,
                            in mountDevices: [String: String]) -> [String] {
        guard !device.isEmpty else { return [] }
        return mountDevices.filter { $0.value == device && $0.key != mountPoint }.map(\.key).sorted()
    }

    /// The disc was renamed since `drive` was detected (a lookup for its old
    /// name just finished): it's ripped under the new name, not this one.
    func wasRenamedAway(_ drive: OpticalDrive) -> Bool {
        guard renamedMounts.contains(drive.mountPoint) else { return false }
        appendToLog("Not ripping \(drive.name): macOS renamed the disc, and it's ripped under its new name.")
        return true
    }

    /// The disc on `device` now mounts at `mountPoint`: cancel any rip still
    /// reading it under an earlier name (quietly; the new name rips it again)
    /// and forget that name.
    func supersedeReads(onDevice device: String, renamedTo mountPoint: String) {
        let stale = Self.staleMounts(ofDevice: device, renamedTo: mountPoint, in: mountDevices)
        guard !stale.isEmpty else { return }
        for job in conversionQueue.getAllJobs()
        where stale.contains(job.sourcePath) && (job.status == .pending || job.status == .extracting) {
            supersededJobs.insert(job.id)
            appendToLog("\(job.discTitle) was renamed by macOS while being read; "
                        + "ripping it again under its new name.")
            conversionQueue.cancelJob(id: job.id)
        }
        detectedDrives.removeAll { stale.contains($0.mountPoint) }
        for path in stale {
            renamedMounts.insert(path)
            mountDevices[path] = nil
            discLookups[path] = nil
            homeVideoMounts.remove(path)
        }
    }
}
