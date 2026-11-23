import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Usage & Entry

guard CommandLine.arguments.count >= 3 else {
    fputs("Usage: swift tools/make_web_media.swift <input-shots-dir> <output-assets-dir>\n", stderr)
    exit(2)
}

let inputDir = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let outputDir = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

enum ThemeMode: String, CaseIterable {
    case dark
    case light

    var isDark: Bool { self == .dark }
}

// MARK: - Palette & Drawing Helpers

struct CanvasPalette {
    let bgTop: NSColor
    let bgBottom: NSColor
    let glowColor: NSColor
    let gridLine: NSColor
    let panelBg: NSColor
    let sidebarBg: NSColor
    let elevatedBg: NSColor
    let toolbarBg: NSColor
    let cardBorder: NSColor
    let hairline: NSColor
    let textPrimary: NSColor
    let textSecondary: NSColor
    let textMuted: NSColor
    let accentBlue: NSColor
    let accentBlueFill: NSColor
    let accentGreen: NSColor
    let terminalBg: NSColor
    let terminalBorder: NSColor
    let badgeBg: NSColor
    let badgeBorder: NSColor
    let windowBorder: NSColor
    let shadowColor: NSColor

    static func forMode(_ mode: ThemeMode) -> CanvasPalette {
        if mode.isDark {
            return CanvasPalette(
                bgTop: NSColor(srgbRed: 0.067, green: 0.067, blue: 0.075, alpha: 1),
                bgBottom: NSColor(srgbRed: 0.047, green: 0.047, blue: 0.055, alpha: 1),
                glowColor: NSColor(srgbRed: 0.25, green: 0.26, blue: 0.30, alpha: 0.16),
                gridLine: NSColor(white: 1.0, alpha: 0.032),
                panelBg: NSColor(srgbRed: 0.118, green: 0.118, blue: 0.125, alpha: 1),
                sidebarBg: NSColor(srgbRed: 0.145, green: 0.145, blue: 0.157, alpha: 1),
                elevatedBg: NSColor(srgbRed: 0.175, green: 0.175, blue: 0.188, alpha: 1),
                toolbarBg: NSColor(srgbRed: 0.155, green: 0.155, blue: 0.165, alpha: 1),
                cardBorder: NSColor(white: 1.0, alpha: 0.12),
                hairline: NSColor(white: 1.0, alpha: 0.075),
                textPrimary: NSColor(srgbRed: 0.945, green: 0.945, blue: 0.955, alpha: 1),
                textSecondary: NSColor(srgbRed: 0.72, green: 0.72, blue: 0.74, alpha: 1),
                textMuted: NSColor(srgbRed: 0.52, green: 0.52, blue: 0.55, alpha: 1),
                accentBlue: NSColor(srgbRed: 0.23, green: 0.56, blue: 1.0, alpha: 1),
                accentBlueFill: NSColor(srgbRed: 0.23, green: 0.56, blue: 1.0, alpha: 0.20),
                accentGreen: NSColor(srgbRed: 0.22, green: 0.80, blue: 0.45, alpha: 1),
                terminalBg: NSColor(srgbRed: 0.082, green: 0.086, blue: 0.094, alpha: 0.98),
                terminalBorder: NSColor(white: 1.0, alpha: 0.14),
                badgeBg: NSColor(srgbRed: 0.10, green: 0.10, blue: 0.11, alpha: 0.96),
                badgeBorder: NSColor(white: 1.0, alpha: 0.14),
                windowBorder: NSColor(white: 1.0, alpha: 0.14),
                shadowColor: NSColor(white: 0.0, alpha: 0.62)
            )
        } else {
            return CanvasPalette(
                bgTop: NSColor(srgbRed: 0.965, green: 0.965, blue: 0.957, alpha: 1),
                bgBottom: NSColor(srgbRed: 0.925, green: 0.925, blue: 0.916, alpha: 1),
                glowColor: NSColor(srgbRed: 0.55, green: 0.56, blue: 0.60, alpha: 0.12),
                gridLine: NSColor(white: 0.0, alpha: 0.042),
                panelBg: NSColor(srgbRed: 0.988, green: 0.988, blue: 0.992, alpha: 1),
                sidebarBg: NSColor(srgbRed: 0.945, green: 0.945, blue: 0.953, alpha: 1),
                elevatedBg: NSColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 1),
                toolbarBg: NSColor(srgbRed: 0.958, green: 0.958, blue: 0.965, alpha: 1),
                cardBorder: NSColor(white: 0.0, alpha: 0.11),
                hairline: NSColor(white: 0.0, alpha: 0.075),
                textPrimary: NSColor(srgbRed: 0.11, green: 0.11, blue: 0.12, alpha: 1),
                textSecondary: NSColor(srgbRed: 0.34, green: 0.34, blue: 0.37, alpha: 1),
                textMuted: NSColor(srgbRed: 0.52, green: 0.52, blue: 0.55, alpha: 1),
                accentBlue: NSColor(srgbRed: 0.04, green: 0.44, blue: 0.95, alpha: 1),
                accentBlueFill: NSColor(srgbRed: 0.04, green: 0.44, blue: 0.95, alpha: 0.13),
                accentGreen: NSColor(srgbRed: 0.12, green: 0.65, blue: 0.34, alpha: 1),
                terminalBg: NSColor(srgbRed: 0.115, green: 0.118, blue: 0.128, alpha: 0.98),
                terminalBorder: NSColor(white: 0.0, alpha: 0.24),
                badgeBg: NSColor(srgbRed: 0.98, green: 0.98, blue: 0.975, alpha: 0.96),
                badgeBorder: NSColor(white: 0.0, alpha: 0.12),
                windowBorder: NSColor(white: 0.0, alpha: 0.12),
                shadowColor: NSColor(white: 0.0, alpha: 0.20)
            )
        }
    }
}

/// Converts top-left layout coordinates to AppKit bottom-left coordinates.
func topRect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, in canvasHeight: CGFloat) -> NSRect {
    NSRect(x: x, y: canvasHeight - y - h, width: w, height: h)
}

func renderBitmap(width: Int, height: Int, draw: (_ size: NSSize) -> Void) -> CGImage {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: width,
        pixelsHigh: height,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!
    rep.size = NSSize(width: width, height: height)

    let context = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    NSColor.clear.setFill()
    NSRect(x: 0, y: 0, width: width, height: height).fill()
    draw(NSSize(width: width, height: height))
    context.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()

    return rep.cgImage!
}

