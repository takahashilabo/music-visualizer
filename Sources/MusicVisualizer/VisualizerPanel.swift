import AppKit

/// Borderless, transparent, click-through-by-default panel that hosts the
/// visualizer content. Click-through is disabled while "Edit Mode" is on so
/// the user can drag/resize it; otherwise it never intercepts clicks meant
/// for whatever is underneath.
final class VisualizerPanel: NSPanel {
    private static let frameDefaultsKey = "VisualizerPanelFrame"

    private let editBorderView = EditModeBorderView()

    convenience init() {
        let defaultFrame = Self.defaultEdgeFrame()
        self.init(
            contentRect: defaultFrame,
            styleMask: [.borderless, .resizable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
    }

    override init(
        contentRect: NSRect,
        styleMask style: NSWindow.StyleMask,
        backing backingStoreType: NSWindow.BackingStoreType,
        defer flag: Bool
    ) {
        super.init(contentRect: contentRect, styleMask: style, backing: backingStoreType, defer: flag)

        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isMovableByWindowBackground = false
        ignoresMouseEvents = true
        minSize = NSSize(width: 80, height: 80)

        let content = NSView(frame: NSRect(origin: .zero, size: contentRect.size))
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.clear.cgColor
        contentView = content

        editBorderView.frame = content.bounds
        editBorderView.autoresizingMask = [.width, .height]
        editBorderView.isHidden = true
        content.addSubview(editBorderView)

        restoreSavedFrame()
    }

    /// Inserts the visualization view below the edit-mode border overlay so
    /// the dashed outline/grip still draws on top while editing.
    func embedVisualization(_ view: NSView) {
        guard let content = contentView else { return }
        view.frame = content.bounds
        view.autoresizingMask = [.width, .height]
        content.addSubview(view, positioned: .below, relativeTo: editBorderView)
    }

    func setEditMode(_ enabled: Bool) {
        ignoresMouseEvents = !enabled
        editBorderView.isHidden = !enabled
        if !enabled {
            saveFrame()
        }
    }

    func setJoinsAllSpaces(_ enabled: Bool) {
        if enabled {
            collectionBehavior.formUnion([.canJoinAllSpaces, .fullScreenAuxiliary])
        } else {
            collectionBehavior.subtract([.canJoinAllSpaces, .fullScreenAuxiliary])
        }
    }

    /// A tall strip tucked into the top-right of the main screen by default,
    /// so it doesn't sit on top of whatever the user is working on.
    private static func defaultEdgeFrame() -> NSRect {
        guard let visible = NSScreen.main?.visibleFrame else {
            return NSRect(x: 120, y: 120, width: 240, height: 420)
        }
        let width: CGFloat = 320
        let height: CGFloat = 560
        let margin: CGFloat = 16
        let x = visible.maxX - width - margin
        let y = visible.maxY - height - margin
        return NSRect(x: x, y: y, width: width, height: height)
    }

    private func restoreSavedFrame() {
        guard
            let saved = UserDefaults.standard.string(forKey: Self.frameDefaultsKey)
        else { return }
        let rect = NSRectFromString(saved)
        guard rect.width >= minSize.width, rect.height >= minSize.height else { return }
        setFrame(rect, display: false)
    }

    func saveFrame() {
        UserDefaults.standard.set(NSStringFromRect(frame), forKey: Self.frameDefaultsKey)
    }
}
