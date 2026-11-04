//
//  Civil.swift
//  ReixOS
//
//  Created by Eliomar on 23/08/2026.
//


/// The pieces of a date, as anybody would write them.
public struct Civil: Equatable, Sendable {

    public var year  : Int
    public var month : Int // 1...12
    public var day   : Int // 1...31
    public var hour  : Int
    public var minute: Int
    public var second: Int

    public init(
        year  : Int,
        month : Int,
        day   : Int,
        hour  : Int = 0,
        minute: Int = 0,
        second: Int = 0
    ) {
        self.year   = year
        self.month  = month
        self.day    = day
        self.hour   = hour
        self.minute = minute
        self.second = second
    }
}
