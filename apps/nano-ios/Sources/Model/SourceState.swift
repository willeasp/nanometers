import Foundation

/// Connection lifecycle of a `Source` (handoff §07). Drives the Library status dot + Settings copy.
enum SourceState: String, CaseIterable {
    case disconnected   // not added
    case authorizing    // OAuth session in flight
    case connected      // valid access + ≥1 root
    case noRoots        // connected but no root chosen → hidden from Library
    case needsReauth    // refresh failed / revoked → amber dot
    case offline        // unreachable → grey dot, cached metadata browsable
}
