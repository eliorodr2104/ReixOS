//
//  LaunchLoader.swift
//  ReixOS
//

/// Keeps the file claim and copy cursor with the one launch allowed to load.
struct LaunchLoader<File: ProgramFile> {
    let slot   : Int
    var file   : File
    let plan   : ELFLoadPlan
    var copy   = ProgramCopy()
    var claimed = true
}
