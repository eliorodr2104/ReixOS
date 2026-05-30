//
//  TarInfo.swift
//  ReixOS
//
//  Created by Eliomar on 30/05/2026.
//

@frozen
public struct TarInfo {
    let address: PhysicalAddress
    
    
    var name: UnsafePointer<CChar>? {
        UnsafePointer(bitPattern: UInt(address))
    }
    
    var mode: UnsafePointer<CChar>? {
        UnsafePointer(bitPattern: UInt(address + 100))
    }
    
    var uid: UnsafePointer<CChar>? {
        UnsafePointer(bitPattern: UInt(address + 108))
    }
    
    var gid: UnsafePointer<CChar>? {
        UnsafePointer(bitPattern: UInt(address + 116))
    }
    
    var size: UnsafePointer<CChar>? {
        UnsafePointer(bitPattern: UInt(address + 124))
    }
    
    var mtime: UnsafePointer<CChar>? {
        UnsafePointer(bitPattern: UInt(address + 136))
    }
    
    var chksum: UnsafePointer<CChar>? {
        UnsafePointer(bitPattern: UInt(address + 148))
    }
    
    var typeflag: UnsafePointer<CChar>? {
        UnsafePointer(bitPattern: UInt(address + 156))
    }
    
    var linkname: UnsafePointer<CChar>? {
        UnsafePointer(bitPattern: UInt(address + 157))
    }
    
    var magic: UnsafePointer<CChar>? {
        UnsafePointer(bitPattern: UInt(address + 257))
    }
    
    var version: UnsafePointer<CChar>? {
        UnsafePointer(bitPattern: UInt(address + 263))
    }
    
    var uname: UnsafePointer<CChar>? {
        UnsafePointer(bitPattern: UInt(address + 265))
    }
    
    var gname: UnsafePointer<CChar>? {
        UnsafePointer(bitPattern: UInt(address + 297))
    }
    
    var devmajor: UnsafePointer<CChar>? {
        UnsafePointer(bitPattern: UInt(address + 329))
    }
    
    var devminor: UnsafePointer<CChar>? {
        UnsafePointer(bitPattern: UInt(address + 337))
    }
    
    var prefix: UnsafePointer<CChar>? {
        UnsafePointer(bitPattern: UInt(address + 345))
    }
    
    var pad: UnsafePointer<CChar>? {
        UnsafePointer(bitPattern: UInt(address + 500))
    }
}
