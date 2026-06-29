import AppKit

// Hidden "Beacon / Bacon" easter egg.
//
// Switches the menu bar icon (and an optional in-app About preview) to a
// crispy/bacon variant once the user unlocks it from the About screen.
//
// ASSETS TO ADD LATER (the app currently ships no asset catalog, so these
// resolve to nil and the code falls back to the normal icon, no crash):
//   - "MenuBarIconCrispy": menu bar template image. In the asset catalog set
//     "Render As: Template Image", or rely on the isTemplate flag set below.
//   - "AppIconCrispy": optional crispy app-icon preview shown in About.

/// The two icon looks Beacon can show.
enum IconVariant {
    case normal
    case crispy
}

/// Asset catalog names for the crispy variant. Placeholders for now.
enum IconAsset {
    static let menuBarCrispy = "MenuBarIconCrispy"
    static let appCrispy = "AppIconCrispy"
}

/// UserDefaults keys backing the easter egg, read via `@AppStorage` in the views.
enum CrispyDefaults {
    static let unlocked = "beacon.crispyIconUnlocked"
    static let usesCrispy = "beacon.usesCrispyIcon"
}

/// Centralizes resolution of the crispy icon images, with safe fallbacks so the
/// app builds and runs before the real assets exist. Keeping it here avoids
/// duplicating the lookup/fallback logic across the menu bar and About views.
enum StatusBarIconManager {
    /// Status bar image for a variant, or nil to fall back to the default
    /// SF Symbol label. The crispy image is flagged as a template so it adapts to
    /// light/dark menu bars; a missing asset returns nil (fall back to normal).
    static func statusBarImage(for variant: IconVariant) -> NSImage? {
        switch variant {
        case .normal:
            return nil
        case .crispy:
            guard let image = NSImage(named: IconAsset.menuBarCrispy) else { return nil }
            image.isTemplate = true
            return image
        }
    }

    /// Optional in-app app-icon preview for a variant, or nil to fall back to the
    /// normal symbol.
    static func appPreviewImage(for variant: IconVariant) -> NSImage? {
        switch variant {
        case .normal:
            return nil
        case .crispy:
            return NSImage(named: IconAsset.appCrispy)
        }
    }
}
