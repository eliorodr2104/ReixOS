//
//  FrameBudgetSiteTests.swift
//  ReixOS
//

import Testing
import Foundation

/// Every place the kernel takes a frame, and which side of the budget it is on.
///
/// A check on the source and not on behaviour, and that is the point: a budget
/// is only as good as the completeness of its charge points, and a new
/// `alloc` written next year would be a leak nothing else here notices. It is
/// the `pte-bbm` post-check's idea applied to the tree instead of to the linked
/// image: state what is there, and fail when something that is not appears.
///
/// The table is per file and not per line, so moving a call does not fail the
/// suite and adding one does.
@Suite("Frame budget charge sites")
struct FrameBudgetSiteTests {

    /// What a file's allocation sites answer to.
    private enum Accounting {

        /// Charged to the process that caused the allocation, and refunded on
        /// every failure and every release.
        case process

        /// The kernel's own: the boot page tables, the heap's backing pages,
        /// the ASID bitmap, and the allocator funnel itself. None of these
        /// belongs to any one process, and charging them to whoever happened to
        /// be running would make a process pay for the machine.
        case kernel
    }


    /// Source file relative to the package root, the number of `alloc(` call
    /// sites it holds, and what they answer to.
    ///
    /// Grown deliberately. A file that gains a site fails the count below, and a
    /// file that is not here at all fails outright: both are the same question,
    /// which is whether somebody decided where the frames come from.
    private static let sites: [String: (count: Int, accounting: Accounting)] = [
        // The allocator funnel every other site below reaches. Its own call is
        // into the buddy, and the reserve is enforced right above it.
        "Sources/ReixKernel/Memory/Physical/PhysicalPageManager.swift": (1, .kernel),

        // Kernel heap: one backing page per new slab, plus the slab core's own
        // hand-out, which takes no frame.
        "Sources/ReixKernel/Memory/Heap/BucketsHeap.swift": (2, .kernel),
        "Sources/ReixKernel/Memory/Heap/PPMBackend.swift" : (1, .kernel),

        // The first heap page, before there is a process to charge it to.
        "Sources/ReixKernel/Core/Kernel.swift": (1, .kernel),

        // Two boot roots and the ASID bitmap are the machine's; the root table
        // and every level `mapTable` creates are the address space's.
        "Sources/ReixKernel/Memory/Virtual/VirtualMemoryManager.swift": (5, .process),

        // Demand-zero pages and copy-on-write copies.
        "Sources/ReixKernel/Process/VMA/VMAManager+Faults.swift": (2, .process),

        // The first stack page, the task map, the ELF load frames.
        "Sources/ReixKernel/Process/ProcessManager.swift"      : (1, .process),
        "Sources/ReixKernel/Process/ProcessManager+Tasks.swift": (1, .process),
        "Sources/ReixKernel/Platform/ELFParser/ElfParser.swift": (1, .process),

        // Regions, charged to the process that created them for as long as it
        // holds them: `shmCreate` charges before `allocateFrames` takes the
        // blocks, and a DMA buffer is the one block `dmaAlloc` takes itself.
        // A region's extent spill is kernel heap, not a frame: see `spill`.
        "Sources/ReixKernel/InterProcessControl/Capabilities/SharedRegion.swift"       : (1, .process),
        "Sources/ReixKernel/Arch/aarch64/Exceptions/Providers/RXMemory/DmaAlloc.swift" : (1, .process),
    ]


    /// The package root: the nearest ancestor of this file holding `Package.swift`.
    private static var packageRoot: URL {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while !FileManager.default.fileExists(atPath: directory.appendingPathComponent("Package.swift").path),
              directory.path != "/" {
            directory.deleteLastPathComponent()
        }
        return directory
    }


    @Test("every allocation site in the kernel is one the budget knows about")
    func noSiteEscapesTheBudget() throws {
        let root   = Self.packageRoot
        let kernel = root.appendingPathComponent("Sources/ReixKernel")

        guard let walk = FileManager.default.enumerator(
            at                     : kernel,
            includingPropertiesForKeys: nil
        ) else {
            Issue.record("could not walk \(kernel.path)")
            return
        }

        var found: [String: Int] = [:]

        for case let url as URL in walk where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)

            var count = 0
            for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)

                // Documentation is not a call site, and neither is the name of
                // one inside a sentence about it.
                guard !trimmed.hasPrefix("//") else { continue }
                guard line.contains(".alloc(") else { continue }

                count += 1
            }

            guard count > 0 else { continue }

            let relative = url.path.replacingOccurrences(
                of  : root.path + "/",
                with: ""
            )
            found[relative] = count
        }

        for (file, count) in found.sorted(by: { $0.key < $1.key }) {
            guard let expected = Self.sites[file] else {
                Issue.record("""
                    \(file) takes frames and is on neither list. \
                    Charge them to the process that caused them, or say why \
                    they are the kernel's own, then add the file to \
                    FrameBudgetSiteTests.sites.
                    """)
                continue
            }

            #expect(
                count == expected.count,
                "\(file) has \(count) allocation sites, the budget knows \(expected.count)"
            )
        }

        for file in Self.sites.keys.sorted() where found[file] == nil {
            Issue.record("\(file) is listed as a charge point and has no allocation site left")
        }
    }
}
