import SwiftUI

/// S01: two steps with an animated example result. No permission requests and no paywall here.
/// The scenes are drawn samples marked "Sample"; with Reduce Motion they appear without movement.
struct OnboardingView: View {
    let onFinish: () -> Void
    @State private var page = 0
    private let pageCount = 2

    private var isLastPage: Bool { page == pageCount - 1 }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button(L("onboarding.skip"), action: onFinish)
                    .frame(minHeight: Theme.minTapSize)
                    .padding(.horizontal)
                    .opacity(isLastPage ? 0 : 1)
                    .disabled(isLastPage)
                    .animation(.easeOut(duration: 0.2), value: page)
            }
            TabView(selection: $page) {
                OnboardingPage(title: L("onboarding.capture.title"), message: L("onboarding.capture.message")) {
                    CaptureDemo(isActive: page == 0)
                }
                .tag(0)
                OnboardingPage(title: L("onboarding.report.title"), message: L("onboarding.report.message")) {
                    ReportDemo(isActive: page == 1)
                }
                .tag(1)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))

            PageDots(count: pageCount, current: page)
                .padding(.bottom, 18)

            Button {
                if isLastPage { onFinish() } else { withAnimation(.smooth(duration: 0.35)) { page += 1 } }
            } label: {
                ZStack {
                    HStack(spacing: 8) {
                        Text(isLastPage ? L("onboarding.start") : L("onboarding.continue"))
                        if !isLastPage {
                            Image(systemName: "arrow.right").accessibilityHidden(true)
                        }
                    }
                    .id(isLastPage)
                    .transition(.blurReplace)
                }
                .font(.headline)
                .frame(maxWidth: .infinity, minHeight: 54)
                .animation(.smooth(duration: 0.3), value: isLastPage)
            }
            .buttonStyle(PressableProminentButtonStyle())
            .accessibilityIdentifier("onboarding.next")
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
        }
        .background { OnboardingBackground(page: page).ignoresSafeArea() }
        .sensoryFeedback(.selection, trigger: page)
    }
}

/// Filled accent button that scales slightly while pressed.
struct PressableProminentButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.accentColor))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.92 : 1)
            .animation(.easeOut(duration: 0.16), value: configuration.isPressed)
    }
}

private struct OnboardingPage<Illustration: View>: View {
    let title: String
    let message: String
    @ViewBuilder let illustration: () -> Illustration

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(spacing: 18) {
                    Spacer(minLength: 0)
                    illustration()
                        .frame(maxWidth: 360, maxHeight: max(240, proxy.size.height * 0.58))
                        .accessibilityHidden(true)
                    VStack(spacing: 10) {
                        Text(title)
                            .font(.title.weight(.bold))
                            .multilineTextAlignment(.center)
                            .accessibilityAddTraits(.isHeader)
                        Text(message)
                            .font(.body)
                            .foregroundStyle(Color.secondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 360)
                        Text(L("onboarding.sampleNote"))
                            .font(.footnote)
                            .foregroundStyle(.tertiary)
                            .padding(.top, 2)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 12)
                .frame(minHeight: proxy.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }
}

// MARK: - Page chrome

private struct PageDots: View {
    let count: Int
    let current: Int

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<count, id: \.self) { index in
                Capsule()
                    .fill(index == current ? Color.accentColor : Color.secondary.opacity(0.3))
                    .frame(width: index == current ? 24 : 8, height: 8)
            }
        }
        .animation(.spring(duration: 0.35, bounce: 0.25), value: current)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L("onboarding.pageIndicator", current + 1, count))
    }
}

/// Calm background with a soft accent glow that moves with the page.
private struct OnboardingBackground: View {
    let page: Int
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Theme.groupedBackground
            Circle()
                .fill(Color.accentColor.opacity(colorScheme == .dark ? 0.30 : 0.16))
                .frame(width: 360, height: 360)
                .blur(radius: 90)
                .offset(x: page == 0 ? -90 : 90, y: -230)
        }
        .animation(reduceMotion ? nil : .smooth(duration: 0.7), value: page)
    }
}

