//
//  FileBlockDevice.swift
//  ReixOS
//

import Darwin
import Foundation
import ReixABI

enum FileBlockDeviceError: Error, CustomStringConvertible {
    case live(String)
    case open(String, Int32)
    case lock(String, Int32)
    case geometry(String)

    var description: String {
        switch self {
            case .live(let marker):
                return "disk is live (marker exists: \(marker))"
            case .open(let path, let code):
                return "cannot open \(path) read-write (errno \(code))"
            case .lock(let path, let code):
                return "cannot acquire the offline lock for \(path) (errno \(code))"
            case .geometry(let reason):
                return "invalid disk geometry: \(reason)"
        }
    }
}

/// A bounded host adapter over one raw disk image.
///
/// It owns both a non-blocking advisory lock and a `.live` marker check. The
/// managed QEMU launchers create the marker; the advisory lock also prevents
/// two importers from mutating the same image concurrently.
final class FileBlockDevice: BlockDevice {
    let sectorSize : UInt64          = 512
    let sectorCount: UInt64
    let maximumRun : UInt64          = 8
    let durability : BlockDurability = .onFlush
    let depth      : Int             = 1

    private let descriptor: Int32
    private let transfer  : UnsafeMutableRawPointer
    private var completion: (slot: Int, status: BlockStatus)?

    init(path: String) throws {
        let liveMarker = path + ".live"
        guard !FileManager.default.fileExists(atPath: liveMarker) else {
            throw FileBlockDeviceError.live(liveMarker)
        }

        let fd = Darwin.open(path, O_RDWR | O_CLOEXEC)
        guard fd >= 0 else {
            throw FileBlockDeviceError.open(path, errno)
        }

        guard Self.setLock(fd, type: Int16(F_WRLCK)) else {
            let code = errno
            Darwin.close(fd)
            throw FileBlockDeviceError.lock(path, code)
        }

        var information = stat()
        guard fstat(fd, &information) == 0,
              information.st_size > 0,
              information.st_size % off_t(sectorSize) == 0
        else {
            _ = Self.setLock(fd, type: Int16(F_UNLCK))
            Darwin.close(fd)
            throw FileBlockDeviceError.geometry("size is not a positive multiple of 512 bytes")
        }

        descriptor = fd
        sectorCount = UInt64(information.st_size) / sectorSize
        transfer = UnsafeMutableRawPointer.allocate(
            byteCount: Int(maximumRun * sectorSize),
            alignment: 8
        )
    }

    deinit {
        _ = Self.setLock(descriptor, type: Int16(F_UNLCK))
        _ = Darwin.close(descriptor)
        transfer.deallocate()
    }

    func begin(
        _ count    : UInt64,
        from sector: UInt64,
        slot       : Int
    ) -> BlockStatus {
        guard completion == nil else { return .queueFull }
        let status = read(count, from: sector, into: transfer)
        completion = (slot, status)
        return .ok
    }

    func collect() -> (slot: Int, status: BlockStatus)? {
        defer { completion = nil }
        return completion
    }

    func buffer(of slot: Int) -> UnsafeRawPointer {
        UnsafeRawPointer(transfer)
    }

    func read(
        _ count         : UInt64,
        from sector     : UInt64,
        into destination: UnsafeMutableRawPointer
    ) -> BlockStatus {
        guard let byteCount = checkedByteCount(count, from: sector) else {
            return count > maximumRun ? .tooLong : .outOfRange
        }
        var moved  = 0
        let offset = sector * sectorSize
        while moved < byteCount {
            let result = Darwin.pread(
                descriptor,
                destination.advanced(by: moved),
                byteCount - moved,
                off_t(offset + UInt64(moved))
            )
            if result > 0 {
                moved += result
            } else if result < 0 && errno == EINTR {
                continue
            } else {
                return .deviceRefused
            }
        }
        return .ok
    }

    func write(
        _ count    : UInt64,
        to sector  : UInt64,
        from source: UnsafeRawPointer
    ) -> BlockStatus {
        guard let byteCount = checkedByteCount(count, from: sector) else {
            return count > maximumRun ? .tooLong : .outOfRange
        }
        var moved  = 0
        let offset = sector * sectorSize
        while moved < byteCount {
            let result = Darwin.pwrite(
                descriptor,
                source.advanced(by: moved),
                byteCount - moved,
                off_t(offset + UInt64(moved))
            )
            if result > 0 {
                moved += result
            } else if result < 0 && errno == EINTR {
                continue
            } else {
                return .deviceRefused
            }
        }
        return .ok
    }

    func flush() -> BlockStatus {
        Darwin.fsync(descriptor) == 0 ? .ok : .deviceRefused
    }

    private func checkedByteCount(
        _ count    : UInt64,
        from sector: UInt64
    ) -> Int? {
        guard count <= maximumRun,
              sector <= sectorCount,
              count <= sectorCount - sector,
              count <= UInt64(Int.max) / sectorSize
        else { return nil }
        return Int(count * sectorSize)
    }

    private static func setLock(
        _ descriptor: Int32,
        type        : Int16
    ) -> Bool {
        var lock = Darwin.flock()
        lock.l_start = 0
        lock.l_len = 0
        lock.l_pid = 0
        lock.l_type = type
        lock.l_whence = Int16(SEEK_SET)
        return Darwin.fcntl(descriptor, F_SETLK, &lock) != -1
    }

}
