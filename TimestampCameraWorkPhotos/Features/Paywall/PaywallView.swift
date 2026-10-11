import StoreKit
import SwiftUI

/// S14 Pro. Shown only after an explicit attempt to use a Pro feature (or from Settings).
/// Prices, currency, periods and the free trial always come from StoreKit. Yearly is preselected
/// (owner decision); both plans and their prices stay visible and the price is the most prominent
/// figure. Closing returns to the previous screen without losing input.
struct PaywallView: View {
    let trigger: PaywallTrigger
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @State private var selectedID = ProductCatalog.yearly
    @State private var message: StatusMessage?
    @State private var isRestoring = false

    struct StatusMessage: Equatable {
        enum Kind { case info, error, success }
        let text: String
        let kind: Kind
        var offersSupport = false
    }

    var body: some View {
        let store = env.entitlements
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    PaywallHero()
                        .overlay(alignment: .topTrailing) { closeButton }
                    VStack(alignment: .leading, spacing: 22) {
                        header
                        if store.isPro {
                            InfoBanner(icon: "checkmark.seal.fill", title: L("paywall.alreadyPro"), message: L("paywall.alreadyPro.message"),
                                       tint: Theme.success)
                        } else {
                            usageCard
                        }
                        benefits
                        plans(store)
                        if let message { statusView(message) }
                        finePrint(store)
                        links(store)
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 20)
                    .padding(.bottom, 28)
                }
            }
            .background(Theme.groupedBackground)
            .toolbar(.hidden, for: .navigationBar)
            .safeAreaInset(edge: .bottom) { purchaseBar(store) }
        }
        .task {
            env.analytics.track(.paywallViewed(trigger: trigger))
            if store.products.isEmpty { await store.loadProducts() }
        }
    }

    private var closeButton: some View {
        Button { dismiss() } label: {
            Image(systemName: "xmark")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(Circle().fill(.black.opacity(0.25)))
                .frame(width: Theme.minTapSize, height: Theme.minTapSize)
        }
        .accessibilityLabel(L("common.close"))
        .accessibilityIdentifier("paywall.close")
        .padding(8)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L(trigger.titleKey))
                .font(.title2.weight(.bold))
                .accessibilityAddTraits(.isHeader)
            Text(L(trigger.messageKey)).font(.body).foregroundStyle(Color.secondary)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var usageCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("paywall.usage.title")).font(.subheadline.weight(.semibold))
            FreeUsageMeters(policy: env.policy())
            Text(L("free.quota.note")).font(.footnote).foregroundStyle(Color.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Theme.cardBackground))
    }

    private var benefits: some View {
        VStack(alignment: .leading, spacing: 14) {
            benefit("folder.badge.plus", L("paywall.benefit.projects", AccessPolicy.proPhotoLimit))
            benefit("rectangle.split.2x1", L("paywall.benefit.beforeAfter"))
            benefit("building.2", L("paywall.benefit.branding"))
            benefit("square.stack.3d.up", L("paywall.benefit.batch"))
            benefit("star.square", L("paywall.benefit.presets", AccessPolicy.brandPresetLimit))
            benefit("lock.open", L("paywall.benefit.dataStaysFree"), tint: .secondary)
        }
    }

    private func benefit(_ icon: String, _ text: String, tint: Color = .accentColor) -> some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 34, height: 34)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(tint.opacity(0.12)))
                .accessibilityHidden(true)
            Text(text).font(.subheadline).fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func plans(_ store: EntitlementService) -> some View {
        switch store.productsState {
        case .idle, .loading:
            HStack(spacing: 10) {
                ProgressView()
                Text(L("paywall.loading")).foregroundStyle(Color.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 120)
        case .failed:
            VStack(spacing: 10) {
                Text(L("paywall.unavailable")).font(.subheadline).multilineTextAlignment(.center)
                Button(L("common.retry")) { Task { await store.loadProducts() } }.buttonStyle(.bordered)
            }
            .frame(maxWidth: .infinity)
        case .loaded:
            VStack(spacing: 14) {
                // Yearly first: it is the preselected plan.
                ForEach(store.products.sorted { $0.id == ProductCatalog.yearly && $1.id != ProductCatalog.yearly }, id: \.id) { product in
                    PlanCard(product: product, isSelected: selectedID == product.id,
                             savings: product.id == ProductCatalog.yearly ? store.yearlySavingsPercent : nil,
                             trial: store.trialOffer(for: product.id)) {
                        selectedID = product.id
                    }
                }
            }
            .padding(.top, 6)
            .sensoryFeedback(.selection, trigger: selectedID)
        }
    }

    private func purchaseBar(_ store: EntitlementService) -> some View {
        let product = store.products.first { $0.id == selectedID }
        let trial = product.flatMap { store.trialOffer(for: $0.id) }
        let title: String
        if let trial {
            title = L("paywall.trial.cta", TrialText.duration(trial))
        } else {
            title = selectedID == ProductCatalog.yearly ? L("paywall.continueYearly") : L("paywall.continueMonthly")
        }
        return VStack(spacing: 8) {
            Button {
                guard let product else { return }
                Task { await purchase(product) }
            } label: {
                HStack(spacing: 8) {
                    if store.isPurchasing { ProgressView().tint(.white) }
                    Text(title).font(.headline).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, minHeight: 54)
                .padding(.horizontal, 12)
            }
            .buttonStyle(PressableProminentButtonStyle())
            .disabled(product == nil || store.isPurchasing || store.isPro)
            .opacity(product == nil || store.isPro ? 0.5 : 1)
            .accessibilityIdentifier("paywall.purchase")
            if let product {
                let price = L("paywall.plan.price", product.displayPrice, PlanCard.periodText(product))
                Text(trial != nil ? L("paywall.trial.then", price) : price + " · " + L("paywall.cancelAnytime"))
                    .font(.footnote)
                    .foregroundStyle(Color.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .background(.bar)
    }

    @ViewBuilder
    private func finePrint(_ store: EntitlementService) -> some View {
        if let product = store.products.first(where: { $0.id == selectedID }) {
            Group {
                if let trial = store.trialOffer(for: product.id) {
                    Text(L("paywall.finePrint.trial", TrialText.duration(trial), product.displayPrice, PlanCard.periodText(product)))
                } else {
                    Text(L("paywall.finePrint", product.displayPrice, PlanCard.periodText(product)))
                }
            }
            .font(.footnote)
            .foregroundStyle(Color.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func links(_ store: EntitlementService) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                Task { await restore() }
            } label: {
                HStack {
                    if isRestoring { ProgressView() }
                    Text(L("paywall.restore"))
                }
            }
            .disabled(isRestoring || store.isPurchasing)
            HStack(spacing: 16) {
                if let terms = env.config.termsURL {
                    Button(L("paywall.terms")) { ExternalLink.open(terms) }
                }
                if let privacy = env.config.privacyPolicyURL {
                    Button(L("paywall.privacy")) { ExternalLink.open(privacy) }
                }
            }
            if env.config.termsURL == nil || env.config.privacyPolicyURL == nil {
                Text(L("config.documentsMissing")).font(.caption).foregroundStyle(Color.secondary)
            }
            NavigationLink(L("support.title")) { SupportView(presetCategory: .purchase) }
        }
        .font(.subheadline)
    }

    private func statusView(_ message: StatusMessage) -> some View {
        Label {
            Text(message.text).font(.subheadline)
        } icon: {
            Image(systemName: message.kind == .error ? "exclamationmark.triangle.fill" : (message.kind == .success ? "checkmark.circle.fill" : "hourglass"))
                .foregroundStyle(message.kind == .error ? Theme.destructive : (message.kind == .success ? Theme.success : Theme.warning))
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.cardBackground))
    }

    private func purchase(_ product: Product) async {
        message = nil
        let outcome = await env.entitlements.purchase(product)
        switch outcome {
        case .success:
            env.analytics.track(.purchaseResult(result: "success", errorCode: nil))
            Haptics.success()
            // Back to the original action; the action itself still needs the user's confirmation.
            dismiss()
        case .pending:
            env.analytics.track(.purchaseResult(result: "pending", errorCode: nil))
            message = StatusMessage(text: L("paywall.pending"), kind: .info)
        case .cancelled:
            // Quietly back to the plans, no payment error.
            env.analytics.track(.purchaseResult(result: "cancelled", errorCode: nil))
        case .unverified:
            env.analytics.track(.purchaseResult(result: "unverified", errorCode: .purchaseUnverified))
            message = StatusMessage(text: AppError(.purchaseUnverified).displayMessage, kind: .error, offersSupport: true)
        case .failed(let error):
            env.analytics.track(.purchaseResult(result: "failed", errorCode: error.code))
            ErrorLog.shared.record(error.code)
            message = StatusMessage(text: error.displayMessage, kind: .error, offersSupport: true)
        }
    }

    private func restore() async {
        isRestoring = true
        defer { isRestoring = false }
        let outcome = await env.entitlements.restore()
        switch outcome {
        case .restored:
            env.analytics.track(.restoreResult(found: true, errorCode: nil))
            message = StatusMessage(text: L("paywall.restored"), kind: .success)
        case .nothingFound:
            env.analytics.track(.restoreResult(found: false, errorCode: nil))
            message = StatusMessage(text: L("paywall.restore.none"), kind: .info)
        case .failed(let error):
            env.analytics.track(.restoreResult(found: false, errorCode: error.code))
            message = StatusMessage(text: error.displayMessage, kind: .error, offersSupport: true)
        }
    }
}

/// Header art: drawn before/after samples on the app's blue, settling in when the paywall opens.
private struct PaywallHero: View {
    @State private var settled = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color.accentColor, Color(red: 0.06, green: 0.17, blue: 0.42)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            Circle().fill(.white.opacity(0.10)).frame(width: 220).blur(radius: 40).offset(x: -120, y: -70)
            Circle().fill(.white.opacity(0.07)).frame(width: 180).blur(radius: 30).offset(x: 140, y: 80)
            HStack(spacing: -26) {
                photo(clean: false, label: L("report.before.sample"), angle: -8)
                    .offset(x: settled || reduceMotion ? 0 : -40, y: settled || reduceMotion ? 6 : 16)
                photo(clean: true, label: L("report.after.sample"), angle: 6)
                    .offset(x: settled || reduceMotion ? 0 : 40, y: settled || reduceMotion ? -6 : -16)
                    .zIndex(1)
            }
            .opacity(settled || reduceMotion ? 1 : 0)
            Text(L("paywall.title"))
                .font(.system(size: 13, weight: .heavy))
                .tracking(1.2)
                .foregroundStyle(Color.accentColor)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(Capsule().fill(.white))
                .shadow(color: .black.opacity(0.2), radius: 6, y: 3)
                .offset(y: 86)
                .scaleEffect(settled || reduceMotion ? 1 : 0.8)
                .opacity(settled || reduceMotion ? 1 : 0)
        }
        .frame(height: 240)
        .clipped()
        .dynamicTypeSize(.large)
        .accessibilityHidden(true)
        .onAppear {
            withAnimation(.spring(duration: 0.8, bounce: 0.25).delay(0.1)) { settled = true }
        }
    }

    private func photo(clean: Bool, label: String, angle: Double) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Color.accentColor)
            KitchenScene(clean: clean)
                .frame(width: 132, height: 99)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white))
        .shadow(color: .black.opacity(0.25), radius: 14, y: 8)
        .rotationEffect(.degrees(angle))
        .environment(\.colorScheme, .light)
    }
}