// MARK: - Animation helpers

/// Appears with opacity (and, without Reduce Motion, a small lift, scale and blur). Hiding is
/// instant when the transaction disables animations (used to reset a scene).
private struct Reveal: ViewModifier {
    let visible: Bool
    var delay: Double = 0
    var x: CGFloat = 0
    var y: CGFloat = 8
    var scale: CGFloat = 1
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        let moved = !visible && !reduceMotion
        content
            .opacity(visible ? 1 : 0)
            .offset(x: moved ? x : 0, y: moved ? y : 0)
            .scaleEffect(moved ? scale : 1)
            .blur(radius: moved ? 4 : 0)
            .animation(reduceMotion ? .easeOut(duration: 0.25) : .spring(duration: 0.55, bounce: 0.2).delay(delay), value: visible)
    }
}

private extension View {
    func reveal(_ visible: Bool, delay: Double = 0, x: CGFloat = 0, y: CGFloat = 8, scale: CGFloat = 1) -> some View {
        modifier(Reveal(visible: visible, delay: delay, x: x, y: y, scale: scale))
    }
}

/// Plays a scene step by step while its page is visible; resets when the page is left so the
/// scene replays on return. With Reduce Motion the final state appears at once.
private struct SceneTimeline: ViewModifier {
    let isActive: Bool
    let delays: [Int]
    @Binding var step: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.task(id: isActive) {
            var reset = Transaction()
            reset.disablesAnimations = true
            withTransaction(reset) { step = 0 }
            guard isActive else { return }
            if reduceMotion {
                step = delays.count
                return
            }
            for (index, delay) in delays.enumerated() {
                guard (try? await Task.sleep(for: .milliseconds(delay))) != nil else { return }
                step = index + 1
            }
        }
    }
}

/// Lays out a scene at a fixed design size and scales it to the space offered, so the drawn
/// composition (and its fixed-size text) stays identical on every iPhone and text size.
private struct DesignCanvas<Content: View>: View {
    let size: CGSize
    @ViewBuilder let content: () -> Content

    var body: some View {
        GeometryReader { proxy in
            let scale = min(proxy.size.width / size.width, proxy.size.height / size.height)
            content()
                .frame(width: size.width, height: size.height)
                .scaleEffect(scale)
                .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .aspectRatio(size.width / size.height, contentMode: .fit)
        .dynamicTypeSize(.large)
    }
}

// MARK: - Step 1: capture

/// A camera viewfinder: focus, shutter, flash, then the stamp writes itself and the shot is saved.
private struct CaptureDemo: View {
    let isActive: Bool
    @State private var step = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let sceneSize = CGSize(width: 340, height: 292)