func savePNG(_ cgImage: CGImage, to url: URL) throws {
    let rep = NSBitmapImageRep(cgImage: cgImage)
    guard let data = rep.representation(using: .png, properties: [.compressionFactor: 1.0]) else {
        throw NSError(domain: "make_web_media", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed PNG encoding"])
    }
    try data.write(to: url, options: .atomic)
}

func saveGIF(frames: [(image: CGImage, delay: Double)], to url: URL) throws {
    guard let dest = CGImageDestinationCreateWithURL(
        url as CFURL,
        UTType.gif.identifier as CFString,
        frames.count,
        nil
    ) else {
        throw NSError(domain: "make_web_media", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed GIF destination"])
    }

    let fileProperties: [CFString: Any] = [
        kCGImagePropertyGIFDictionary: [
            kCGImagePropertyGIFLoopCount: 0,
            kCGImagePropertyGIFHasGlobalColorMap: false,
        ]
    ]
    CGImageDestinationSetProperties(dest, fileProperties as CFDictionary)

    for frame in frames {
        let frameProps: [CFString: Any] = [
            kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFDelayTime: frame.delay,
                kCGImagePropertyGIFUnclampedDelayTime: frame.delay,
            ]
        ]
        CGImageDestinationAddImage(dest, frame.image, frameProps as CFDictionary)
    }

    guard CGImageDestinationFinalize(dest) else {
        throw NSError(domain: "make_web_media", code: 3, userInfo: [NSLocalizedDescriptionKey: "Failed GIF finalize"])
    }
}

func drawBackdrop(size: NSSize, palette: CanvasPalette) {
    let rect = NSRect(origin: .zero, size: size)
    let gradient = NSGradient(starting: palette.bgTop, ending: palette.bgBottom)
    gradient?.draw(in: rect, angle: -90)

    // Subtle radial spotlight centered in stage.
    if let radial = NSGradient(colors: [palette.glowColor, palette.glowColor.withAlphaComponent(0)]) {
        radial.draw(
            fromCenter: NSPoint(x: size.width * 0.5, y: size.height * 0.52),
            radius: 0,
            toCenter: NSPoint(x: size.width * 0.5, y: size.height * 0.52),
            radius: size.width * 0.58,
            options: []
        )
    }

    // Subtle architectural 48px hairline grid.
    palette.gridLine.setStroke()
    let gridPath = NSBezierPath()
    gridPath.lineWidth = 1
    var gx: CGFloat = 48
    while gx < size.width {
        gridPath.move(to: NSPoint(x: gx + 0.5, y: 0))
        gridPath.line(to: NSPoint(x: gx + 0.5, y: size.height))
        gx += 48
    }
    var gy: CGFloat = 48
    while gy < size.height {
        gridPath.move(to: NSPoint(x: 0, y: gy + 0.5))
        gridPath.line(to: NSPoint(x: size.width, y: gy + 0.5))
        gy += 48
    }
    gridPath.stroke()
}

func drawTopTag(
    _ label: String,
    rightDetail: String?,
    in size: NSSize,
    palette: CanvasPalette,
    topOffset: CGFloat = 22
) {
    let monoFont = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .medium)
    let smallMono = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
    let pillHeight: CGFloat = 28

    let attr: [NSAttributedString.Key: Any] = [
        .font: monoFont,
        .foregroundColor: palette.textSecondary,
    ]
    let measured = (label as NSString).size(withAttributes: attr)

    var totalWidth = measured.width + 24
    var detailWidth: CGFloat = 0
    if let rightDetail {
        let dMeasured = (rightDetail as NSString).size(withAttributes: [.font: smallMono])
        detailWidth = dMeasured.width
        totalWidth += detailWidth + 22
    }

    let x = round((size.width - totalWidth) / 2)
    let pillRect = topRect(x, topOffset, totalWidth, pillHeight, in: size.height)

    let path = NSBezierPath(roundedRect: pillRect, xRadius: 4, yRadius: 4)
    palette.badgeBg.setFill()
    path.fill()
    palette.badgeBorder.setStroke()
    path.lineWidth = 1
    path.stroke()

    let labelY = pillRect.minY + (pillHeight - measured.height) / 2 - 0.5
    (label as NSString).draw(at: NSPoint(x: pillRect.minX + 12, y: labelY), withAttributes: attr)

    if let rightDetail {
        let sepX = pillRect.minX + 12 + measured.width + 10
        palette.hairline.setStroke()
        let sep = NSBezierPath()
        sep.move(to: NSPoint(x: sepX + 0.5, y: pillRect.minY + 6))
        sep.line(to: NSPoint(x: sepX + 0.5, y: pillRect.maxY - 6))
        sep.stroke()

        let dAttr: [NSAttributedString.Key: Any] = [
            .font: smallMono,
            .foregroundColor: palette.textMuted,
        ]
        (rightDetail as NSString).draw(at: NSPoint(x: sepX + 11, y: labelY), withAttributes: dAttr)
    }
}

func drawFramedWindow(
    image: NSImage,
    in targetRect: NSRect,
    cornerRadius: CGFloat,
    palette: CanvasPalette,
    opacity: CGFloat = 1.0,
    shadowBlur: CGFloat = 34,
    shadowYOffset: CGFloat = -14
) {
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = palette.shadowColor
    shadow.shadowBlurRadius = shadowBlur
    shadow.shadowOffset = NSSize(width: 0, height: shadowYOffset)
    shadow.set()

    let clipPath = NSBezierPath(roundedRect: targetRect, xRadius: cornerRadius, yRadius: cornerRadius)
    palette.panelBg.setFill()
    clipPath.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.saveGraphicsState()
    clipPath.addClip()
    image.draw(in: targetRect, from: .zero, operation: .sourceOver, fraction: opacity)
    NSGraphicsContext.restoreGraphicsState()

    palette.windowBorder.setStroke()
    clipPath.lineWidth = 1
    clipPath.stroke()
}

func loadShot(_ filename: String) -> NSImage {
    let url = inputDir.appendingPathComponent(filename)
    guard let img = NSImage(contentsOf: url) else {
        fputs("Missing input screenshot: \(url.path)\n", stderr)
        exit(1)
    }
    return img
}

