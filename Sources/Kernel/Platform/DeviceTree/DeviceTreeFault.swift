//
//  DeviceTreeFault.swift
//  ReixOS
//
//  Created by Claude on 09/08/2026.
//

/// Which device-tree check refused the blob, and how far into it.
///
/// The walk used to answer with `-1`/`-2`/`-3`/`-4` and `discover` collapsed all
/// four to `false`, so the one thing a failed boot had to say, which check
/// rejected the blob, was thrown away at the only place left that could still
/// print it. Every guard now names itself and carries an offset, which is where
/// this got its second job: a bad blob is usually bad in one spot, and the
/// difference between "malformed" and "malformed at 0x2f4" is the difference
/// between guessing and opening the dump there.
public struct DeviceTreeFault {

    /// One case per guard, in the order they are applied.
    ///
    /// Deliberately finer-grained than the four codes it replaces: the cost of
    /// a case is one literal in read-only storage, and the whole point of the
    /// type is that a rejection arrives named.
    public enum Reason {
        case missingBlob
        case misalignedBlob
        case badMagic
        case shortHeader
        case structBlockBounds
        case stringBlockBounds
        case overlappingBlocks
        case nodeName
        case depthLimit
        case rootNode
        case orphanNode
        case strayEndNode
        case strayProperty
        case propertyHeader
        case propertyValueBounds
        case propertyName
        case compatibleList
        case unknownTag
        case misplacedEnd
        case unterminatedStruct

        /// The one check that runs after the walk rather than inside it, and
        /// the only one about what the blob failed to say rather than about
        /// how it is built. See `getPlatformInfo`.
        case missingConsole

        /// Every branch is a plain literal, as in `ElfError`: the sentence is
        /// the report, and nothing here composes one at runtime.
        public var description: StaticString {
            switch self {
                case .missingBlob:
                    "no device tree was handed to the kernel (null pointer)."

                case .misalignedBlob:
                    "the blob is not 4-byte aligned."

                case .badMagic:
                    "the blob does not open with the FDT magic."

                case .shortHeader:
                    "the blob is shorter than an FDT header."

                case .structBlockBounds:
                    "the struct block falls outside the blob."

                case .stringBlockBounds:
                    "the strings block falls outside the blob."

                case .overlappingBlocks:
                    "the struct and strings blocks overlap."

                case .nodeName:
                    "a node name runs past the end of the struct block."

                case .depthLimit:
                    "the tree nests deeper than the walk can follow."

                case .rootNode:
                    "the root node carries a name."

                case .orphanNode:
                    "a node begins after the root node has ended."

                case .strayEndNode:
                    "a node ends where none was open."

                case .strayProperty:
                    "a property sits outside a node, or after its children."

                case .propertyHeader:
                    "a property header runs past the end of the struct block."

                case .propertyValueBounds:
                    "a property value runs past the end of the struct block."

                case .propertyName:
                    "a property name is not a terminated string in the strings block."

                case .compatibleList:
                    "a compatible string is not terminated inside its value."

                case .unknownTag:
                    "the struct block holds a tag that is not an FDT tag."

                case .misplacedEnd:
                    "FDT_END arrives with the tree still open, or with bytes after it."

                case .unterminatedStruct:
                    "the struct block ends without an FDT_END tag."

                case .missingConsole:
                    "the blob parses but leaves the console without a base address."
            }
        }
    }

    public let reason: Reason

    /// Byte offset into the blob the check stopped at, or `nil` when the reason
    /// is about the blob as a whole and there is nothing to point at.
    ///
    /// Optional rather than zero so the two cannot be confused: a fault at the
    /// very first tag and a fault that has no position both used to print
    /// `offset 0x0`. For a tag-level rejection this is the tag's own offset, and
    /// for the rest it is the field that was refused, the node name or the
    /// property value the walk stopped on.
    public let offset: UInt32?

    @inline(__always)
    init(_ reason: Reason) {
        self.reason = reason
        self.offset = nil
    }

    @inline(__always)
    init(_ reason: Reason, at offset: Int) {
        self.reason = reason
        self.offset = UInt32(truncatingIfNeeded: offset)
    }
}
