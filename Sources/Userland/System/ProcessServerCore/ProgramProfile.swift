//
//  ProgramProfile.swift
//  ReixOS
//

import ReixABI

/// Bounded launch policy selected by an exact disk basename.
///
/// These are the server-side ceilings and required bindings for the two
/// ordinary programs of the first migration. A future manifest may request
/// less; the server still decides what a program receives.
public enum ProgramProfile: UInt8 {
    case shell
    case top

    public static func identify(
        _ bytes: InlineArray<12, UInt8>,
        length : Int
    ) -> ProgramProfile? {
        if equals(bytes, length: length, "Shell.elf") { return .shell }
        if equals(bytes, length: length, "Top.elf") { return .top }
        return nil
    }

    public var bindings: (
        storage: InlineArray<16, ProgramBindingSpec?>,
        count: Int
    ) {
        var storage = InlineArray<16, ProgramBindingSpec?>(repeating: nil)
        var count   = 0

        func require(
            _ binding: EnvironmentBinding,
            _ rights : CapRights
        ) {
            storage[count] = ProgramBindingSpec(binding: binding, rights: rights)
            count += 1
        }

        require(.console, [.send])
        require(.profiler, [.profileStats])

        if self == .shell {
            require(.nameServer, [.send])
            require(.terminal, [.send])
            require(.inputConsumer, [.send])
            require(.container, [.send, .grant])
            require(.block, [.send])
            require(.programs, [.send])
            require(.processServer, [.send])
            require(.sessionControl, [.send])
            #if REIX_TERMINAL_PROFILE
            require(.profileMarker, [.profileMark, .profileConsole])
            #endif
        }

        return (storage, count)
    }

    private static func equals(
        _ bytes: InlineArray<12, UInt8>,
        length : Int,
        _ text : StaticString
    ) -> Bool {
        guard length == text.utf8CodeUnitCount else { return false }
        for index in 0..<length where bytes[index] != text.utf8Start[index] {
            return false
        }
        return true
    }
}

public struct ProgramBindingSpec {
    public let binding: EnvironmentBinding
    public let rights : CapRights

    public init(
        binding: EnvironmentBinding,
        rights : CapRights
    ) {
        self.binding = binding
        self.rights = rights
    }
}