func fittedFrame(for img: NSImage, inside box: NSRect) -> NSRect {
    let imgSize = img.size
    guard imgSize.width > 0, imgSize.height > 0 else { return box }
    let scale = min(box.width / imgSize.width, box.height / imgSize.height)
    let w = round(imgSize.width * scale)
    let h = round(imgSize.height * scale)
    let x = round(box.minX + (box.width - w) / 2)
    let y = round(box.minY + (box.height - h) / 2)
    return NSRect(x: x, y: y, width: w, height: h)
}

// MARK: - 1. Framed Static Screenshots (1440x900)

func generateStaticScreenshots() throws {
    let W = 1440
    let H = 900
    let wF = CGFloat(W)
    let hF = CGFloat(H)

    for mode in ThemeMode.allCases {
        let palette = CanvasPalette.forMode(mode)
        let m = mode.rawValue

        // Single-window centered views
        let singleSpecs: [(name: String, file: String, tag: String, detail: String)] = [
            ("overview", "overview-\(m).png", "OPEN DRIVE · OVERVIEW", "VIRTUAL DISK · LIVE QUOTA"),
            ("accounts", "accounts-\(m).png", "OPEN DRIVE · ACCOUNTS", "MULTI-ACCOUNT · PKCE"),
            ("uploads", "uploads-\(m).png", "OPEN DRIVE · UPLOADS", "HOTSPOT PAUSE · RESUMABLE PUT"),
            ("offline", "offline-\(m).png", "OPEN DRIVE · OFFLINE CACHE", "PINNED LOCAL COPIES"),
        ]

        for spec in singleSpecs {
            let shot = loadShot(spec.file)
            let cg = renderBitmap(width: W, height: H) { size in
                drawBackdrop(size: size, palette: palette)
                drawTopTag(spec.tag, rightDetail: spec.detail, in: size, palette: palette)
                let avail = topRect(110, 70, wF - 220, hF - 102, in: hF)
                let frame = fittedFrame(for: shot, inside: avail)
                drawFramedWindow(image: shot, in: frame, cornerRadius: 15, palette: palette)
            }
            try savePNG(cg, to: outputDir.appendingPathComponent("\(spec.name)-\(m).png"))
        }

        // Global Search Palette floating over softly dimmed Overview window
        do {
            let overviewShot = loadShot("overview-\(m).png")
            let paletteShot = loadShot("palette-\(m).png")
            let cg = renderBitmap(width: W, height: H) { size in
                drawBackdrop(size: size, palette: palette)
                drawTopTag("GLOBAL SEARCH PALETTE · ⌃⌥F", rightDetail: "SQLITE TREE INDEX", in: size, palette: palette)

                let bgAvail = topRect(160, 74, wF - 320, hF - 110, in: hF)
                let bgFrame = fittedFrame(for: overviewShot, inside: bgAvail)
                drawFramedWindow(
                    image: overviewShot,
                    in: bgFrame,
                    cornerRadius: 15,
                    palette: palette,
                    opacity: mode.isDark ? 0.42 : 0.52,
                    shadowBlur: 24,
                    shadowYOffset: -10
                )

                let pW: CGFloat = 760
                let pH = round(pW * (paletteShot.size.height / paletteShot.size.width))
                let pRect = topRect(round((wF - pW) / 2), round((hF - pH) / 2) + 12, pW, pH, in: hF)
                drawFramedWindow(
                    image: paletteShot,
                    in: pRect,
                    cornerRadius: 16,
                    palette: palette,
                    opacity: 1.0,
                    shadowBlur: 46,
                    shadowYOffset: -20
                )
            }
            try savePNG(cg, to: outputDir.appendingPathComponent("palette-\(m).png"))
        }

        // Settings dual-window showcase (General left + Network Hotspot Protection right)
        do {
            let generalShot = loadShot("settings-general-\(m).png")
            let networkShot = loadShot("settings-network-\(m).png")
            let cg = renderBitmap(width: W, height: H) { size in
                drawBackdrop(size: size, palette: palette)
                drawTopTag("SETTINGS · MOUNT, CACHE & HOTSPOT GUARD", rightDetail: "NWPATHMONITOR · 10 GiB CACHE", in: size, palette: palette)

                let gAvail = topRect(56, 78, 636, 766, in: hF)
                let gFrame = fittedFrame(for: generalShot, inside: gAvail)
                drawFramedWindow(image: generalShot, in: gFrame, cornerRadius: 15, palette: palette)

                let nW: CGFloat = 648
                let nH = round(nW * (networkShot.size.height / networkShot.size.width))
                let nY = round(78 + (766 - nH) / 2)
                let nRect = topRect(736, nY, nW, nH, in: hF)
                drawFramedWindow(image: networkShot, in: nRect, cornerRadius: 15, palette: palette, shadowBlur: 40, shadowYOffset: -18)
            }
            try savePNG(cg, to: outputDir.appendingPathComponent("settings-\(m).png"))
        }

        // Zero-Knowledge Vault dual-window showcase (Accounts left + Accounts & Vault Settings right)
        do {
            let accountsShot = loadShot("accounts-\(m).png")
            let vaultSettingsShot = loadShot("settings-accounts-\(m).png")
            let cg = renderBitmap(width: W, height: H) { size in
                drawBackdrop(size: size, palette: palette)
                drawTopTag("ZERO-KNOWLEDGE VAULT", rightDetail: "ODE1 STREAM + ODNAMES · AES-256-GCM", in: size, palette: palette)

                let aAvail = topRect(52, 92, 650, 740, in: hF)
                let aFrame = fittedFrame(for: accountsShot, inside: aAvail)
                drawFramedWindow(image: accountsShot, in: aFrame, cornerRadius: 15, palette: palette)

                let vAvail = topRect(738, 82, 650, 760, in: hF)
                let vFrame = fittedFrame(for: vaultSettingsShot, inside: vAvail)
                drawFramedWindow(image: vaultSettingsShot, in: vFrame, cornerRadius: 15, palette: palette, shadowBlur: 42, shadowYOffset: -18)
            }
            try savePNG(cg, to: outputDir.appendingPathComponent("vault-\(m).png"))
        }
    }
}

// MARK: - 2. Vector macOS Sequoia Finder + Get Info + Terminal + Live Rename GIF (960x600)

struct FinderDemoState {
    var topTag: String
    var topDetail: String
    var driveName: String
    var activeSidebarItem: String
    var selectedFile: String?
    var terminalProgress: CGFloat
    var terminalLine2: CGFloat
    var showGetInfo: CGFloat
    var showRenamePopover: Bool
    var renameTypedText: String
    var showCursor: Bool
    var cursorPos: NSPoint // top-left coordinates on 960x600
    var cursorClicking: Bool
}

