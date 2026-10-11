import StoreKit
import SwiftUI

/// Top of Settings instead of a subscription screen (owner decision). Free users see what Pro adds and
/// open the paywall; Pro users see their verified StoreKit status. There is no in-app cancel or
/// "manage subscription": subscriptions are managed by Apple in the iPhone's Settings.
struct ProStatusBanner: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let onUpgrade: () -> Void

    var body: some View {
        let store = env.entitlements
        Group {
            if store.isPro {
                proCard(store)
            } else {
                Button(action: onUpgrade) { freeCard(store) }
                    .buttonStyle(BannerPressStyle())
            }
        }
        .accessibilityIdentifier("settings.proBanner")
        .task { if store.products.isEmpty { await store.loadProducts() } }
    }

    // MARK: Free

    private func freeCard(_ store: EntitlementService) -> some View {
        let trial = store.trialOffer(for: ProductCatalog.yearly)
        return HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                ProChip(foreground: .accentColor, background: .white)
                Text(L("paywall.trigger.settings.title"))
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.white)
                Text(freeMessage(store))
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.86))
                HStack(spacing: 6) {
                    Text(trial.map { L("paywall.trial.badge", TrialText.duration($0)) } ?? L("subscription.seePlans"))
                    Image(systemName: "arrow.right").accessibilityHidden(true)
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Capsule().fill(.white.opacity(0.18)))
                .padding(.top, 2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            if !dynamicTypeSize.isAccessibilitySize {
                BannerArt()
                    .frame(width: 104, height: 96)
                    .accessibilityHidden(true)
            }
        }
        .padding(18)
        .background {
            ZStack {
                LinearGradient(colors: [Color.accentColor, Color(red: 0.06, green: 0.17, blue: 0.42)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                Circle().fill(.white.opacity(0.10)).frame(width: 180).blur(radius: 30).offset(x: 130, y: -60)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private func freeMessage(_ store: EntitlementService) -> String {
        switch store.displayState {
        case .pending: return L("paywall.pending")
        case .billingRetry: return L("subscription.detail.billingRetry")
        case .expired: return L("subscription.state.expired") + ". " + L("settings.banner.free.message")
        case .revoked: return L("subscription.state.revoked") + ". " + L("settings.banner.free.message")
        case .verificationFailed: return AppError(.purchaseUnverified).displayMessage
        default: return L("settings.banner.free.message")
        }
    }

    // MARK: Pro

    private func proCard(_ store: EntitlementService) -> some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                Circle().fill(Color.accentColor.opacity(0.22)).frame(width: 52, height: 52)
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(Color(red: 0.45, green: 0.66, blue: 1.0))
            }
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(L("paywall.alreadyPro"))
                        .font(.title3.weight(.bold))
                        .foregroundStyle(.white)
                    ProChip(foreground: .white, background: .accentColor)
                }
                Text(proDetail(store))
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.78))
                if let next = store.nextRenewalProductID {
                    Text(L("subscription.changeScheduled", next == ProductCatalog.yearly ? L("paywall.plan.yearly") : L("paywall.plan.monthly")))
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .background {
            ZStack {
                LinearGradient(colors: [Color(red: 0.12, green: 0.14, blue: 0.19), Color(red: 0.05, green: 0.07, blue: 0.11)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                Circle().fill(Color.accentColor.opacity(0.35)).frame(width: 200).blur(radius: 50).offset(x: 140, y: -70)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private func proDetail(_ store: EntitlementService) -> String {
        func date(_ value: Date?) -> String { value?.appFormatted(date: .long, time: .omitted) ?? "—" }
        switch store.displayState {
        case .active(let renews): return L("subscription.detail.renews", date(renews))
        case .trial(let ends): return L("subscription.detail.trial", date(ends))
        case .cancelledAutoRenew(let until): return L("subscription.detail.until", date(until))
        case .inGracePeriod(let until): return L("subscription.detail.grace", date(until))
        default: return L("paywall.alreadyPro.message")
        }
    }
}

private struct ProChip: View {
    let foreground: Color
    let background: Color

    var body: some View {
        Text(verbatim: "PRO")
            .font(.system(size: 11, weight: .heavy))
            .tracking(1.2)
            .foregroundStyle(foreground)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(background))
            .accessibilityHidden(true)
    }
}

/// Two small before/after cards, like on the paywall.
private struct BannerArt: View {
    var body: some View {
        ZStack {
            card(clean: false).rotationEffect(.degrees(-9)).offset(x: -14, y: 8)
            card(clean: true).rotationEffect(.degrees(7)).offset(x: 14, y: -8)
        }
        .environment(\.colorScheme, .light)
    }

    private func card(clean: Bool) -> some View {
        KitchenScene(clean: clean)
            .frame(width: 66, height: 50)
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            .padding(4)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(.white))
            .shadow(color: .black.opacity(0.25), radius: 8, y: 4)
    }
}

private struct BannerPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.16), value: configuration.isPressed)
    }
}
