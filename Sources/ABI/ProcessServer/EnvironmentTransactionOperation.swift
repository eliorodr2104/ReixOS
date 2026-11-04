//
//  EnvironmentTransactionOperation.swift
//  ReixOS
//

public enum EnvironmentTransactionOperation: UInt32, IPCLabel {
    case begin = 0x730
    case binding
    case acknowledgement
    case commit
    case ready
    case refused
}