    var body: some View {
        DesignCanvas(size: CGSize(width: 340, height: 360)) {
            VStack(spacing: 0) {
                viewfinder
                    .frame(width: sceneSize.width, height: sceneSize.height)
                    .clipped()
                controls
            }
            .background(Color(white: 0.06))
            .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 30, style: .continuous).strokeBorder(.white.opacity(0.08)))
            .shadow(color: .black.opacity(0.28), radius: 24, y: 12)
        }
        .modifier(SceneTimeline(isActive: isActive, delays: [350, 750, 110, 700], step: $step))
    }

    private var viewfinder: some View {
        ZStack {
            KitchenScene(clean: true)
                .scaleEffect(step >= 1 || reduceMotion ? 1 : 1.06)
                .animation(.spring(duration: 0.9, bounce: 0.1), value: step >= 1)
            ThirdsGrid().stroke(.white.opacity(0.18), lineWidth: 0.5)

            FocusBrackets()
                .stroke(.white, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .frame(width: 76, height: 76)
                .position(x: sceneSize.width * 0.6, y: sceneSize.height * 0.42)
                .opacity(step == 1 || step == 2 ? 1 : 0)
                .scaleEffect(step >= 1 || reduceMotion ? 1 : 1.35)
                .animation(.spring(duration: 0.4, bounce: 0.3), value: step)

            sparkle(size: 18, x: 0.21, y: 0.22, delay: 0.15)
            sparkle(size: 13, x: 0.83, y: 0.17, delay: 0.25)
            sparkle(size: 15, x: 0.56, y: 0.57, delay: 0.35)

            Color.white
                .opacity(step == 2 && !reduceMotion ? 0.85 : 0)
                .animation(step == 2 ? .easeOut(duration: 0.06) : .easeOut(duration: 0.45), value: step)

            stamp
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .padding(12)

            HStack {
                SampleBadge()
                Spacer()
            }
            .frame(maxHeight: .infinity, alignment: .top)
            .padding(12)

            savedPill
                .frame(maxHeight: .infinity, alignment: .top)
                .padding(.top, 12)
        }
    }

    private func sparkle(size: CGFloat, x: CGFloat, y: CGFloat, delay: Double) -> some View {
        Image(systemName: "sparkle")
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(.white)
            .shadow(color: .white.opacity(0.8), radius: 4)
            .reveal(step >= 3, delay: delay, y: 0, scale: 0.3)
            .position(x: sceneSize.width * x, y: sceneSize.height * y)
    }

    private var stamp: some View {
        let lines = [
            DateTimeFormatting(locale: AppLanguage.current.formattingLocale).dateTimeString(LocalDateTime(iso: "2026-10-08T14:03:00")!, offsetSeconds: 7200),
            L("onboarding.sample.project"),
            L("onboarding.sample.caption")
        ]
        return VStack(alignment: .trailing, spacing: 2) {
            ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                Text(verbatim: line)
                    .font(.system(size: index == 0 ? 11.5 : 10.5, weight: index == 0 ? .semibold : .regular))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .reveal(step >= 3, delay: 0.05 + Double(index) * 0.08, y: 5)
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(.black.opacity(0.6)))
        .frame(maxWidth: 230, alignment: .trailing)
        .reveal(step >= 3, y: 6, scale: 0.96)
    }

    private var savedPill: some View {
        Label(L("camera.saved"), systemImage: "checkmark.circle.fill")
            .font(.system(size: 12, weight: .semibold))
            .symbolRenderingMode(.palette)
            .foregroundStyle(.white, Theme.success)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Capsule().fill(.black.opacity(0.55)))
            .environment(\.colorScheme, .dark)
            .reveal(step >= 4, y: -8, scale: 0.9)
    }

    private var controls: some View {
        HStack {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(.white.opacity(0.35), lineWidth: 1)
                .frame(width: 34, height: 34)
                .overlay {
                    KitchenScene(clean: true)
                        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .reveal(step >= 4, delay: 0.1, y: 0, scale: 0.5)
                }
            Spacer()
            ZStack {
                Circle().strokeBorder(.white, lineWidth: 3).frame(width: 50, height: 50)
                Circle()
                    .fill(.white)
                    .frame(width: 40, height: 40)
                    .scaleEffect(step == 2 && !reduceMotion ? 0.82 : 1)
                    .animation(step == 2 ? .easeOut(duration: 0.08) : .spring(duration: 0.35, bounce: 0.4), value: step)
            }
            Spacer()
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(Circle().fill(.white.opacity(0.14)))
        }
        .padding(.horizontal, 26)
        .frame(height: 68)
    }
}

private struct ThirdsGrid: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        for fraction in [1.0 / 3, 2.0 / 3] {
            path.move(to: CGPoint(x: rect.width * fraction, y: 0))
            path.addLine(to: CGPoint(x: rect.width * fraction, y: rect.height))
            path.move(to: CGPoint(x: 0, y: rect.height * fraction))
            path.addLine(to: CGPoint(x: rect.width, y: rect.height * fraction))
        }
        return path
    }
}