func drawTrafficLights(x: CGFloat, y: CGFloat, canvasH: CGFloat, spacing: CGFloat = 20) {
    let colors: [NSColor] = [
        NSColor(srgbRed: 1.0, green: 0.373, blue: 0.341, alpha: 1),
        NSColor(srgbRed: 0.996, green: 0.737, blue: 0.180, alpha: 1),
        NSColor(srgbRed: 0.157, green: 0.784, blue: 0.251, alpha: 1),
    ]
    for (idx, col) in colors.enumerated() {
        let dot = topRect(x + CGFloat(idx) * spacing, y, 11.5, 11.5, in: canvasH)
        let path = NSBezierPath(ovalIn: dot)
        col.setFill()
        path.fill()
    }
}

func drawText(
    _ str: String,
    atTopLeft pt: NSPoint,
    canvasH: CGFloat,
    font: NSFont,
    color: NSColor,
    lineHeight: CGFloat? = nil
) {
    let attrs: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: color,
    ]
    let size = (str as NSString).size(withAttributes: attrs)
    let h = lineHeight ?? size.height
    (str as NSString).draw(at: NSPoint(x: pt.x, y: canvasH - pt.y - h), withAttributes: attrs)
}

func drawFinderScene(state: FinderDemoState, mode: ThemeMode) -> CGImage {
    let W = 960
    let H = 600
    let hF = CGFloat(H)
    let p = CanvasPalette.forMode(mode)

    return renderBitmap(width: W, height: H) { size in
        drawBackdrop(size: size, palette: p)
        drawTopTag(state.topTag, rightDetail: state.topDetail, in: size, palette: p, topOffset: 16)

        // Main macOS Sequoia Finder Window
        let winX: CGFloat = 44
        let winY: CGFloat = 58
        let winW: CGFloat = 872
        let winH: CGFloat = 510
        let winRect = topRect(winX, winY, winW, winH, in: hF)

        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = p.shadowColor
        shadow.shadowBlurRadius = 32
        shadow.shadowOffset = NSSize(width: 0, height: -14)
        shadow.set()
        let winPath = NSBezierPath(roundedRect: winRect, xRadius: 14, yRadius: 14)
        p.panelBg.setFill()
        winPath.fill()
        NSGraphicsContext.restoreGraphicsState()

        NSGraphicsContext.saveGraphicsState()
        winPath.addClip()

        // Left Sidebar (196px wide)
        let sideW: CGFloat = 198
        let sideRect = topRect(winX, winY, sideW, winH, in: hF)
        p.sidebarBg.setFill()
        sideRect.fill()

        // Sidebar divider
        p.hairline.setStroke()
        let sideDiv = NSBezierPath()
        sideDiv.move(to: NSPoint(x: winX + sideW + 0.5, y: winRect.minY))
        sideDiv.line(to: NSPoint(x: winX + sideW + 0.5, y: winRect.maxY))
        sideDiv.stroke()

        drawTrafficLights(x: winX + 16, y: winY + 16, canvasH: hF)

        // Sidebar Sections
        drawText(
            "Favourites",
            atTopLeft: NSPoint(x: winX + 16, y: winY + 52),
            canvasH: hF,
            font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            color: p.textMuted
        )

        let favItems: [(name: String, badge: String?, isDrive: Bool)] = [
            ("Recents", "REC", false),
            ("Applications", "APP", false),
            ("Desktop", "DSK", false),
            ("Documents", "DOC", false),
            (state.driveName, "DRV", true),
            ("Downloads", "DL", false),
        ]

        for (i, item) in favItems.enumerated() {
            let iy = winY + 74 + CGFloat(i) * 28
            let isSelected = item.name == state.activeSidebarItem || (item.isDrive && state.activeSidebarItem == state.driveName)
            if isSelected {
                let selRect = topRect(winX + 10, iy - 3, sideW - 20, 24, in: hF)
                let pill = NSBezierPath(roundedRect: selRect, xRadius: 6, yRadius: 6)
                p.accentBlueFill.setFill()
                pill.fill()
            }

            // Clean vector glyph chip
            let iconRect = topRect(winX + 18, iy + 2, 14, 14, in: hF)
            let iconPath = NSBezierPath(roundedRect: iconRect, xRadius: 3.5, yRadius: 3.5)
            (item.isDrive ? p.accentBlue : p.textMuted.withAlphaComponent(0.35)).setFill()
            iconPath.fill()

            drawText(
                item.name,
                atTopLeft: NSPoint(x: winX + 40, y: iy + 1),
                canvasH: hF,
                font: NSFont.systemFont(ofSize: 12.5, weight: item.isDrive ? .semibold : .regular),
                color: isSelected ? p.textPrimary : p.textSecondary
            )

            // Eject indicator for mounted drive in Favourites
            if item.isDrive {
                drawText(
                    "⏏",
                    atTopLeft: NSPoint(x: winX + sideW - 26, y: iy + 1),
                    canvasH: hF,
                    font: NSFont.systemFont(ofSize: 11, weight: .medium),
                    color: p.textMuted
                )
            }
        }

        drawText(
            "Locations",
            atTopLeft: NSPoint(x: winX + 16, y: winY + 266),
            canvasH: hF,
            font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            color: p.textMuted
        )

        let locations: [(name: String, sub: String, dot: NSColor)] = [
            ("Macintosh HD", "37.4 GB free", p.textMuted),
            (state.driveName, "5.37 TB available", p.accentGreen),
        ]
        for (i, loc) in locations.enumerated() {
            let ly = winY + 290 + CGFloat(i) * 34
            let dotRect = topRect(winX + 18, ly + 4, 10, 10, in: hF)
            loc.dot.setFill()
            NSBezierPath(ovalIn: dotRect).fill()
            drawText(
                loc.name,
                atTopLeft: NSPoint(x: winX + 36, y: ly),
                canvasH: hF,
                font: NSFont.systemFont(ofSize: 12.5, weight: i == 1 ? .semibold : .regular),
                color: p.textPrimary
            )
            drawText(
                loc.sub,
                atTopLeft: NSPoint(x: winX + 36, y: ly + 15),
                canvasH: hF,
                font: NSFont.systemFont(ofSize: 10, weight: .regular),
                color: i == 1 ? p.accentGreen : p.textMuted
            )
        }

        // Right Toolbar Area
        let mainX = winX + sideW
        let mainW = winW - sideW
        let barH: CGFloat = 48
        let barRect = topRect(mainX, winY, mainW, barH, in: hF)
        p.toolbarBg.setFill()
        barRect.fill()

        p.hairline.setStroke()
        let barLine = NSBezierPath()
        barLine.move(to: NSPoint(x: mainX, y: barRect.minY + 0.5))
        barLine.line(to: NSPoint(x: mainX + mainW, y: barRect.minY + 0.5))
        barLine.stroke()

        // Nav chevrons + active volume title
        drawText(
            "‹   ›",
            atTopLeft: NSPoint(x: mainX + 18, y: winY + 14),
            canvasH: hF,
            font: NSFont.systemFont(ofSize: 16, weight: .medium),
            color: p.textMuted
        )
        drawText(
            "\(state.driveName)  /  Personal Drive",
            atTopLeft: NSPoint(x: mainX + 70, y: winY + 15),
            canvasH: hF,
            font: NSFont.systemFont(ofSize: 13.5, weight: .semibold),
            color: p.textPrimary
        )

        // Path pill + Search pill in Finder toolbar
        let searchRect = topRect(mainX + mainW - 196, winY + 11, 178, 26, in: hF)
        let searchPath = NSBezierPath(roundedRect: searchRect, xRadius: 6, yRadius: 6)
        p.elevatedBg.setFill()
        searchPath.fill()
        p.cardBorder.setStroke()
        searchPath.stroke()
        drawText(
            "⌕  Search \(state.driveName)",
            atTopLeft: NSPoint(x: mainX + mainW - 186, y: winY + 16),
            canvasH: hF,
            font: NSFont.systemFont(ofSize: 11.5, weight: .regular),
            color: p.textMuted
        )

        // Column headers
        let colY = winY + barH + 10
        drawText("Name", atTopLeft: NSPoint(x: mainX + 46, y: colY), canvasH: hF, font: NSFont.systemFont(ofSize: 11, weight: .semibold), color: p.textMuted)
        drawText("Date Modified", atTopLeft: NSPoint(x: mainX + 312, y: colY), canvasH: hF, font: NSFont.systemFont(ofSize: 11, weight: .semibold), color: p.textMuted)
        drawText("Size", atTopLeft: NSPoint(x: mainX + 468, y: colY), canvasH: hF, font: NSFont.systemFont(ofSize: 11, weight: .semibold), color: p.textMuted)
        drawText("Kind", atTopLeft: NSPoint(x: mainX + 542, y: colY), canvasH: hF, font: NSFont.systemFont(ofSize: 11, weight: .semibold), color: p.textMuted)

        p.hairline.setStroke()
        let colSep = NSBezierPath()
        colSep.move(to: NSPoint(x: mainX + 16, y: hF - (colY + 20)))
        colSep.line(to: NSPoint(x: mainX + mainW - 16, y: hF - (colY + 20)))
        colSep.stroke()

        // Synthetic File Rows
        struct FileRow {
            let name: String
            let date: String
            let size: String
            let kind: String
            let badgeColor: NSColor
        }

        let rows: [FileRow] = [
            FileRow(name: "Personal Drive", date: "Today, 10:42 AM", size: "--", kind: "Cloud Root", badgeColor: p.accentBlue),
            FileRow(name: "Private Vault", date: "Today, 09:15 AM", size: "--", kind: "ODE1 Vault", badgeColor: p.accentGreen),
            FileRow(name: "Financials-2026.pdf", date: "Yesterday, 4:18 PM", size: "12.6 MB", kind: "PDF · 0 B local", badgeColor: NSColor.systemOrange),
            FileRow(name: "Quarterly-Deck.key", date: "Nov 18, 2026", size: "48.2 MB", kind: "Keynote", badgeColor: p.accentBlue),
            FileRow(name: "Launch Checklist.md", date: "Nov 14, 2026", size: "25 KB", kind: "Markdown", badgeColor: p.textMuted),
            FileRow(name: "deploy-preview.sh", date: "Today, 11:05 AM", size: "4 KB", kind: "Shell (-rwxr-xr-x)", badgeColor: p.accentGreen),
        ]

        for (idx, row) in rows.enumerated() {
            let ry = colY + 28 + CGFloat(idx) * 34
            let isRowSel = (state.selectedFile == row.name)
            if isRowSel {
                let rowBg = topRect(mainX + 12, ry - 4, mainW - 24, 30, in: hF)
                let rPath = NSBezierPath(roundedRect: rowBg, xRadius: 6, yRadius: 6)
                p.accentBlueFill.setFill()
                rPath.fill()
            } else if idx % 2 == 1 {
                let altBg = topRect(mainX + 12, ry - 4, mainW - 24, 30, in: hF)
                p.hairline.withAlphaComponent(0.035).setFill()
                NSBezierPath(roundedRect: altBg, xRadius: 5, yRadius: 5).fill()
            }

            let dot = topRect(mainX + 24, ry + 4, 13, 13, in: hF)
            let dotPath = NSBezierPath(roundedRect: dot, xRadius: idx < 2 ? 3 : 2, yRadius: idx < 2 ? 3 : 2)
            row.badgeColor.setFill()
            dotPath.fill()

            drawText(row.name, atTopLeft: NSPoint(x: mainX + 46, y: ry + 2), canvasH: hF, font: NSFont.systemFont(ofSize: 12.5, weight: isRowSel ? .semibold : .regular), color: p.textPrimary)
            drawText(row.date, atTopLeft: NSPoint(x: mainX + 312, y: ry + 3), canvasH: hF, font: NSFont.systemFont(ofSize: 11.5, weight: .regular), color: p.textSecondary)
            drawText(row.size, atTopLeft: NSPoint(x: mainX + 468, y: ry + 3), canvasH: hF, font: NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .regular), color: p.textSecondary)
            drawText(row.kind, atTopLeft: NSPoint(x: mainX + 542, y: ry + 3), canvasH: hF, font: NSFont.systemFont(ofSize: 11, weight: .regular), color: idx == 2 ? p.accentGreen : p.textMuted)
        }

        // Bottom Finder Status Bar showing Live Google Drive Free Space!
        let statusH: CGFloat = 28
        let statusRect = topRect(mainX, winY + winH - statusH, mainW, statusH, in: hF)
        p.toolbarBg.setFill()
        statusRect.fill()

        p.hairline.setStroke()
        let sLine = NSBezierPath()
        sLine.move(to: NSPoint(x: mainX, y: statusRect.maxY - 0.5))
        sLine.line(to: NSPoint(x: mainX + mainW, y: statusRect.maxY - 0.5))
        sLine.stroke()

        drawText(
            "6 items, 5.37 TB available  ·  ~/Library/OpenDrive/\(state.driveName)",
            atTopLeft: NSPoint(x: mainX + 18, y: winY + winH - 21),
            canvasH: hF,
            font: NSFont.systemFont(ofSize: 11, weight: .medium),
            color: p.textSecondary
        )

        NSGraphicsContext.restoreGraphicsState()

        // Finder Outer Border
        p.windowBorder.setStroke()
        winPath.lineWidth = 1
        winPath.stroke()

        // Overlay 1: Finder Get Info Inspector Card (Zero bytes on disk!)
        if state.showGetInfo > 0.01 {
            let alpha = state.showGetInfo
            let infoW: CGFloat = 310
            let infoH: CGFloat = 248
            let infoX: CGFloat = 588
            let infoY: CGFloat = 112 + (1 - alpha) * 10
            let infoRect = topRect(infoX, infoY, infoW, infoH, in: hF)

            NSGraphicsContext.saveGraphicsState()
            let sh = NSShadow()
            sh.shadowColor = p.shadowColor
            sh.shadowBlurRadius = 26
            sh.shadowOffset = NSSize(width: 0, height: -12)
            sh.set()
            let iPath = NSBezierPath(roundedRect: infoRect, xRadius: 12, yRadius: 12)
            p.elevatedBg.withAlphaComponent(alpha).setFill()
            iPath.fill()
            NSGraphicsContext.restoreGraphicsState()

            p.cardBorder.withAlphaComponent(alpha).setStroke()
            iPath.lineWidth = 1
            iPath.stroke()

            drawText("Financials-2026.pdf Info", atTopLeft: NSPoint(x: infoX + 16, y: infoY + 12), canvasH: hF, font: NSFont.systemFont(ofSize: 12.5, weight: .semibold), color: p.textPrimary.withAlphaComponent(alpha))
            drawText("⌘I", atTopLeft: NSPoint(x: infoX + infoW - 34, y: infoY + 12), canvasH: hF, font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular), color: p.textMuted.withAlphaComponent(alpha))

            p.hairline.withAlphaComponent(alpha).setStroke()
            let div = NSBezierPath()
            div.move(to: NSPoint(x: infoX + 12, y: hF - (infoY + 38)))
            div.line(to: NSPoint(x: infoX + infoW - 12, y: hF - (infoY + 38)))
            div.stroke()

            let infoRows: [(k: String, v: String, highlight: Bool)] = [
                ("Kind:", "PDF Document", false),
                ("Logical Size:", "12,642,180 bytes (12.6 MB)", false),
                ("On Disk:", "Zero bytes on disk", true),
                ("Volume Quota:", "5.37 TB available (Google Drive)", true),
                ("Account:", "Personal Drive (Whole Drive)", false),
                ("POSIX Mode:", "-rw-r--r--  (statfs / NFSv3)", false),
            ]
            for (idx, row) in infoRows.enumerated() {
                let ry = infoY + 52 + CGFloat(idx) * 28
                if row.highlight {
                    let hRect = topRect(infoX + 10, ry - 4, infoW - 20, 23, in: hF)
                    (idx == 2 ? p.accentGreen.withAlphaComponent(0.14 * alpha) : p.accentBlue.withAlphaComponent(0.14 * alpha)).setFill()
                    NSBezierPath(roundedRect: hRect, xRadius: 5, yRadius: 5).fill()
                }
                drawText(row.k, atTopLeft: NSPoint(x: infoX + 16, y: ry), canvasH: hF, font: NSFont.systemFont(ofSize: 11, weight: .semibold), color: p.textMuted.withAlphaComponent(alpha))
                drawText(row.v, atTopLeft: NSPoint(x: infoX + 106, y: ry), canvasH: hF, font: NSFont.systemFont(ofSize: 11, weight: row.highlight ? .semibold : .regular), color: (row.highlight ? p.textPrimary : p.textSecondary).withAlphaComponent(alpha))
            }
        }

        // Overlay 2: Terminal POSIX workflow card
        if state.terminalProgress > 0.01 {
            let alpha = state.terminalProgress
            let tW: CGFloat = 530
            let tH: CGFloat = 148
            let tX: CGFloat = 368
            let tY: CGFloat = 398 + (1 - alpha) * 12
            let tRect = topRect(tX, tY, tW, tH, in: hF)

            NSGraphicsContext.saveGraphicsState()
            let sh = NSShadow()
            sh.shadowColor = NSColor(white: 0, alpha: 0.45 * alpha)
            sh.shadowBlurRadius = 24
            sh.shadowOffset = NSSize(width: 0, height: -10)
            sh.set()
            let tPath = NSBezierPath(roundedRect: tRect, xRadius: 10, yRadius: 10)
            p.terminalBg.withAlphaComponent(alpha).setFill()
            tPath.fill()
            NSGraphicsContext.restoreGraphicsState()

            p.terminalBorder.withAlphaComponent(alpha).setStroke()
            tPath.lineWidth = 1
            tPath.stroke()

            drawTrafficLights(x: tX + 14, y: tY + 12, canvasH: hF, spacing: 16)
            drawText(
                "zsh — ~/Library/OpenDrive/\(state.driveName)/Personal Drive",
                atTopLeft: NSPoint(x: tX + 76, y: tY + 11),
                canvasH: hF,
                font: NSFont.monospacedSystemFont(ofSize: 11, weight: .medium),
                color: NSColor(white: 0.72, alpha: alpha)
            )

            let line1 = "$ chmod +x deploy-preview.sh && ln -s deploy-preview.sh current.sh"
            drawText(
                line1,
                atTopLeft: NSPoint(x: tX + 16, y: tY + 46),
                canvasH: hF,
                font: NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular),
                color: NSColor(srgbRed: 0.94, green: 0.95, blue: 0.96, alpha: alpha)
            )

            if state.terminalLine2 > 0.05 {
                let a2 = min(1, state.terminalLine2) * alpha
                drawText(
                    "$ ls -la current.sh deploy-preview.sh",
                    atTopLeft: NSPoint(x: tX + 16, y: tY + 72),
                    canvasH: hF,
                    font: NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular),
                    color: NSColor(srgbRed: 0.68, green: 0.72, blue: 0.78, alpha: a2)
                )
                drawText(
                    "lrwxr-xr-x  1 alex  staff   17B  current.sh -> deploy-preview.sh",
                    atTopLeft: NSPoint(x: tX + 16, y: tY + 96),
                    canvasH: hF,
                    font: NSFont.monospacedSystemFont(ofSize: 11.2, weight: .regular),
                    color: NSColor(srgbRed: 0.35, green: 0.88, blue: 0.56, alpha: a2)
                )
                drawText(
                    "-rwxr-xr-x  1 alex  staff  4.0K  deploy-preview.sh  (persisted x-bit)",
                    atTopLeft: NSPoint(x: tX + 16, y: tY + 118),
                    canvasH: hF,
                    font: NSFont.monospacedSystemFont(ofSize: 11.2, weight: .regular),
                    color: NSColor(srgbRed: 0.45, green: 0.74, blue: 1.0, alpha: a2)
                )
            }
        }

        // Overlay 3: Live Rename Popover
        if state.showRenamePopover {
            let rW: CGFloat = 340
            let rH: CGFloat = 128
            let rX: CGFloat = 348
            let rY: CGFloat = 178
            let rRect = topRect(rX, rY, rW, rH, in: hF)

            NSGraphicsContext.saveGraphicsState()
            let sh = NSShadow()
            sh.shadowColor = p.shadowColor
            sh.shadowBlurRadius = 30
            sh.shadowOffset = NSSize(width: 0, height: -14)
            sh.set()
            let rPath = NSBezierPath(roundedRect: rRect, xRadius: 12, yRadius: 12)
            p.elevatedBg.setFill()
            rPath.fill()
            NSGraphicsContext.restoreGraphicsState()

            p.cardBorder.setStroke()
            rPath.lineWidth = 1
            rPath.stroke()

            drawText("Rename Mounted Volume", atTopLeft: NSPoint(x: rX + 18, y: rY + 16), canvasH: hF, font: NSFont.systemFont(ofSize: 13, weight: .semibold), color: p.textPrimary)

            let fieldRect = topRect(rX + 18, rY + 46, rW - 36, 32, in: hF)
            let fPath = NSBezierPath(roundedRect: fieldRect, xRadius: 6, yRadius: 6)
            p.panelBg.setFill()
            fPath.fill()
            p.accentBlue.setStroke()
            fPath.lineWidth = 1.5
            fPath.stroke()

            drawText(
                state.renameTypedText + "|",
                atTopLeft: NSPoint(x: rX + 28, y: rY + 54),
                canvasH: hF,
                font: NSFont.systemFont(ofSize: 13, weight: .medium),
                color: p.textPrimary
            )

            // Apply pill
            let btnRect = topRect(rX + rW - 118, rY + 90, 100, 26, in: hF)
            let btnPath = NSBezierPath(roundedRect: btnRect, xRadius: 6, yRadius: 6)
            p.accentBlue.setFill()
            btnPath.fill()
            drawText(
                "Rename",
                atTopLeft: NSPoint(x: rX + rW - 92, y: rY + 95),
                canvasH: hF,
                font: NSFont.systemFont(ofSize: 12, weight: .semibold),
                color: .white
            )
        }

        // Animated macOS Pointer Cursor
        if state.showCursor {
            let cx = state.cursorPos.x
            let cy = state.cursorPos.y
            if state.cursorClicking {
                let ring = topRect(cx - 10, cy - 10, 24, 24, in: hF)
                p.accentBlue.withAlphaComponent(0.35).setFill()
                NSBezierPath(ovalIn: ring).fill()
            }
            let pointer = NSBezierPath()
            let base = NSPoint(x: cx, y: hF - cy)
            pointer.move(to: base)
            pointer.line(to: NSPoint(x: base.x, y: base.y - 16))
            pointer.line(to: NSPoint(x: base.x + 4.5, y: base.y - 12))
            pointer.line(to: NSPoint(x: base.x + 8, y: base.y - 19))
            pointer.line(to: NSPoint(x: base.x + 10.5, y: base.y - 18))
            pointer.line(to: NSPoint(x: base.x + 7, y: base.y - 11))
            pointer.line(to: NSPoint(x: base.x + 12.5, y: base.y - 11))
            pointer.close()

            NSColor.black.withAlphaComponent(0.75).setStroke()
            pointer.lineWidth = 2.2
            pointer.stroke()
            NSColor.white.setFill()
            pointer.fill()
        }
    }
}

