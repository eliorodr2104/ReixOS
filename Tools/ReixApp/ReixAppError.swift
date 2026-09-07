//
//  ReixAppError.swift
//  ReixOS
//

enum ReixAppError: Error, CustomStringConvertible {
    case usage(String)
    case refused(String)

    var description: String {
        switch self {
            case .usage(let text), .refused(let text): return text
        }
    }
}
