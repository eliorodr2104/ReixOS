//
//  ELFLoadPlan.swift
//  ReixOS
//

import ReixABI

public struct ELFLoadPlan {
    public let entry       : UInt64
    public let programBreak: UInt64
    public let imagePages  : UInt32
    public let regionCount : Int
    public let copyCount   : Int

    private var regions: InlineArray<31, ELFLoadRegion?>
    private var copies : InlineArray<16, ELFCopy?>

    init(
        entry       : UInt64,
        programBreak: UInt64,
        imagePages  : UInt32,
        regions     : InlineArray<31, ELFLoadRegion?>,
        regionCount : Int,
        copies      : InlineArray<16, ELFCopy?>,
        copyCount   : Int
    ) {
        self.entry = entry
        self.programBreak = programBreak
        self.imagePages = imagePages
        self.regions = regions
        self.regionCount = regionCount
        self.copies = copies
        self.copyCount = copyCount
    }

    public func region(at index: Int) -> ELFLoadRegion? {
        guard index >= 0, index < regionCount else { return nil }
        return regions[index]
    }

    public func copy(at index: Int) -> ELFCopy? {
        guard index >= 0, index < copyCount else { return nil }
        return copies[index]
    }
}
