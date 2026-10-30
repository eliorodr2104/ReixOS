//
//  DmaReclaim.swift
//  ReixOS
//

import ReixABI

/// `dmaReclaim(deviceHandle) -> pages` syscall provider.
///
/// The caller declares that the device behind `deviceHandle` has been reset and
/// no longer holds any address it was given. The kernel then gives back to the
/// PPM every buffer on `DmaQuarantine` bound to that device, which is every
/// published buffer minted through that window that nothing holds any more,
/// and refunds each one's creator if it is still paying.
///
/// **The kernel cannot verify the reset, and does not try.** It trusts the
/// caller, for the reason `DmaAlloc` gives: a process holding a device window
/// with `.dma` is already inside the trusted base, and could aim the device at
/// any frame of the machine without this call. A false declaration frees
/// memory the device may still write, which is the same harm that holder could
/// do directly, and no more.
///
/// The gate is the one `dmaAlloc` uses (`DmaAlloc.transferWindow`): a device
/// capability carrying `.dma`. A buffer still held by a capability, a window or
/// a message in flight is never on the list, published or not, so the caller's
/// own live buffer survives this call; one bound to another window is not
/// touched either.
///
/// `x0` the device window's handle in, and out the frames given back, zero
/// included. `UInt64.max` on refusal, which no count of frames can be.
public struct DmaReclaim: SyscallProvider {

    public static let number: SyscallNumber = .dmaReclaim

    public static func handle(
        frame  : UnsafeMutablePointer<Arch.TrapFrame>,
        context: SyscallContext
    ) {
        guard let current = Arch.CPU.getCurrentProcess(),
              let window  = DmaAlloc.transferWindow(handle: frame.pointee.x0, in: current)
        else {
            frame.pointee.x0 = UInt64.max
            return
        }

        frame.pointee.x0 = UInt64(DmaQuarantine.release(
            device: window.address,
            ppm   : context.ppm,
            heap  : context.processManager.pointee.heap
        ))
    }
}
