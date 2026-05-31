//
//  GlobalTypes.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 25/04/2026.
//

public typealias KernelPPM                = PhysicalPageManager<BuddyAllocator>
public typealias KernelHeap               = BucketsHeap
public typealias KernelScheduler          = RoundRobin
public typealias KernelIPC                = RendezvousIPC
public typealias KernelInternalFileSystem = TarFileSystem

public typealias Arch                     = AArch64
