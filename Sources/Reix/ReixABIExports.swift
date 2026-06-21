//
//  ReixABIExports.swift
//  ReixOS
//
//  Re-exports the shared ABI so userland apps that `import Reix` also see
//  Message, CapRights, SyscallNumber, etc. — same ergonomics as the old
//  single-module build.
//

@_exported import ReixABI