func generateFinderGIFs() throws {
    for mode in ThemeMode.allCases {
        var frames: [(image: CGImage, delay: Double)] = []

        // Scene 1: Direct Finder Sidebar Mount (no localhost wrapper)
        let s1Frames: [(cursor: NSPoint, click: Bool, selected: String?, delay: Double)] = [
            (NSPoint(x: 168, y: 248), false, nil, 0.55),
            (NSPoint(x: 152, y: 245), true, nil, 0.45),
            (NSPoint(x: 340, y: 230), false, nil, 0.35),
            (NSPoint(x: 365, y: 222), true, "Financials-2026.pdf", 0.50),
        ]
        for f in s1Frames {
            let state = FinderDemoState(
                topTag: "01 / DIRECT FINDER FAVOURITES",
                topDetail: "NO LOCALHOST WRAPPER · 5.37 TB QUOTA",
                driveName: "Open Drive",
                activeSidebarItem: "Open Drive",
                selectedFile: f.selected,
                terminalProgress: 0,
                terminalLine2: 0,
                showGetInfo: 0,
                showRenamePopover: false,
                renameTypedText: "",
                showCursor: true,
                cursorPos: f.cursor,
                cursorClicking: f.click
            )
            frames.append((drawFinderScene(state: state, mode: mode), f.delay))
        }

        // Scene 2: Get Info (Zero bytes on disk) + Terminal POSIX (chmod +x, ln -s)
        let s2Steps: [(info: CGFloat, term: CGFloat, term2: CGFloat, delay: Double)] = [
            (0.65, 0.0, 0.0, 0.16),
            (1.0, 0.0, 0.0, 1.35),
            (1.0, 0.70, 0.0, 0.18),
            (1.0, 1.0, 0.4, 0.45),
            (1.0, 1.0, 1.0, 1.85),
        ]
        for s in s2Steps {
            let state = FinderDemoState(
                topTag: "02 / ZERO BYTES ON DISK + POSIX TERMINAL",
                topDetail: "STATFS QUOTA · SYMLINKS & X-BIT",
                driveName: "Open Drive",
                activeSidebarItem: "Open Drive",
                selectedFile: s.term > 0 ? "deploy-preview.sh" : "Financials-2026.pdf",
                terminalProgress: s.term,
                terminalLine2: s.term2,
                showGetInfo: s.info,
                showRenamePopover: false,
                renameTypedText: "",
                showCursor: false,
                cursorPos: .zero,
                cursorClicking: false
            )
            frames.append((drawFinderScene(state: state, mode: mode), s.delay))
        }

        // Scene 3: Live Drive Rename -> Work Cloud
        let typedSteps = ["Open Drive", "Work", "Work Clo", "Work Cloud"]
        for (idx, txt) in typedSteps.enumerated() {
            let state = FinderDemoState(
                topTag: "03 / LIVE DRIVE RENAME",
                topDetail: "RENAMES MOUNT PATH & FINDER FAVOURITE",
                driveName: "Open Drive",
                activeSidebarItem: "Open Drive",
                selectedFile: nil,
                terminalProgress: 0,
                terminalLine2: 0,
                showGetInfo: 0,
                showRenamePopover: true,
                renameTypedText: txt,
                showCursor: idx == typedSteps.count - 1,
                cursorPos: NSPoint(x: 618, y: 278),
                cursorClicking: idx == typedSteps.count - 1
            )
            frames.append((drawFinderScene(state: state, mode: mode), idx == typedSteps.count - 1 ? 0.55 : 0.30))
        }

        // Final renamed state hold
        let renamedState = FinderDemoState(
            topTag: "03 / LIVE DRIVE RENAME · APPLIED",
            topDetail: "~/Library/OpenDrive/Work Cloud",
            driveName: "Work Cloud",
            activeSidebarItem: "Work Cloud",
            selectedFile: "Personal Drive",
            terminalProgress: 0,
            terminalLine2: 0,
            showGetInfo: 0,
            showRenamePopover: false,
            renameTypedText: "",
            showCursor: false,
            cursorPos: .zero,
            cursorClicking: false
        )
        frames.append((drawFinderScene(state: renamedState, mode: mode), 2.10))

        try saveGIF(frames: frames, to: outputDir.appendingPathComponent("finder-demo-\(mode.rawValue).gif"))
    }
}

