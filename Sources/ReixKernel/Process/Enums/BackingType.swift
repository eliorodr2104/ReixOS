//
//  BackingType.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 10/05/2026.
//

/// What stands behind the pages of a region, and with it who owns the frames
/// under them.
///
/// The distinction the VMA layer actually acts on is `.anonymous` against
/// everything else: only anonymous frames were issued to this address space and
/// are therefore this address space's to hand back. Every other case is
/// unmap-only on retirement, and `mergeAdjacent` and `decommit` refuse it.
public enum BackingType {

    /// Frames this address space owns: allocated on first touch, zero filled, and
    /// released when the last mapping of them goes.
    case anonymous

    /// Read-only pages mapped straight from the permanently resident initrd
    /// frames, shared by every process that maps the same file.
    ///
    /// The adopted semantics, which the rest of the VMA layer already enforces:
    ///
    /// - The mapping is read-only, so the archive cannot be written through it and
    ///   a fault on a write is a fault and not a copy.
    /// - The frames come from the initrd `ReservedRange` the physical page manager
    ///   withholds at boot, so they are permanently resident and are mapped
    ///   directly rather than copied into fresh anonymous pages.
    /// - Two processes mapping the same file map the same frames. Sharing is the
    ///   normal case here, not an optimization applied to some of them.
    /// - Nobody owns those frames in the VMA layer. The reserved range keeps them
    ///   alive whatever any process does, no reference was taken on them here, and
    ///   the buddy allocator never issued them to anyone.
    ///
    /// That last point is what the retirement rules follow from.
    /// `PageRetirement.retire` clears the translations and releases nothing;
    /// `VMAManager.decommit` refuses the range instead of freeing frames it does
    /// not own; `VMAList.mergeAdjacent` refuses two such regions even when their
    /// permissions and flags match, since regions that look alike may sit on
    /// unrelated file offsets and a merged region could no longer say which.
    ///
    /// Revisit when the FS server lands. This design makes the
    /// permanently-resident initrd productive; it does not reclaim it. True
    /// reclaim requires the initrd to stop being the live backing store for
    /// spawnProcess. At that point these shared mappings become the natural client
    /// of a page cache instead of raw initrd frames, and PhysicalPageManager's
    /// initrd ReservedRange can be reclaimed the way reclaimDeviceTree reclaims
    /// the DTB.
    case fileBacked

    /// A window onto a `SharedRegion`, whose frames are owned by that region and
    /// released when its last reference goes. `registerRegion` requires the two to
    /// arrive together, so a `.shared` region without a region pointer is refused.
    case shared

    /// Device memory mapped for a driver. The frames are not RAM at all, so
    /// nothing here may ever hand them to the allocator.
    case device
}
