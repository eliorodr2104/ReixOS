//
//  KernelPolicyTestRoot.swift
//  ReixOS
//
//  These host fixtures temporarily install process-wide kernel state. Keep the
//  target's suites under one serialized parent; unrelated test targets still
//  run concurrently under `swift test --parallel`.

import Testing

@Suite("Kernel policy host fixtures", .serialized)
struct KernelPolicyTestRoot {}