private struct FocusBrackets: Shape {
    func path(in rect: CGRect) -> Path {
        let arm = rect.width * 0.24
        var path = Path()
        let corners: [(CGPoint, CGFloat, CGFloat)] = [(CGPoint(x: rect.minX, y: rect.minY), 1, 1), (CGPoint(x: rect.maxX, y: rect.minY), -1, 1),
                                                      (CGPoint(x: rect.minX, y: rect.maxY), 1, -1), (CGPoint(x: rect.maxX, y: rect.maxY), -1, -1)]
        for (corner, dx, dy) in corners {
            path.move(to: CGPoint(x: corner.x + arm * dx, y: corner.y))
            path.addLine(to: corner)
            path.addLine(to: CGPoint(x: corner.x, y: corner.y + arm * dy))
        }
        return path
    }
}

// MARK: - Step 2: report

/// A before/after page assembles itself, a second page fans out and the share bar slides up.
private struct ReportDemo: View {
    let isActive: Bool
    @State private var step = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let paper = CGSize(width: 226, height: 292)

    var body: some View {
        DesignCanvas(size: CGSize(width: 340, height: 360)) {
            ZStack(alignment: .bottom) {
                ZStack {
                    backPage
                        .rotationEffect(.degrees(step >= 3 ? -7 : 0), anchor: .bottom)
                        .offset(x: step >= 3 ? -30 : 0, y: step >= 3 ? 6 : 0)
                        .animation(reduceMotion ? nil : .spring(duration: 0.7, bounce: 0.25), value: step >= 3)
                    frontPage
                        .reveal(step >= 1, y: 14, scale: 0.97)
                }
                .frame(maxHeight: .infinity, alignment: .top)
                .padding(.top, 4)
                shareBar
                    .reveal(step >= 4, y: 18, scale: 0.98)
            }
        }
        .modifier(SceneTimeline(isActive: isActive, delays: [250, 450, 550, 500, 650], step: $step))
    }

    private var backPage: some View {
        VStack(alignment: .leading, spacing: 8) {
            Bar(width: 120, height: 7, opacity: 0.25)
            Bar(width: 160, height: 4, opacity: 0.12)
            RoundedRectangle(cornerRadius: 3).fill(Color.black.opacity(0.06)).frame(height: 96)
            Bar(width: 170, height: 4, opacity: 0.12)
            Bar(width: 120, height: 4, opacity: 0.12)
            Spacer()
        }
        .padding(16)
        .frame(width: paper.width, height: paper.height)
        .background(RoundedRectangle(cornerRadius: 6).fill(.white))
        .shadow(color: .black.opacity(0.16), radius: 10, y: 4)
        .opacity(step >= 3 ? 1 : 0)
        .environment(\.colorScheme, .light)
    }

