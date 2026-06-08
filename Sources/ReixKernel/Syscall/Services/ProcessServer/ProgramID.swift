//
//  ProgramID.swift
//  ReixOS
//
//  Launchable programs known to the Process Server. It maps each to the path
//  the kernel loader resolves in the initrd.
//

public enum ProgramID: UInt32 {
    case child  = 0
    case child2 = 1

    public var tarPath: StaticString {
        switch self {
            case .child : "Child.elf"
            case .child2: "Child2.elf"
        }
    }
}
