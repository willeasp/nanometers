import Foundation

/// The three analysis meters on the flip B-side (handoff §06C). The switcher is multi-select with at
/// least one always on.
enum AnalysisModule: String, CaseIterable, Identifiable {
    case scope, gonio, spectrum
    var id: String { rawValue }
    /// Accessibility identifier for the switcher button.
    var axID: String {
        switch self {
        case .scope: return "modScope"
        case .gonio: return "modGonio"
        case .spectrum: return "modSpectrum"
        }
    }
}

/// Parse/serialize the persisted `modules` CSV (`@AppStorage("modules")`, default "scope") to an
/// ordered, deduplicated set with the **min-one** invariant — toggling the last-on module is a no-op.
enum ModuleSelection {
    static let order: [AnalysisModule] = [.scope, .gonio, .spectrum]

    static func parse(_ csv: String) -> [AnalysisModule] {
        let present = Set(csv.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) })
        let result = order.filter { present.contains($0.rawValue) }
        return result.isEmpty ? [.scope] : result      // min one
    }

    static func serialize(_ mods: [AnalysisModule]) -> String {
        let canonical = order.filter { mods.contains($0) }
        return (canonical.isEmpty ? [.scope] : canonical).map(\.rawValue).joined(separator: ",")
    }

    /// Toggle `m`; refuses to remove the last remaining module (min one). Returns the new CSV.
    static func toggle(_ csv: String, _ m: AnalysisModule) -> String {
        var mods = parse(csv)
        if mods.contains(m) {
            guard mods.count > 1 else { return serialize(mods) }   // last one stays on
            mods.removeAll { $0 == m }
        } else {
            mods.append(m)
        }
        return serialize(mods)
    }
}
