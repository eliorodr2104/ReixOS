//
//  ReixTextSurfaceProtocol.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 27/08/2026.
//

/// The semantic screen command contract. VT bytes are an implementation detail
/// of VTAdapter and never occur in this protocol.
public enum ReixTextSurfaceProtocol {
    public static let version: UInt16 = 2
    public static let recordBytes = 288
    public static let headerBytes = 32

    /// TextSurface carries printable Unicode text plus LF, never VT bytes.
    /// C0 controls, DEL and C1 controls are rejected before the adapter.
    public static func validText(
        _ bytes: UnsafePointer<UInt8>,
        count  : Int
    ) -> Bool {
        ReixInputRecord.validText(bytes, count: count, allowsLF: true)
    }
}