/// Localized length of a free trial ("3 days", "3 дня", "3 Tage"), from the StoreKit offer.
enum TrialText {
    static func duration(_ offer: Product.SubscriptionOffer) -> String {
        let count = offer.period.value * max(offer.periodCount, 1)
        var components = DateComponents()
        let unit: NSCalendar.Unit
        switch offer.period.unit {
        case .day: components.day = count; unit = .day
        case .week: components.weekOfMonth = count; unit = .weekOfMonth
        case .month: components.month = count; unit = .month
        case .year: components.year = count; unit = .year
        @unknown default: components.day = count; unit = .day
        }
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .full
        formatter.allowedUnits = unit
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = AppLanguage.current.formattingLocale
        formatter.calendar = calendar
        return formatter.string(from: components) ?? ""
    }
}

struct PlanCard: View {
    let product: Product
    let isSelected: Bool
    let savings: Int?
    var trial: Product.SubscriptionOffer?
    let action: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var isYearly: Bool { product.id == ProductCatalog.yearly }

    var body: some View {
        Button(action: action) {
            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 12) { radio; name }
                        price(alignment: .leading)
                    }
                } else {
                    HStack(spacing: 12) {
                        radio
                        name
                        Spacer(minLength: 8)
                        price(alignment: .trailing)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.08) : Theme.cardBackground))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(isSelected ? Color.accentColor : Color.secondary.opacity(0.25), lineWidth: isSelected ? 2 : 1))
            .overlay(alignment: .topTrailing) {
                if let savings {
                    Text(L("paywall.savings", savings))
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Color.accentColor))
                        .offset(x: -14, y: -11)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .animation(.easeOut(duration: 0.18), value: isSelected)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }

    private var radio: some View {
        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
            .font(.title2)
            .foregroundStyle(isSelected ? Color.accentColor : Color.secondary.opacity(0.6))
    }

    private var name: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(isYearly ? L("paywall.plan.yearly") : L("paywall.plan.monthly"))
                .font(.headline)
                .foregroundStyle(Color.primary)
            if let trial {
                Text(L("paywall.trial.badge", TrialText.duration(trial)))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.accentColor.opacity(0.14)))
            }
        }
    }

    private func price(alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(product.displayPrice)
                    .font(.title3.weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(Color.primary)
                Text("/ " + Self.periodText(product))
                    .font(.footnote)
                    .foregroundStyle(Color.secondary)
            }
            if isYearly, let perMonth = Self.perMonthText(product) {
                Text(perMonth).font(.footnote).foregroundStyle(Color.secondary)
            }
        }
    }

    /// "≈ $2.50 per month" for a yearly plan, from its StoreKit price.
    static func perMonthText(_ product: Product) -> String? {
        guard let period = product.subscription?.subscriptionPeriod, period.unit == .year, period.value == 1 else { return nil }
        let monthly = product.price / 12
        return L("paywall.plan.perMonth", monthly.formatted(product.priceFormatStyle))
    }

    /// "month" / "year" (or "3 months") from StoreKit's subscription period.
    static func periodText(_ product: Product) -> String {
        guard let period = product.subscription?.subscriptionPeriod else { return "" }
        if period.value == 1 {
            switch period.unit {
            case .day: return L("period.single.day")
            case .week: return L("period.single.week")
            case .month: return L("period.single.month")
            case .year: return L("period.single.year")
            @unknown default: return ""
            }
        }
        switch period.unit {
        case .day: return L("period.days", period.value)
        case .week: return L("period.weeks", period.value)
        case .month: return L("period.months", period.value)
        case .year: return L("period.years", period.value)
        @unknown default: return ""
        }
    }
}
