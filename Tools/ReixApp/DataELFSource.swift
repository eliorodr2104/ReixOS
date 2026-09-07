//
//  DataELFSource.swift
//  ReixOS
//

import Foundation
import ProcessServerCore

struct DataELFSource: ELFByteSource {
    let bytes: Data
    var size : UInt64 { UInt64(bytes.count) }

    mutating func read(
        at offset       : UInt64,
        into destination: UnsafeMutableRawPointer,
        count           : Int
    ) -> Bool {
        guard count > 0,
              offset <= UInt64(bytes.count),
              UInt64(count) <= UInt64(bytes.count) - offset
        else { return false }

        bytes.withUnsafeBytes { source in
            destination.copyMemory(
                from: source.baseAddress!.advanced(by: Int(offset)),
                byteCount: count
            )
        }
        return true
    }
}
