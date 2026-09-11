import AppKit
import Combine
import SwiftUI
import PaceCore

/// Owns the status item. Renders the SwiftUI glyph to an image so every pixel and color
/// is under our control, sets the tooltip, and toggles the popover on click.
@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {
    private let item: NSStatusItem
    private let popover = NSPopover()
    private let store: UsageStore
    private var cancellables = Set<AnyCancellable>()
    private var appearanceObservation: NSKeyValueObservation?
    var openSettings: () -> Void = {}

    init(store: UsageStore) {
        self.store = store
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        item.button?.target = self
        item.button?.action = #selector(togglePopover)
        popover.behavior = .transient
        popover.delegate = self
        popover.contentViewController = NSHostingController(rootView: PopoverView(
            store: store,
            openSettings: { [weak self] in self?.popover.performClose(nil); self?.openSettings() },
            close: { [weak self] in self?.popover.performClose(nil) }))
        store.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in DispatchQueue.main.async { self?.render() } }
            .store(in: &cancellables)
        if let button = item.button {
            appearanceObservation = button.observe(\.effectiveAppearance) { [weak self] _, _ in
                Task { @MainActor in self?.render() }
            }
        }
        render()
    }

    @objc private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        guard let button = item.button else { return }
        Task { await store.refresh() }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    private var isDarkMenuBar: Bool {
        item.button?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    func render() {
        let rows = RowBuilder.rows(store: store)
        let ink: Color = isDarkMenuBar ? .white : .black
        let hours = store.settings.showHoursLeft
            ? rows.first(where: { $0.id == "week" })?.remaining.map(Fmt.hoursOnly)
            : nil
        let view = GlyphView(rows: rows, settings: store.settings, ink: ink, hoursLeft: hours,
                             dimmed: store.isStale || store.snapshot == nil)
        let renderer = ImageRenderer(content: view)
        renderer.scale = item.button?.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        guard let image = renderer.nsImage else { return }
        image.isTemplate = false
        item.button?.image = image
        item.button?.imagePosition = .imageOnly
        item.button?.toolTip = Tooltip.text(rows: rows, store: store)
        dumpIfRequested(image)
    }

    /// Debug aids, both off unless the environment asks:
    /// `PACE_DEBUG_DUMP=/path/glyph.png` writes the rendered glyph on a menu-bar-dark background;
    /// `PACE_DEBUG_DUMP_POPOVER=/path/popover.png` renders the popover offscreen once data has arrived.
    private func dumpIfRequested(_ image: NSImage) {
        let env = ProcessInfo.processInfo.environment
        if let path = env["PACE_DEBUG_DUMP"], !path.isEmpty {
            let scale: CGFloat = 2
            let size = NSSize(width: image.size.width + 8, height: image.size.height + 8)
            let canvas = NSImage(size: size)
            canvas.lockFocus()
            (isDarkMenuBar ? NSColor(srgbRed: 0.17, green: 0.17, blue: 0.19, alpha: 1) : NSColor(srgbRed: 0.93, green: 0.93, blue: 0.95, alpha: 1)).setFill()
            NSRect(origin: .zero, size: size).fill()
            image.draw(in: NSRect(x: 4, y: 4, width: image.size.width, height: image.size.height))
            canvas.unlockFocus()
            writePNG(canvas, to: path, scale: scale)
        }
        if let path = env["PACE_DEBUG_DUMP_POPOVER"], !path.isEmpty, store.snapshot != nil {
            let view = PopoverView(store: store, openSettings: {}, close: {})
                .background(Color(nsColor: .windowBackgroundColor))
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            if let img = renderer.nsImage { writePNG(img, to: path, scale: 2) }
        }
    }

    private func writePNG(_ image: NSImage, to path: String, scale: CGFloat) {
        let pixel = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(pixel.width), pixelsHigh: Int(pixel.height),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
        rep.size = image.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(origin: .zero, size: image.size))
        NSGraphicsContext.restoreGraphicsState()
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}