    private var frontPage: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 7) {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.accentColor)
                    .frame(width: 18, height: 18)
                    .overlay(Image(systemName: "camera.fill").font(.system(size: 8, weight: .semibold)).foregroundStyle(.white))
                VStack(alignment: .leading, spacing: 3) {
                    Text(L("onboarding.sample.project"))
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.black.opacity(0.85))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Bar(width: 84, height: 3.5, opacity: 0.2)
                }
            }
            .reveal(step >= 1, delay: 0.1, y: 4)
            Rectangle().fill(Color.black.opacity(0.08)).frame(height: 0.5)
                .reveal(step >= 1, delay: 0.15, y: 0)
            HStack(alignment: .top, spacing: 8) {
                photoColumn(title: L("report.before.sample"), clean: false)
                    .reveal(step >= 2, x: -18, y: 0, scale: 0.94)
                photoColumn(title: L("report.after.sample"), clean: true)
                    .reveal(step >= 2, delay: 0.09, x: 18, y: 0, scale: 0.94)
            }
            VStack(alignment: .leading, spacing: 6) {
                metaRow("clock", width: 120)
                    .reveal(step >= 3, y: 3)
                metaRow("mappin.and.ellipse", width: 96)
                    .reveal(step >= 3, delay: 0.05, y: 3)
                ForEach(Array([196.0, 180.0, 150.0].enumerated()), id: \.offset) { index, width in
                    Bar(width: width, height: 3.5, opacity: 0.14)
                        .reveal(step >= 3, delay: 0.1 + Double(index) * 0.05, y: 3)
                }
                .padding(.top, 2)
            }
            .padding(.top, 2)
            Spacer(minLength: 0)
            HStack {
                Bar(width: 64, height: 3, opacity: 0.12)
                Spacer()
                Text(verbatim: "1 / 2")
                    .font(.system(size: 7))
                    .foregroundStyle(.black.opacity(0.45))
            }
            .reveal(step >= 3, delay: 0.2, y: 0)
        }
        .padding(15)
        .frame(width: paper.width, height: paper.height)
        .background(RoundedRectangle(cornerRadius: 6).fill(.white))
        .shadow(color: .black.opacity(0.18), radius: 14, y: 6)
        .overlay(alignment: .topTrailing) {
            SampleBadge()
                .rotationEffect(.degrees(6))
                .offset(x: 16, y: -10)
                .shadow(color: .black.opacity(0.15), radius: 3, y: 1)
        }
        .environment(\.colorScheme, .light)
    }

    private func metaRow(_ symbol: String, width: CGFloat) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: 7, weight: .semibold))
                .foregroundStyle(.black.opacity(0.35))
                .frame(width: 9)
            Bar(width: width, height: 3.5, opacity: 0.16)
        }
    }

    private func photoColumn(title: String, clean: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 7, weight: .bold))
                .foregroundStyle(Color.accentColor)
            KitchenScene(clean: clean)
                .aspectRatio(4.0 / 3.0, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 3))
            Bar(width: 70, height: 3, opacity: 0.18)
            Bar(width: 46, height: 3, opacity: 0.12)
        }
    }

    private var shareBar: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.accentColor.opacity(0.15))
                .frame(width: 38, height: 38)
                .overlay(Image(systemName: "doc.richtext.fill").font(.system(size: 17)).foregroundStyle(Color.accentColor))
            VStack(alignment: .leading, spacing: 2) {
                Text(L("report.ready"))
                    .font(.system(size: 13, weight: .semibold))
                Text(L("report.fileInfo", 2, ByteFormatting.string(1_240_000)))
                    .font(.system(size: 11))
                    .foregroundStyle(Color.secondary)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            Spacer(minLength: 4)
            ZStack {
                Circle()
                    .stroke(Color.accentColor, lineWidth: 2)
                    .frame(width: 36, height: 36)
                    .scaleEffect(step >= 5 ? 1.8 : 1)
                    .opacity(step >= 5 || reduceMotion ? 0 : 0.6)
                    .animation(step >= 5 ? .easeOut(duration: 0.9) : nil, value: step)
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 36, height: 36)
                    .overlay(Image(systemName: "square.and.arrow.up").font(.system(size: 14, weight: .semibold)).foregroundStyle(.white))
                    .scaleEffect(step == 5 && !reduceMotion ? 0.92 : 1)
                    .animation(.spring(duration: 0.3, bounce: 0.5), value: step)
            }
        }
        .padding(.horizontal, 12)
        .frame(width: 292, height: 62)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.primary.opacity(0.06)))
        .shadow(color: .black.opacity(0.18), radius: 16, y: 6)
    }
}

private struct Bar: View {
    let width: CGFloat
    let height: CGFloat
    let opacity: Double

    var body: some View {
        RoundedRectangle(cornerRadius: height / 2).fill(Color.black.opacity(opacity)).frame(width: width, height: height)
    }
}

// MARK: - Drawn sample scene

/// A small kitchen drawn with vector shapes: "clean" (after) or "dirty" (before). Not a photo.
struct KitchenScene: View {
    var clean: Bool

    var body: some View {
        Canvas { context, size in
            let w = size.width
            let h = size.height
            func rect(_ x0: CGFloat, _ y0: CGFloat, _ x1: CGFloat, _ y1: CGFloat) -> CGRect {
                CGRect(x: x0 * w, y: y0 * h, width: (x1 - x0) * w, height: (y1 - y0) * h)
            }
            func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * w, y: y * h) }
            func vertical(_ colors: [Color], _ r: CGRect) -> GraphicsContext.Shading {
                .linearGradient(Gradient(colors: colors), startPoint: CGPoint(x: r.midX, y: r.minY), endPoint: CGPoint(x: r.midX, y: r.maxY))
            }

