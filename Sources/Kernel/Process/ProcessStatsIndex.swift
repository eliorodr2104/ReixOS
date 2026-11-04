//
//  ProcessMetadata.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 22/08/2026.
//

enum ProcessStatsIndex {
    private static var root: UnsafeMutablePointer<Process>? = nil

    #if !hasFeature(Embedded)
        private(set) static var lookupSteps: UInt64 = 0

        static func resetLookupSteps() {
            lookupSteps = 0
        }

        static func reset() {
            root = nil
            lookupSteps = 0
        }
    #endif

    @discardableResult
    static func insert(_ process: UnsafeMutablePointer<Process>) -> Bool {
        var current = root

        while let candidate = current {
            if candidate == process || candidate.pointee.pid == process.pointee.pid {
                return false
            }

            current = process.pointee.pid < candidate.pointee.pid
                ? candidate.pointee.procStatsLeft
                : candidate.pointee.procStatsRight
        }

        process.pointee.procStatsParent = nil
        process.pointee.procStatsLeft   = nil
        process.pointee.procStatsRight  = nil
        process.pointee.procStatsHeight = 1

        guard let first = root else {
            root = process
            return true
        }

        current = first

        while let candidate = current {
            if process.pointee.pid < candidate.pointee.pid {
                
                if let left = candidate.pointee.procStatsLeft {
                    current = left
                    
                } else {
                    candidate.pointee.procStatsLeft = process
                    process.pointee.procStatsParent = candidate
                    rebalance(from: candidate)
                    
                    return true
                }
                
            } else {
                if let right = candidate.pointee.procStatsRight {
                    current = right
                    
                } else {
                    candidate.pointee.procStatsRight = process
                    process.pointee.procStatsParent = candidate
                    rebalance(from: candidate)
                    
                    return true
                }
            }
        }

        return false
    }

    @discardableResult
    static func remove(_ process: UnsafeMutablePointer<Process>) -> Bool {
        guard contains(process) else { return false }

        while process.pointee.procStatsLeft != nil,
              process.pointee.procStatsRight != nil {
            if height(process.pointee.procStatsLeft) > height(process.pointee.procStatsRight) {
                _ = rotateRight(process)
                
            } else { _ = rotateLeft(process) }
        }

        let parent = process.pointee.procStatsParent
        let child = process.pointee.procStatsLeft ?? process.pointee.procStatsRight

        replace(process, with: child)

        process.pointee.procStatsParent = nil
        process.pointee.procStatsLeft   = nil
        process.pointee.procStatsRight  = nil
        process.pointee.procStatsHeight = 1

        if let parent {
            rebalance(from: parent)
            
        } else if let child { updateHeight(child) }

        return true
    }

    static func successor(after cursor: PID) -> UnsafeMutablePointer<Process>? {
        var current = root
        var candidate: UnsafeMutablePointer<Process>? = nil

        while let process = current {
            #if !hasFeature(Embedded)
                lookupSteps &+= 1
            #endif

            if process.pointee.pid > cursor {
                candidate = process
                current = process.pointee.procStatsLeft
            
            } else { current = process.pointee.procStatsRight }
        }

        return candidate
    }

    private static func contains(_ process: UnsafeMutablePointer<Process>) -> Bool {
        var current = root

        while let candidate = current {
            if candidate == process { return true }

            if process.pointee.pid < candidate.pointee.pid {
                current = candidate.pointee.procStatsLeft
            
            } else { current = candidate.pointee.procStatsRight }
        }

        return false
    }

    private static func height(_ process: UnsafeMutablePointer<Process>?) -> UInt8 {
        process?.pointee.procStatsHeight ?? 0
    }

    private static func updateHeight(_ process: UnsafeMutablePointer<Process>) {
        let left = height(process.pointee.procStatsLeft)
        let right = height(process.pointee.procStatsRight)
        process.pointee.procStatsHeight = (left > right ? left : right) &+ 1
    }

    private static func balance(_ process: UnsafeMutablePointer<Process>) -> Int {
        Int(height(process.pointee.procStatsLeft)) - Int(height(process.pointee.procStatsRight))
    }

