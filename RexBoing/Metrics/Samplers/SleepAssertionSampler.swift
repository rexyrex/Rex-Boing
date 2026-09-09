import Foundation
import IOKit.pwr_mgt
import AppKit

/// Which processes are holding the machine or its display awake.
///
/// `IOPMCopyAssertionsByProcess` is the public call `pmset -g assertions` is
/// built on: one Mach round-trip to powerd returning every active assertion,
/// grouped by owning pid. Only the user-facing scopes are kept — display sleep
/// and system sleep — because those are the ones that answer "why won't it
/// sleep"; declarations like `UserIsActive` assert nothing and are noise here.
final class SleepAssertionSampler {
    /// Assertion types that hold the display on. The second spelling is the
    /// deprecated one; powerd may hand back either, depending on what the
    /// creating app asked for.
    private static let displayTypes: Set<String> = [
        "PreventUserIdleDisplaySleep",  // kIOPMAssertionTypePreventUserIdleDisplaySleep
        "NoDisplaySleepAssertion",
    ]
    /// Types that hold the machine up while letting the display sleep.
    /// `PreventSystemSleep` blocks even forced sleep — an active Time Machine
    /// backup is the usual holder.
    private static let systemTypes: Set<String> = [
        "PreventUserIdleSystemSleep",   // kIOPMAssertionTypePreventUserIdleSystemSleep
        "NoIdleSleepAssertion",
        "PreventSystemSleep",
    ]

    /// powerd's own bookkeeping: it holds a system assertion whenever the
    /// display is on, so surfacing it would answer "why won't it sleep" with
    /// "because the screen is on" on every machine, always. Matched by name —
    /// the one thing that distinguishes it from a real powerd-held assertion
    /// like a tty keep-awake, which deserves to be shown.
    private static let internalAssertionNames: Set<String> = [
        "Powerd - Prevent sleep while display is on",
    ]

    /// Names resolved on earlier passes, kept only for pids still holding an
    /// assertion. `NSRunningApplication` answers through synchronous
    /// LaunchServices XPC, and the same few long-lived holders — a browser,
    /// a music player, a backup — would otherwise be looked up afresh on
    /// every two-second pass for as long as the dashboard is open.
    private var names: [Int32: String] = [:]

    func sample() -> SleepMetrics {
        var metrics = SleepMetrics()

        var raw: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&raw) == kIOReturnSuccess,
              let byPid = raw?.takeRetainedValue() as? [NSNumber: Any]
        else { return metrics }
        metrics.sampled = true

        var blockers: [Int32: SleepBlocker] = [:]
        for (owner, value) in byPid {
            // Per the header: each value is a CFArray of assertion
            // dictionaries. Checked per entry rather than in one deep cast of
            // the whole tree, so one oddly-shaped value cannot blank the lot.
            guard let assertions = value as? [[String: Any]] else { continue }

            for assertion in assertions {
                guard let type = assertion["AssertType"] as? String else { continue }
                let display = Self.displayTypes.contains(type)
                let system = Self.systemTypes.contains(type)
                guard display || system else { continue }
                // Level is On (255) or Off (0); an assertion parked at Off
                // holds nothing. Missing means it was created on, the default.
                if let level = assertion["AssertLevel"] as? Int, level == 0 { continue }
                let assertionName = assertion["AssertName"] as? String
                if let assertionName, Self.internalAssertionNames.contains(assertionName) {
                    continue
                }

                // Audio and media assertions are often held by a daemon on
                // behalf of the app actually playing — coreaudiod for Music —
                // and the on-behalf pid is the honest answer to "who". The key
                // is not in the public header but is present in what powerd
                // returns; absent, the owner stands.
                let pid = (assertion["AssertionOnBehalfOfPID"] as? Int32)
                    ?? Int32(truncating: owner)

                var blocker = blockers[pid]
                    ?? SleepBlocker(pid: pid, name: name(for: pid))
                if display { blocker.preventsDisplaySleep = true }
                if system { blocker.preventsSystemSleep = true }
                if let assertionName, !assertionName.isEmpty,
                   !blocker.assertionNames.contains(assertionName) {
                    blocker.assertionNames.append(assertionName)
                }
                blockers[pid] = blocker
            }
        }

        // A pid that has let go of its assertions can be recycled; forget its
        // name with it so a new occupant is resolved on its own terms.
        names = names.filter { blockers[$0.key] != nil }

        // Display blockers lead — they hold the most — then alphabetical, so
        // the list keeps its order from one sample to the next.
        metrics.blockers = blockers.values.sorted {
            if $0.preventsDisplaySleep != $1.preventsDisplaySleep {
                return $0.preventsDisplaySleep
            }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        return metrics
    }

    private func name(for pid: Int32) -> String {
        if let cached = names[pid] { return cached }
        let resolved = Self.resolveName(for: pid)
        // The placeholder is not worth remembering: a process still starting
        // up can miss its LaunchServices name for one pass and have it the
        // next.
        if resolved != nil { names[pid] = resolved }
        return resolved ?? "pid \(pid)"
    }

    /// App display name where the pid is an app, unix name otherwise; `nil`
    /// when nothing at all could be read about the process.
    private static func resolveName(for pid: Int32) -> String? {
        if let name = NSRunningApplication(processIdentifier: pid)?.localizedName {
            return name
        }
        var buffer = [CChar](repeating: 0, count: 64)
        let length = proc_name(pid, &buffer, UInt32(buffer.count))
        if length > 0 {
            return buffer.withUnsafeBytes { raw in
                let bytes = raw.prefix(min(Int(length), raw.count)).prefix { $0 != 0 }
                return String(decoding: bytes, as: UTF8.self)
            }
        }
        // `proc_name` fails for other users' processes — root daemons hold
        // assertions too. `KERN_PROC` is readable across users, same as the
        // process sampler's start-time fallback; 16 characters, but a name.
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        if sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 {
            let comm = withUnsafeBytes(of: &info.kp_proc.p_comm) { raw -> String in
                String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
            }
            if !comm.isEmpty { return comm }
        }
        return nil
    }
}