            // Wall
            let full = CGRect(origin: .zero, size: size)
            context.fill(Path(full), with: vertical(clean ? [rgb(0.92, 0.94, 0.97), rgb(0.80, 0.84, 0.90)]
                                                          : [rgb(0.80, 0.76, 0.70), rgb(0.63, 0.59, 0.53)], full))

            // Window with sky, clouds and frame
            let window = rect(0.07, 0.09, 0.37, 0.44)
            let windowPath = Path(roundedRect: window, cornerRadius: w * 0.012)
            context.fill(windowPath, with: vertical(clean ? [rgb(0.55, 0.75, 0.97), rgb(0.84, 0.92, 1.0)]
                                                          : [rgb(0.58, 0.61, 0.64), rgb(0.70, 0.71, 0.72)], window))
            context.drawLayer { layer in
                layer.clip(to: windowPath)
                layer.fill(Path(ellipseIn: rect(0.10, 0.15, 0.24, 0.21)), with: .color(.white.opacity(clean ? 0.75 : 0.35)))
                layer.fill(Path(ellipseIn: rect(0.19, 0.24, 0.34, 0.30)), with: .color(.white.opacity(clean ? 0.6 : 0.3)))
            }
            let frameWidth = max(1, w * 0.012)
            context.stroke(windowPath, with: .color(.white), lineWidth: frameWidth)
            var bars = Path()
            bars.move(to: point(0.22, 0.09)); bars.addLine(to: point(0.22, 0.44))
            bars.move(to: point(0.07, 0.265)); bars.addLine(to: point(0.37, 0.265))
            context.stroke(bars, with: .color(.white), lineWidth: frameWidth * 0.8)

            // Light falling from the window (clean only)
            if clean {
                var beam = Path()
                beam.move(to: point(0.07, 0.44)); beam.addLine(to: point(0.37, 0.44))
                beam.addLine(to: point(0.62, 0.62)); beam.addLine(to: point(0.20, 0.62)); beam.closeSubpath()
                context.fill(beam, with: .linearGradient(Gradient(colors: [.white.opacity(0.30), .white.opacity(0)]),
                                                         startPoint: point(0.2, 0.44), endPoint: point(0.4, 0.62)))
            }

            // Upper cabinets
            let doorColor = clean ? rgb(0.97, 0.97, 0.98) : rgb(0.85, 0.81, 0.75)
            for door in [rect(0.50, 0.07, 0.72, 0.36), rect(0.73, 0.07, 0.95, 0.36)] {
                context.fill(Path(roundedRect: door, cornerRadius: w * 0.008), with: .color(doorColor))
            }
            context.fill(Path(rect(0.50, 0.36, 0.95, 0.375)), with: .color(.black.opacity(0.07)))
            for handle in [rect(0.695, 0.27, 0.705, 0.33), rect(0.745, 0.27, 0.755, 0.33)] {
                context.fill(Path(roundedRect: handle, cornerRadius: w * 0.005), with: .color(rgb(0.36, 0.38, 0.42)))
            }

            // Backsplash tiles
            let tiles = rect(0, 0.46, 1, 0.62)
            context.fill(Path(tiles), with: .color(.white.opacity(clean ? 0.16 : 0.04)))
            var grid = Path()
            for row in 0...3 {
                let y = tiles.minY + tiles.height * CGFloat(row) / 3
                grid.move(to: CGPoint(x: 0, y: y)); grid.addLine(to: CGPoint(x: w, y: y))
            }
            for column in 1..<12 {
                let x = w * CGFloat(column) / 12
                grid.move(to: CGPoint(x: x, y: tiles.minY)); grid.addLine(to: CGPoint(x: x, y: tiles.maxY))
            }
            context.stroke(grid, with: .color(.white.opacity(clean ? 0.5 : 0.18)), lineWidth: max(0.5, w * 0.0025))

