//
//  IPCLabel.swift
//  ReixOS
//
//  A type whose rawValue can travel in a message tag label.
//

public protocol IPCLabel: RawRepresentable where RawValue == UInt32 {  }
