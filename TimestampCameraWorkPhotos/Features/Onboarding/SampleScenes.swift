import SwiftUI

/// Drawn sample rooms (vector shapes, not photos) in "before" (dirty) and "after" (clean) states.
/// Used by the onboarding, the paywall and the Debug sample project; always marked as samples there.
struct SampleScene: View {
    enum Kind: CaseIterable {
        case kitchen
        case bathroom
        case livingRoom
        case balcony
    }

    let kind: Kind
    var clean: Bool

    var body: some View {
        switch kind {
        case .kitchen: KitchenScene(clean: clean)
        case .bathroom: Canvas { context, size in Self.drawBathroom(&context, size, clean) }
        case .livingRoom: Canvas { context, size in Self.drawLivingRoom(&context, size, clean) }
        case .balcony: Canvas { context, size in Self.drawBalcony(&context, size, clean) }
        }
    }

    // MARK: Helpers

    private struct Frame {
        let w: CGFloat
        let h: CGFloat
        func rect(_ x0: CGFloat, _ y0: CGFloat, _ x1: CGFloat, _ y1: CGFloat) -> CGRect {
            CGRect(x: x0 * w, y: y0 * h, width: (x1 - x0) * w, height: (y1 - y0) * h)
        }
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * w, y: y * h) }
    }

    private static func rgb(_ red: Double, _ green: Double, _ blue: Double) -> Color {
        Color(red: red, green: green, blue: blue)
    }

    private static func vertical(_ colors: [Color], _ r: CGRect) -> GraphicsContext.Shading {
        .linearGradient(Gradient(colors: colors), startPoint: CGPoint(x: r.midX, y: r.minY), endPoint: CGPoint(x: r.midX, y: r.maxY))
    }

    /// Soft blurred blotches for the "before" state.
    private static func dirt(_ context: inout GraphicsContext, _ f: Frame, _ spots: [(CGFloat, CGFloat, CGFloat, CGFloat)],
                             color: Color = rgb(0.36, 0.27, 0.18), opacity: Double = 0.4) {
        context.drawLayer { layer in
            layer.addFilter(.blur(radius: max(1, f.w * 0.012)))
            for (cx, cy, rx, ry) in spots {
                layer.fill(Path(ellipseIn: f.rect(cx - rx, cy - ry, cx + rx, cy + ry)), with: .color(color.opacity(opacity)))
            }
        }
    }

    // MARK: Bathroom

    private static func drawBathroom(_ context: inout GraphicsContext, _ size: CGSize, _ clean: Bool) {
        let f = Frame(w: size.width, h: size.height)
        let full = CGRect(origin: .zero, size: size)
        // Tiled wall
        context.fill(Path(full), with: vertical(clean ? [rgb(0.90, 0.94, 0.97), rgb(0.80, 0.87, 0.92)]
                                                      : [rgb(0.82, 0.80, 0.72), rgb(0.70, 0.67, 0.58)], full))
        var grout = Path()
        for row in 1..<9 {
            let y = f.h * CGFloat(row) / 9 * 0.78
            grout.move(to: CGPoint(x: 0, y: y)); grout.addLine(to: CGPoint(x: f.w, y: y))
        }
        for column in 1..<12 {
            let x = f.w * CGFloat(column) / 12
            grout.move(to: CGPoint(x: x, y: 0)); grout.addLine(to: CGPoint(x: x, y: f.h * 0.78))
        }
        context.stroke(grout, with: .color(clean ? .white.opacity(0.8) : rgb(0.45, 0.40, 0.32).opacity(0.5)),
                       lineWidth: max(0.6, f.w * 0.003))

        // Mirror with reflection
        let mirror = f.rect(0.33, 0.08, 0.67, 0.42)
        let mirrorPath = Path(roundedRect: mirror, cornerRadius: f.w * 0.02)
        context.fill(mirrorPath, with: vertical(clean ? [rgb(0.78, 0.88, 0.96), rgb(0.62, 0.74, 0.86)]
                                                      : [rgb(0.66, 0.68, 0.66), rgb(0.56, 0.57, 0.54)], mirror))
        context.drawLayer { layer in
            layer.clip(to: mirrorPath)
            var shine = Path()
            shine.move(to: f.point(0.40, 0.08)); shine.addLine(to: f.point(0.48, 0.08))
            shine.addLine(to: f.point(0.38, 0.42)); shine.addLine(to: f.point(0.30, 0.42)); shine.closeSubpath()
            layer.fill(shine, with: .color(.white.opacity(clean ? 0.45 : 0.15)))
        }
        context.stroke(mirrorPath, with: .color(rgb(0.72, 0.75, 0.80)), lineWidth: max(1, f.w * 0.008))

        // Vanity, sink and faucet
        context.fill(Path(roundedRect: f.rect(0.26, 0.58, 0.74, 0.62), cornerRadius: f.w * 0.008),
                     with: .color(clean ? rgb(0.97, 0.97, 0.98) : rgb(0.86, 0.84, 0.78)))
        context.fill(Path(ellipseIn: f.rect(0.40, 0.555, 0.60, 0.60)), with: .color(clean ? rgb(0.88, 0.91, 0.94) : rgb(0.74, 0.71, 0.64)))
        var faucet = Path()
        faucet.move(to: f.point(0.50, 0.555)); faucet.addLine(to: f.point(0.50, 0.50))
        faucet.addQuadCurve(to: f.point(0.545, 0.515), control: f.point(0.50, 0.475))
        context.stroke(faucet, with: .color(rgb(0.66, 0.70, 0.75)),
                       style: StrokeStyle(lineWidth: max(1.2, f.w * 0.014), lineCap: .round))
        let cabinet = f.rect(0.28, 0.62, 0.72, 0.86)
        context.fill(Path(cabinet), with: .color(clean ? rgb(0.31, 0.34, 0.39) : rgb(0.38, 0.35, 0.31)))
        var doors = Path()
        doors.move(to: f.point(0.50, 0.62)); doors.addLine(to: f.point(0.50, 0.86))
        context.stroke(doors, with: .color(.black.opacity(0.3)), lineWidth: max(0.6, f.w * 0.004))
        for x in [0.47, 0.53] {
            context.fill(Path(roundedRect: f.rect(x - 0.004, 0.68, x + 0.004, 0.75), cornerRadius: f.w * 0.004),
                         with: .color(rgb(0.74, 0.76, 0.80)))
        }

        // Towel (the app's blue) and floor
        context.fill(Path(roundedRect: f.rect(0.80, 0.30, 0.90, 0.60), cornerRadius: f.w * 0.01),
                     with: .color(clean ? .accentColor : rgb(0.42, 0.48, 0.58)))
        context.fill(Path(f.rect(0.78, 0.29, 0.92, 0.305)), with: .color(rgb(0.66, 0.70, 0.75)))
        let floor = f.rect(0, 0.86, 1, 1)
        context.fill(Path(floor), with: .color(clean ? rgb(0.72, 0.76, 0.82) : rgb(0.58, 0.55, 0.48)))

        if !clean {
            dirt(&context, f, [(0.45, 0.20, 0.03, 0.03), (0.58, 0.30, 0.025, 0.025), (0.52, 0.14, 0.02, 0.02),
                               (0.47, 0.58, 0.05, 0.012), (0.12, 0.70, 0.06, 0.05), (0.88, 0.80, 0.05, 0.04)])
            dirt(&context, f, [(0.30, 0.93, 0.08, 0.03), (0.66, 0.95, 0.10, 0.03)], color: rgb(0.30, 0.25, 0.18), opacity: 0.5)
        }
    }

    // MARK: Living room

    private static func drawLivingRoom(_ context: inout GraphicsContext, _ size: CGSize, _ clean: Bool) {
        let f = Frame(w: size.width, h: size.height)
        let full = CGRect(origin: .zero, size: size)
        context.fill(Path(full), with: vertical(clean ? [rgb(0.93, 0.93, 0.95), rgb(0.85, 0.86, 0.89)]
                                                      : [rgb(0.80, 0.77, 0.72), rgb(0.68, 0.65, 0.60)], full))
        // Window with curtains
        let window = f.rect(0.62, 0.10, 0.90, 0.56)
        context.fill(Path(roundedRect: window, cornerRadius: f.w * 0.01),
                     with: vertical(clean ? [rgb(0.58, 0.77, 0.97), rgb(0.86, 0.93, 1.0)] : [rgb(0.60, 0.63, 0.66), rgb(0.72, 0.73, 0.74)], window))
        var bars = Path()
        bars.move(to: f.point(0.76, 0.10)); bars.addLine(to: f.point(0.76, 0.56))
        context.stroke(Path(roundedRect: window, cornerRadius: f.w * 0.01), with: .color(.white), lineWidth: max(1, f.w * 0.01))
        context.stroke(bars, with: .color(.white), lineWidth: max(1, f.w * 0.008))
        for (x0, x1) in [(0.585, 0.635), (0.885, 0.935)] {
            context.fill(Path(roundedRect: f.rect(x0, 0.07, x1, 0.62), cornerRadius: f.w * 0.01),
                         with: .color(clean ? rgb(0.86, 0.88, 0.92) : rgb(0.72, 0.69, 0.63)))
        }
        // Floor and rug
        let floor = f.rect(0, 0.72, 1, 1)
        context.fill(Path(floor), with: vertical([rgb(0.62, 0.52, 0.42), rgb(0.52, 0.43, 0.34)], floor))
        context.fill(Path(ellipseIn: f.rect(0.10, 0.80, 0.70, 0.98)), with: .color(clean ? rgb(0.80, 0.84, 0.90) : rgb(0.66, 0.64, 0.58)))
        // Sofa
        context.fill(Path(roundedRect: f.rect(0.10, 0.44, 0.56, 0.64), cornerRadius: f.w * 0.025), with: .color(rgb(0.29, 0.33, 0.40)))
        context.fill(Path(roundedRect: f.rect(0.08, 0.56, 0.58, 0.78), cornerRadius: f.w * 0.025), with: .color(rgb(0.33, 0.37, 0.45)))
        for x in [0.16, 0.30] {
            context.fill(Path(roundedRect: f.rect(x, 0.50, x + 0.11, 0.60), cornerRadius: f.w * 0.02),
                         with: .color(clean ? .accentColor.opacity(0.85) : rgb(0.45, 0.48, 0.55)))
        }
        // Floor lamp
        var lamp = Path()
        lamp.move(to: f.point(0.95, 0.80)); lamp.addLine(to: f.point(0.95, 0.40))
        context.stroke(lamp, with: .color(rgb(0.30, 0.32, 0.36)), lineWidth: max(1, f.w * 0.008))
        var shade = Path()
        shade.move(to: f.point(0.91, 0.40)); shade.addLine(to: f.point(0.99, 0.40))
        shade.addLine(to: f.point(0.975, 0.33)); shade.addLine(to: f.point(0.925, 0.33)); shade.closeSubpath()
        context.fill(shade, with: .color(rgb(0.96, 0.93, 0.84)))

        if !clean {
            // Dust haze, stains and clutter on the floor
            context.fill(Path(full), with: .color(rgb(0.55, 0.50, 0.42).opacity(0.12)))
            dirt(&context, f, [(0.40, 0.88, 0.06, 0.03), (0.22, 0.70, 0.05, 0.03), (0.75, 0.30, 0.04, 0.04)])
            for (x, y, angle) in [(0.68, 0.86, 0.3), (0.80, 0.92, -0.5), (0.58, 0.95, 0.9)] {
                var item = Path(roundedRect: CGRect(x: -f.w * 0.035, y: -f.h * 0.012, width: f.w * 0.07, height: f.h * 0.024),
                                cornerRadius: f.w * 0.005)
                item = item.applying(CGAffineTransform(rotationAngle: angle).concatenating(CGAffineTransform(translationX: x * f.w, y: y * f.h)))
                context.fill(item, with: .color(rgb(0.90, 0.88, 0.82)))
            }
        }
    }

    // MARK: Balcony windows

    private static func drawBalcony(_ context: inout GraphicsContext, _ size: CGSize, _ clean: Bool) {
        let f = Frame(w: size.width, h: size.height)
        let full = CGRect(origin: .zero, size: size)
        context.fill(Path(full), with: .color(rgb(0.90, 0.91, 0.93)))
        let glass = f.rect(0.06, 0.08, 0.94, 0.78)
        // Sky and city
        context.fill(Path(glass), with: vertical(clean ? [rgb(0.45, 0.68, 0.96), rgb(0.82, 0.91, 1.0)]
                                                       : [rgb(0.62, 0.64, 0.66), rgb(0.76, 0.76, 0.75)], glass))
        var city = Path()
        let heights: [CGFloat] = [0.50, 0.42, 0.56, 0.38, 0.47, 0.34, 0.52, 0.44, 0.58, 0.40]
        for (index, top) in heights.enumerated() {
            let x0 = 0.06 + CGFloat(index) * 0.088
            city.addRect(f.rect(x0, top, x0 + 0.08, 0.78))
        }
        context.fill(city, with: .color(clean ? rgb(0.36, 0.45, 0.60).opacity(0.55) : rgb(0.45, 0.46, 0.47).opacity(0.5)))
        if clean {
            context.fill(Path(ellipseIn: f.rect(0.12, 0.14, 0.30, 0.22)), with: .color(.white.opacity(0.7)))
            context.fill(Path(ellipseIn: f.rect(0.60, 0.18, 0.80, 0.25)), with: .color(.white.opacity(0.55)))
        }
        // Frames and sill
        var frames = Path(roundedRect: glass, cornerRadius: f.w * 0.008)
        for x in [0.353, 0.647] {
            frames.move(to: f.point(x, 0.08)); frames.addLine(to: f.point(x, 0.78))
        }
        context.stroke(frames, with: .color(.white), lineWidth: max(1.5, f.w * 0.014))
        for x in [0.33, 0.67] {
            context.fill(Path(roundedRect: f.rect(x - 0.006, 0.38, x + 0.006, 0.48), cornerRadius: f.w * 0.004),
                         with: .color(rgb(0.70, 0.73, 0.78)))
        }
        context.fill(Path(f.rect(0.03, 0.78, 0.97, 0.83)), with: .color(rgb(0.97, 0.97, 0.98)))
        context.fill(Path(f.rect(0.03, 0.83, 0.97, 0.845)), with: .color(.black.opacity(0.08)))
        // Plant on the sill
        context.fill(Path(roundedRect: f.rect(0.80, 0.70, 0.86, 0.78), cornerRadius: f.w * 0.006), with: .color(rgb(0.84, 0.55, 0.40)))
        for (dx, dy) in [(-0.02, -0.05), (0.0, -0.08), (0.02, -0.05)] {
            context.fill(Path(ellipseIn: f.rect(0.83 + dx - 0.018, 0.70 + dy - 0.03, 0.83 + dx + 0.018, 0.70 + dy + 0.03)),
                         with: .color(rgb(0.42, 0.60, 0.46)))
        }
        if clean {
            // Light reflections on the glass
            context.drawLayer { layer in
                layer.clip(to: Path(glass))
                for x in [0.12, 0.42, 0.72] {
                    var shine = Path()
                    shine.move(to: f.point(x, 0.08)); shine.addLine(to: f.point(x + 0.05, 0.08))
                    shine.addLine(to: f.point(x - 0.06, 0.78)); shine.addLine(to: f.point(x - 0.11, 0.78)); shine.closeSubpath()
                    layer.fill(shine, with: .color(.white.opacity(0.16)))
                }
            }
        } else {
            // Streaks and spots
            context.drawLayer { layer in
                layer.clip(to: Path(glass))
                layer.addFilter(.blur(radius: max(1, f.w * 0.006)))
                var streaks = Path()
                for index in 0..<14 {
                    let x = 0.08 + CGFloat(index) * 0.064
                    streaks.move(to: f.point(x, 0.12)); streaks.addQuadCurve(to: f.point(x + 0.03, 0.74), control: f.point(x + 0.05, 0.45))
                }
                layer.stroke(streaks, with: .color(rgb(0.50, 0.46, 0.40).opacity(0.35)), lineWidth: max(1, f.w * 0.01))
            }
            dirt(&context, f, [(0.20, 0.30, 0.03, 0.03), (0.52, 0.22, 0.025, 0.025), (0.78, 0.55, 0.035, 0.03),
                               (0.40, 0.62, 0.03, 0.02)], color: rgb(0.40, 0.36, 0.30), opacity: 0.45)
        }
    }
}