// MARK: - 3. Real App Tour GIF (960x600)

func generateAppTourGIFs() throws {
    let W = 960
    let H = 600
    let wF = CGFloat(W)
    let hF = CGFloat(H)

    for mode in ThemeMode.allCases {
        let p = CanvasPalette.forMode(mode)
        let m = mode.rawValue

        let tourStops: [(tag: String, detail: String, file: String, isOverlayPalette: Bool)] = [
            ("01 / OVERVIEW", "VIRTUAL DISK MOUNT · 1.74 TB AVAILABLE", "overview-\(m).png", false),
            ("02 / UPLOADS", "HOTSPOT AUTO-PAUSE · 4 MiB RESUMABLE PUT", "uploads-\(m).png", false),
            ("03 / OFFLINE CACHE", "PINNED LOCAL FILES · INSTANT OPEN", "offline-\(m).png", false),
            ("04 / GLOBAL SEARCH ⌃⌥F", "SQLITE TREE INDEX · SUB-10ms", "palette-\(m).png", true),
            ("05 / ACCOUNTS & VAULT", "MULTI-ACCOUNT PKCE · ODE1 ENCRYPTION", "settings-accounts-\(m).png", false),
        ]

        let overviewImg = loadShot("overview-\(m).png")
        var frames: [(image: CGImage, delay: Double)] = []

        func renderTourSlide(index: Int) -> CGImage {
            let stop = tourStops[index]
            let shot = loadShot(stop.file)
            return renderBitmap(width: W, height: H) { size in
                drawBackdrop(size: size, palette: p)
                drawTopTag(stop.tag, rightDetail: stop.detail, in: size, palette: p, topOffset: 16)

                if stop.isOverlayPalette {
                    let bgBox = topRect(110, 56, wF - 220, hF - 82, in: hF)
                    let bgFrame = fittedFrame(for: overviewImg, inside: bgBox)
                    drawFramedWindow(
                        image: overviewImg,
                        in: bgFrame,
                        cornerRadius: 13,
                        palette: p,
                        opacity: mode.isDark ? 0.35 : 0.45,
                        shadowBlur: 18,
                        shadowYOffset: -8
                    )
                    let pW: CGFloat = 540
                    let pH = round(pW * (shot.size.height / shot.size.width))
                    let pRect = topRect(round((wF - pW) / 2), round((hF - pH) / 2) + 10, pW, pH, in: hF)
                    drawFramedWindow(image: shot, in: pRect, cornerRadius: 14, palette: p, shadowBlur: 34, shadowYOffset: -14)
                } else {
                    let box = topRect(70, 56, wF - 140, hF - 84, in: hF)
                    let frame = fittedFrame(for: shot, inside: box)
                    drawFramedWindow(image: shot, in: frame, cornerRadius: 13, palette: p, shadowBlur: 28, shadowYOffset: -12)
                }

                // Step indicator dots at bottom-center
                let dotW: CGFloat = 18
                let gap: CGFloat = 8
                let totalW = CGFloat(tourStops.count) * dotW + CGFloat(tourStops.count - 1) * gap
                let startX = round((wF - totalW) / 2)
                for idx in 0..<tourStops.count {
                    let barRect = topRect(startX + CGFloat(idx) * (dotW + gap), hF - 18, dotW, 3, in: hF)
                    let col = (idx == index) ? p.textPrimary : p.textMuted.withAlphaComponent(0.35)
                    col.setFill()
                    barRect.fill()
                }
            }
        }

        for idx in 0..<tourStops.count {
            frames.append((renderTourSlide(index: idx), 2.15))
        }

        try saveGIF(frames: frames, to: outputDir.appendingPathComponent("app-tour-\(mode.rawValue).gif"))
    }
}

do {
    try generateStaticScreenshots()
    try generateFinderGIFs()
    try generateAppTourGIFs()
    print("WEB_MEDIA_DONE \(outputDir.path)")
} catch {
    fputs("Error generating web media: \(error)\n", stderr)
    exit(1)
}
