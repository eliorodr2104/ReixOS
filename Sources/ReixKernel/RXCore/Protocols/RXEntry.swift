//
//  RXObject.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 10/05/2026.
//

public protocol RXEntry: ~Copyable {
    associatedtype IDType: Equatable
    
    var entryID: IDType { get }
    var prev   : UnsafeMutablePointer<Self>? { get set }
    var next   : UnsafeMutablePointer<Self>? { get set }
}
