//
//  Runtime.swift
//  ReixOS
//
//  Created by Eliomar on 29/06/2026.
//

import ReixABI

public enum Runtime {

    @discardableResult
    public static func bootstrap() -> Environment {
        let environment = Environment.boot()

        if let console = environment.console {
            Console.attach(console: console)
        }

        return environment
    }
}