            // Faucet
            var faucet = Path()
            faucet.move(to: point(0.30, 0.62)); faucet.addLine(to: point(0.30, 0.54))
            faucet.addQuadCurve(to: point(0.37, 0.545), control: point(0.30, 0.48))
            faucet.addLine(to: point(0.37, 0.57))
            context.stroke(faucet, with: .color(clean ? rgb(0.66, 0.70, 0.75) : rgb(0.55, 0.55, 0.54)),
                           style: StrokeStyle(lineWidth: max(1.2, w * 0.016), lineCap: .round, lineJoin: .round))

            // Spray bottle and mug on the counter
            context.fill(Path(roundedRect: rect(0.66, 0.535, 0.71, 0.62), cornerRadius: w * 0.01),
                         with: .color(clean ? rgb(0.96, 0.97, 0.99) : rgb(0.84, 0.81, 0.77)))
            context.fill(Path(rect(0.672, 0.515, 0.698, 0.535)), with: .color(.accentColor))
            context.fill(Path(roundedRect: rect(0.655, 0.503, 0.705, 0.518), cornerRadius: w * 0.004), with: .color(.accentColor))
            context.fill(Path(roundedRect: rect(0.80, 0.575, 0.845, 0.62), cornerRadius: w * 0.008), with: .color(rgb(0.95, 0.95, 0.96)))
            context.stroke(Path(ellipseIn: rect(0.835, 0.585, 0.862, 0.607)), with: .color(rgb(0.95, 0.95, 0.96)),
                           lineWidth: max(0.8, w * 0.006))

            // Counter top and lower cabinets
            let counter = rect(0, 0.62, 1, 0.665)
            context.fill(Path(counter), with: vertical([rgb(0.27, 0.29, 0.33), rgb(0.19, 0.21, 0.25)], counter))
            var highlight = Path()
            highlight.move(to: CGPoint(x: 0, y: counter.minY + 0.5)); highlight.addLine(to: CGPoint(x: w, y: counter.minY + 0.5))
            context.stroke(highlight, with: .color(.white.opacity(clean ? 0.35 : 0.12)), lineWidth: 1)
            context.fill(Path(rect(0, 0.665, 1, 1)), with: .color(clean ? rgb(0.31, 0.34, 0.39) : rgb(0.37, 0.34, 0.30)))
            var seams = Path()
            for x in [0.25, 0.5, 0.75] {
                seams.move(to: point(x, 0.665)); seams.addLine(to: point(x, 1))
            }
            context.stroke(seams, with: .color(.black.opacity(0.28)), lineWidth: max(0.6, w * 0.004))
            for center in [0.125, 0.375, 0.625, 0.875] {
                context.fill(Path(roundedRect: rect(center - 0.045, 0.70, center + 0.045, 0.715), cornerRadius: w * 0.005),
                             with: .color(rgb(0.74, 0.76, 0.80)))
            }

            // Dirt before cleaning
            if !clean {
                context.drawLayer { layer in
                    layer.addFilter(.blur(radius: max(1, w * 0.012)))
                    let stains: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [(0.58, 0.52, 0.06, 0.035), (0.14, 0.56, 0.05, 0.03),
                                                                         (0.46, 0.64, 0.07, 0.012), (0.86, 0.22, 0.04, 0.05),
                                                                         (0.30, 0.80, 0.05, 0.04), (0.22, 0.30, 0.05, 0.04)]
                    for (cx, cy, rx, ry) in stains {
                        layer.fill(Path(ellipseIn: rect(cx - rx, cy - ry, cx + rx, cy + ry)), with: .color(rgb(0.36, 0.27, 0.18).opacity(0.42)))
                    }
                }
            }
        }
    }

    private func rgb(_ red: Double, _ green: Double, _ blue: Double) -> Color {
        Color(red: red, green: green, blue: blue)
    }
}

struct SampleBadge: View {
    var body: some View {
        Text(L("common.sample"))
            .font(.system(size: 11, weight: .bold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.accentColor))
            .foregroundStyle(.white)
    }
}
