//
//  ASIDAllocator.swift
//  ReixOS
//

/// Live address spaces own their tags until their translations are invalidated
/// and their roots destroyed. Flushing at counter wrap cannot make two live
/// roots with the same tag safe.
struct ASIDAllocator {
    private var used = InlineArray<4, UInt64>(repeating: 0)
    private var extended: UnsafeMutablePointer<UInt64>?
    private let wide: Bool
    private var nextWord = 0

    private var wordCount: Int { extended == nil ? 4 : 1024 }

    init(bits: UInt64) {
        wide = bits == 16
        used[0] = 1 // The kernel identity root owns ASID zero.
    }

    /// The 8 KiB wide bitmap is needed only above 255 live processes. Keeping
    /// the common bitmap inline avoids large aggregate copies on the boot stack.
    mutating func allocate(
        expand: () -> UnsafeMutablePointer<UInt64>? = { nil }
    ) -> ASID? {
        for distance in 0..<wordCount {
            let word = (nextWord + distance) % wordCount
            let value = extended.map { $0[word] } ?? used[word]
            let available = ~value
            guard available != 0 else { continue }
            let bit = available.trailingZeroBitCount
            set(word, to: value | (UInt64(1) << bit))
            nextWord = word
            return ASID(word * 64 + bit)
        }
        if wide, extended == nil, let storage = expand() {
            storage.initialize(repeating: 0, count: 1024)
            for index in 0..<used.count { storage[index] = used[index] }
            extended = storage
            return allocate()
        }
        return nil
    }

    /// The caller must complete TLB invalidation before releasing the tag.
    mutating func release(_ asid: ASID) {
        let word = Int(asid) / 64
        guard asid != 0, word < wordCount else { return }
        let value = extended.map { $0[word] } ?? used[word]
        set(word, to: value & ~(UInt64(1) << (Int(asid) % 64)))
        nextWord = word
    }

    private mutating func set(_ word: Int, to value: UInt64) {
        if let extended { extended[word] = value }
        else { used[word] = value }
    }
}