    private static func rebalance(from start: UnsafeMutablePointer<Process>) {
        var current: UnsafeMutablePointer<Process>? = start

        while let process = current {
            updateHeight(process)

            if balance(process) > 1 {
                if let left = process.pointee.procStatsLeft, balance(left) < 0 {
                    _ = rotateLeft(left)
                }

                let top = rotateRight(process)
                current = top.pointee.procStatsParent
                
            } else if balance(process) < -1 {
                if let right = process.pointee.procStatsRight, balance(right) > 0 {
                    _ = rotateRight(right)
                }

                let top = rotateLeft(process)
                current = top.pointee.procStatsParent
                
            } else { current = process.pointee.procStatsParent }
        }
    }

    @discardableResult
    private static func rotateLeft(
        _ process: UnsafeMutablePointer<Process>
    ) -> UnsafeMutablePointer<Process> {
        let top    = process.pointee.procStatsRight!
        let middle = top.pointee.procStatsLeft

        replace(process, with: top)
        top.pointee.procStatsLeft       = process
        process.pointee.procStatsParent = top
        process.pointee.procStatsRight  = middle
        middle?.pointee.procStatsParent = process

        updateHeight(process)
        updateHeight(top)
        return top
    }

    private static func rotateRight(
        _ process: UnsafeMutablePointer<Process>
    ) -> UnsafeMutablePointer<Process> {
        let top    = process.pointee.procStatsLeft!
        let middle = top.pointee.procStatsRight

        replace(process, with: top)
        top.pointee.procStatsRight      = process
        process.pointee.procStatsParent = top
        process.pointee.procStatsLeft   = middle
        middle?.pointee.procStatsParent = process

        updateHeight(process)
        updateHeight(top)
        return top
    }

    private static func replace(
        _    process    : UnsafeMutablePointer<Process>,
        with replacement: UnsafeMutablePointer<Process>?
    ) {
        if let parent = process.pointee.procStatsParent {
            if parent.pointee.procStatsLeft == process {
                parent.pointee.procStatsLeft = replacement
            
            } else { parent.pointee.procStatsRight = replacement }
            
        } else { root = replacement }

        replacement?.pointee.procStatsParent = process.pointee.procStatsParent
    }

    #if !hasFeature(Embedded)
        static var rootPIDForTesting: PID? {
            root?.pointee.pid
        }

        static var isValidForTesting: Bool {
            guard root?.pointee.procStatsParent == nil else { return false }
            
            var visited = Set<UInt>()
            return validateForTesting(
                root,
                parent : nil,
                lower  : nil,
                upper  : nil,
                visited: &visited
            ).valid
        }

        private static func validateForTesting(
            _ process: UnsafeMutablePointer<Process>?,
              parent : UnsafeMutablePointer<Process>?,
              lower  : PID?,
              upper  : PID?,
              visited: inout Set<UInt>
        ) -> (valid: Bool, height: UInt8) {
            
            guard let process else { return (true, 0) }

            let address = UInt(bitPattern: process)
            guard visited.insert(address).inserted,
                  process.pointee.procStatsParent == parent,
                  lower.map({ process.pointee.pid > $0 }) ?? true,
                  upper.map({ process.pointee.pid < $0 }) ?? true
            else { return (false, 0) }

            let left = validateForTesting(
                process.pointee.procStatsLeft,
                parent : process,
                lower  : lower,
                upper  : process.pointee.pid,
                visited: &visited
            )
            
            let right = validateForTesting(
                process.pointee.procStatsRight,
                parent : process,
                lower  : process.pointee.pid,
                upper  : upper,
                visited: &visited
            )
            let computedHeight = (left.height > right.height ? left.height : right.height) &+ 1
            let difference = Int(left.height) - Int(right.height)

            return (
                left.valid && right.valid &&
                difference >= -1 && difference <= 1 &&
                process.pointee.procStatsHeight == computedHeight,
                computedHeight
            )
        }
    #endif
}
