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

/// Visual state for the menu bar icon. The icon state is drawn into the image
/// itself because `MenuBarExtra` labels do not reliably preserve arbitrary
/// SwiftUI opacity and overlay modifiers once bridged to `NSStatusItem`.
enum MenuBarIconState {
    case idle
    case broadcasting
    case failedIdle
    case failedBroadcasting

    var iconAlpha: CGFloat {
        switch self {
        case .idle, .failedIdle: 0.45
        case .broadcasting, .failedBroadcasting: 1
        }
    }

    var indicatorColor: NSColor? {
        switch self {
        case .idle: nil
        case .broadcasting: .systemGreen
        case .failedIdle, .failedBroadcasting: .systemRed
        }
    }
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
    /// Menu bar icon height in points. The asset is scaled to this height with
    /// its aspect preserved, so it fills the bar like other icons instead of
    /// rendering a small padded slice of a 1024pt canvas.
    static let menuBarHeight: CGFloat = 18

    /// Fully composed status item image for the variant and run state. The
    /// source glyph is drawn in menu-bar white, while the status dot remains
    /// red/green.
    static func statusBarImage(for variant: IconVariant, state: MenuBarIconState) -> NSImage? {
        guard let source = menuBarSourceImage(for: variant) ?? fallbackStatusBarSourceImage() else {
            return nil
        }

        let canvasSize = NSSize(width: max(source.size.width, menuBarHeight), height: menuBarHeight)
        let image = NSImage(size: canvasSize, flipped: false) { rect in
            let iconRect = NSRect(
                x: rect.midX - source.size.width / 2,
                y: rect.midY - source.size.height / 2,
                width: source.size.width,
                height: source.size.height
            )
            drawTemplateGlyph(source, in: iconRect, alpha: state.iconAlpha)

            if let indicatorColor = state.indicatorColor {
                drawIndicator(color: indicatorColor, in: rect)
            }

            return true
        }
        image.isTemplate = false
        image.size = canvasSize
        return image
    }

    private static func menuBarSourceImage(for variant: IconVariant) -> NSImage? {
        let name = variant == .crispy ? IconAsset.menuBarCrispy : IconAsset.menuBar
        guard let base = NSImage(named: name), base.isValid, base.size.height > 0,
              let image = base.copy() as? NSImage else { return nil }
        image.isTemplate = false
        let aspect = base.size.width / base.size.height
        image.size = NSSize(width: menuBarHeight * aspect, height: menuBarHeight)
        return image
    }

    private static func fallbackStatusBarSourceImage() -> NSImage? {
        guard let image = NSImage(
            systemSymbolName: "antenna.radiowaves.left.and.right",
            accessibilityDescription: "Beacon"
        ) else {
            return nil
        }
        image.isTemplate = false
        image.size = NSSize(width: menuBarHeight, height: menuBarHeight)
        return image
    }

    private static func drawTemplateGlyph(_ image: NSImage, in rect: NSRect, alpha: CGFloat) {
        NSGraphicsContext.saveGraphicsState()
        NSColor.white.withAlphaComponent(alpha).setFill()
        rect.fill()
        image.draw(in: rect, from: .zero, operation: .destinationIn, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
    }

    private static func drawIndicator(color: NSColor, in rect: NSRect) {
        let diameter: CGFloat = 5.5
        let inset: CGFloat = 0.75
        let dotRect = NSRect(
            x: rect.maxX - diameter - inset,
            y: rect.minY + inset,
            width: diameter,
            height: diameter
        )

        color.setFill()
        NSBezierPath(ovalIn: dotRect).fill()
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
