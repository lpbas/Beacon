import AppKit

// Hidden "Beacon / Bacon" easter egg plus icon asset lookups.
//
// ASSETS live in Beacon/Assets.xcassets:
//   - "AppIcon"           the app icon (.appiconset, raster PNG)
//   - "MenuBarIcon"       menu bar glyph, template (PDF vector preferred)
//   - "MenuBarIconCrispy" bacon menu bar glyph, template
//   - "AppIconCrispy"     bacon app image, used for the About preview
// Any missing/empty asset falls back to an SF Symbol, so the app always builds.

/// The two icon looks Beacon can show.
enum IconVariant {
    case normal
    case crispy
}

/// Asset catalog names.
enum IconAsset {
    static let app = "AppIcon"
    static let appCrispy = "AppIconCrispy"
    static let menuBar = "MenuBarIcon"
    static let menuBarCrispy = "MenuBarIconCrispy"
}

/// UserDefaults keys backing the easter egg, read via `@AppStorage` in the views.
enum CrispyDefaults {
    static let unlocked = "beacon.crispyIconUnlocked"
    static let usesCrispy = "beacon.usesCrispyIcon"
}

/// Centralizes resolution of the icon images, with safe fallbacks so the app
/// builds and runs before the real assets exist.
enum StatusBarIconManager {
    /// Template menu bar image for the variant, or nil to fall back to the
    /// SF Symbol. Flagged as a template so it adapts to light/dark menu bars.
    /// Menu bar icon height in points. The asset is scaled to this height with
    /// its aspect preserved, so it fills the bar like other icons instead of
    /// rendering a small padded slice of a 1024pt canvas.
    static let menuBarHeight: CGFloat = 18

    static func statusBarImage(for variant: IconVariant) -> NSImage? {
        let name = variant == .crispy ? IconAsset.menuBarCrispy : IconAsset.menuBar
        guard let base = NSImage(named: name), base.isValid, base.size.height > 0,
              let image = base.copy() as? NSImage else { return nil }
        image.isTemplate = true
        let aspect = base.size.width / base.size.height
        image.size = NSSize(width: menuBarHeight * aspect, height: menuBarHeight)
        return image
    }

    /// Optional in-app app-icon preview for a variant (used by About), or nil to
    /// fall back to an SF Symbol. Only the crispy variant has a preview asset.
    static func appPreviewImage(for variant: IconVariant) -> NSImage? {
        switch variant {
        case .normal:
            return NSImage(named: IconAsset.app) ?? NSApplication.shared.applicationIconImage
        case .crispy:
            guard let image = NSImage(named: IconAsset.appCrispy), image.isValid, image.size.width > 0 else { return nil }
            return image
        }
    }
}
