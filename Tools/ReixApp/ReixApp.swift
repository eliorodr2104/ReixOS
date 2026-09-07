//
//  ReixApp.swift
//  ReixOS
//

import CryptoKit
import Darwin
import Foundation
import ProcessServerCore
import ReixABI
import ReixFS

private struct Options {
    var disk          = ".reix/disk.img"
    var formatIfBlank = false
    var sources       : [String] = []

    static func parse(_ arguments: ArraySlice<String>) throws -> Options {
        guard arguments.first == "install" else {
            throw ReixAppError.usage(
                "usage: reix app install [--disk PATH] [--format-if-blank] APP.elf ..."
            )
        }

        var options = Options()
        var index   = arguments.index(after: arguments.startIndex)
        while index < arguments.endIndex {
            let argument = arguments[index]
            if argument == "--disk" {
                index = arguments.index(after: index)
                guard index < arguments.endIndex else {
                    throw ReixAppError.usage("--disk needs a path")
                }
                options.disk = arguments[index]
            } else if argument == "--format-if-blank" {
                options.formatIfBlank = true
            } else if argument.hasPrefix("-") {
                throw ReixAppError.usage("unknown option: \(argument)")
            } else {
                options.sources.append(argument)
            }
            index = arguments.index(after: index)
        }

        guard !options.sources.isEmpty else {
            throw ReixAppError.usage("install needs at least one ELF")
        }
        return options
    }
}

@main
enum ReixApp {
    private static let maximumAppBytes = 8 * 1024 * 1024

    static func main() {
        do {
            let options = try Options.parse(CommandLine.arguments.dropFirst())
            try install(options)
        } catch {
            FileHandle.standardError.write(Data("reix app: \(error)\n".utf8))
            Darwin.exit(2)
        }
    }

    private static func install(_ options: Options) throws {
        let device  = try FileBlockDevice(path: options.disk)
        let scratch = UnsafeMutableRawPointer.allocate(
            byteCount: FileSystem<FileBlockDevice>.scratchBytes,
            alignment: 4096
        )
        defer { scratch.deallocate() }

        var fileSystem : FileSystem<FileBlockDevice>
        let mounted    = FileSystem<FileBlockDevice>.mount(device, scratch: scratch)
        switch mounted.found {
            case .ok:
                guard let disk = mounted.disk else {
                    throw ReixAppError.refused("RxFS mount returned no volume")
                }
                fileSystem = disk

            case .blank where options.formatIfBlank:
                let formatted = FileSystem<FileBlockDevice>.format(device, scratch: scratch)
                guard formatted.made == .ok, let disk = formatted.disk else {
                    throw ReixAppError.refused("RxFS refused to format the blank image: \(formatted.made)")
                }
                fileSystem = disk

            case .blank:
                throw ReixAppError.refused(
                    "disk is blank; repeat with --format-if-blank to authorize formatting"
                )

            case .unsupportedVersion(let version):
                throw ReixAppError.refused("unsupported RxFS version \(version)")
            case .tooLarge(let blocks):
                throw ReixAppError.refused("RxFS image is too large (\(blocks) blocks)")
            case .corrupt:
                throw ReixAppError.refused("disk is corrupt or belongs to another filesystem")
            case .deviceFailed:
                throw ReixAppError.refused("disk image stopped answering")
            case .unusable:
                throw ReixAppError.refused("disk geometry cannot hold RxFS")
            case .durabilityUnknown:
                throw ReixAppError.refused("disk image has no durability contract")
        }

        var clean = false
        defer {
            if !clean { _ = fileSystem.unmount() }
        }

        let system   = try folder(named: "system", in: FSLayout.rootObject, fileSystem: &fileSystem)
        let programs = try folder(named: "programs", in: system, fileSystem: &fileSystem)

        for path in options.sources {
            try install(path: path, in: programs, fileSystem: &fileSystem)
        }

        guard fileSystem.unmount() == .ok else {
            throw ReixAppError.refused("installed programs but RxFS would not unmount cleanly")
        }
        clean = true
    }

    private static func folder(
        named name: String,
        in parent : UInt32,
        fileSystem: inout FileSystem<FileBlockDevice>
    ) throws -> UInt32 {
        let data = Data(name.utf8)
        return try data.withUnsafeBytes { raw in
            switch fileSystem.lookup(raw.baseAddress!, length: raw.count, in: parent) {
                case .at(let object):
                    guard fileSystem.object(object)?.kind == .folder else {
                        throw ReixAppError.refused("\(name) exists but is not a folder")
                    }
                    return object

                case .refused(.notFound):
                    let made = fileSystem.create(
                        raw.baseAddress!,
                        length: raw.count,
                        kind: .folder,
                        in: parent
                    )
                    guard made.status == .ok else {
                        throw ReixAppError.refused("could not create \(name): \(made.status)")
                    }
                    return made.object

                case .refused(let status):
                    throw ReixAppError.refused("could not inspect \(name): \(status)")
            }
        }
    }

    private static func install(
        path       : String,
        in programs: UInt32,
        fileSystem : inout FileSystem<FileBlockDevice>
    ) throws {
        let url  = URL(fileURLWithPath: path)
        let name = url.lastPathComponent
        guard name.hasSuffix(".elf"),
              !name.isEmpty,
              name.utf8.count <= FSLayout.nameLimit
        else {
            throw ReixAppError.refused("invalid program basename: \(name)")
        }

        let bytes = try Data(contentsOf: url, options: [.mappedIfSafe])
        guard !bytes.isEmpty, bytes.count <= maximumAppBytes else {
            throw ReixAppError.refused("\(name) exceeds the 8 MiB importer bound")
        }

        var source = DataELFSource(bytes: bytes)
        if case .failure(let error) = ELFPlanner.plan(from: &source) {
            throw ReixAppError.refused("\(name) is not an admissible Reix ELF: \(error)")
        }

        let nameBytes = Data(name.utf8)
        try nameBytes.withUnsafeBytes { rawName in
            let object: UInt32
            switch fileSystem.lookup(rawName.baseAddress!, length: rawName.count, in: programs) {
                case .at(let existing):
                    guard fileSystem.object(existing)?.kind == .file else {
                        throw ReixAppError.refused("\(name) exists but is not a file")
                    }
                    object = existing

                case .refused(.notFound):
                    let made = fileSystem.create(
                        rawName.baseAddress!,
                        length: rawName.count,
                        kind: .file,
                        in: programs
                    )
                    guard made.status == .ok else {
                        throw ReixAppError.refused("could not create \(name): \(made.status)")
                    }
                    object = made.object

                case .refused(let status):
                    throw ReixAppError.refused("could not inspect \(name): \(status)")
            }

            let written = bytes.withUnsafeBytes { raw in
                fileSystem.write(
                    object,
                    at: 0,
                    from: raw.baseAddress!,
                    count: UInt64(raw.count),
                    replacing: true
                )
            }
            guard written.status == .ok,
                  written.bytes == UInt64(bytes.count),
                  fileSystem.object(object)?.size == UInt64(bytes.count)
            else {
                throw ReixAppError.refused("could not install all bytes of \(name): \(written.status)")
            }
        }

        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        print("installed system/programs/\(name)  \(bytes.count) bytes  sha256 \(digest)")
    }
}
