//
//  SchedulerError.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 08/05/2026.
//

public enum SchedulerError: Error {
    case notNewerProcess
    case processNotExist
    
    public var localizedDescription: String {
        switch self {
            case .notNewerProcess:
                "The process not contains new status"
                
            case .processNotExist:
                "The pid is not found on process list"
        }
    }
}
