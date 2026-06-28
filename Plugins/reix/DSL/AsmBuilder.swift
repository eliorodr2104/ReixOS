//
//  AsmBuilder.swift
//  ReixOS
//
//  Created by Eliomar on 28/06/2026.
//


@resultBuilder
enum AsmBuilder {
    static func buildExpression(_ line: String) -> String { line }
    static func buildBlock(_ parts: String...) -> [String] { parts }
}