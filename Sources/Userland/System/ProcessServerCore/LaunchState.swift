//
//  LaunchState.swift
//  ReixOS
//

/// Keeps a waiting launch resumable so another can advance while it waits.
public enum LaunchState: Equatable {
    case queued                       // accepted, waiting for the loader
    case loading                      // holds the loader and the claim; one chunk per step
    case sealing                      // copy done, claim let go; seal, context, start
    case offering(LaunchOffer)        // the next bootstrap message to deliver
    case acknowledging(LaunchOffer)   // delivered, waiting for its acknowledgement
    case awaitingReady                // commit delivered, waiting for ready
}
