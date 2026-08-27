//
//  PathParts.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/08/2026.
//

/// A path taken apart, without anything being looked up.
///
/// Spans into the line the shell read, and nothing more: what was typed, split
/// at its separators, with no name opened and no capability touched. That
/// separation is the point. Resolving a path is the file system's business and
/// costs a round trip per name, while deciding whether a path is written at all
/// costs nothing and can be asked on a host with no disk.
///
/// The two depths are kept apart because the separators are. `::` crosses into
/// a container, which is a boundary a capability has to be opened to pass; `/`
/// walks a folder inside one, which is a lookup and nothing more. One list of
/// segments would lose which of the two each step is, at the moment the shell
/// can least afford to guess.
public struct PathParts {

    /// Whether the path named a root, and so starts from one rather than from
    /// where the caller stands.
    public var isRooted: Bool = false

    /// The first segment of a rooted path: the name of the caller's own root.
    public var root: Span = Span(start: 0, count: 0)

    /// Containers to descend into, in order, after the root.
    public var containers    : InlineArray<4, Span> = InlineArray(repeating: Span(start: 0, count: 0))
    public var containerCount: Int = 0

    /// Folders, and then possibly a file, inside the last container.
    public var folders    : InlineArray<8, Span> = InlineArray(repeating: Span(start: 0, count: 0))
    public var folderCount: Int = 0

    /// The last thing named, which is what a verb acts on. Empty when the path
    /// named only a place.
    public var leaf: Span {
        folderCount > 0 ? folders[folderCount - 1] : Span(start: 0, count: 0)
    }
}
