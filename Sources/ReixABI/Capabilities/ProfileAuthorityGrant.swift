/// The share of the boot profiler authority a spawned tool is seeded with.
public enum ProfileAuthorityGrant {

    /// A reader's share: enough for `procStats` and for `attachExport`, and
    /// deliberately not the console dump nor the PMU counters.
    ///
    /// The spawn path intersects this with the parent's own rights, so a parent
    /// holding only `.profileStats` cannot widen a child past itself.
    public static func tool(source: UInt32) -> CapGrant {
        CapGrant(
            source: source,
            slot  : BootCap.profiler.rawValue,
            rights: [.profileStats]
        )
    }


    /// The same reader's share, plus the authority to hand it on once.
    ///
    /// For a process whose job is launching tools: a shell that could read the
    /// process table but could not let `Top.elf` read it would be a shell that
    /// cannot run the tools it lists. `injectCapability` refuses to pass on a
    /// capability that does not carry `grant`, which is the rule that made this
    /// distinction necessary rather than decorative.
    ///
    /// What it hands on should be `tool`, which drops `grant` again: the child
    /// reads, and the chain stops there.
    public static func launcher(source: UInt32) -> CapGrant {
        CapGrant(
            source: source,
            slot  : BootCap.profiler.rawValue,
            rights: [.profileStats, .grant]
        )
    }
}
