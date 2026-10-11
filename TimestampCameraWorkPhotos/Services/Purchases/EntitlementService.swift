import Foundation
import Observation
import StoreKit

/// Product identifiers of the single "Pro" level, in one subscription group.
/// Project identifiers — confirm the prefix before creating them in App Store Connect.
enum ProductCatalog {
    static let monthly = "workphotos.pro.monthly"
    static let yearly = "workphotos.pro.yearly"
    static let all = [monthly, yearly]
}

enum PurchaseOutcome: Equatable {
    case success
    /// Ask to Buy / SCA: no Pro until a verified transaction arrives.
    case pending
    case cancelled
    case unverified
    case failed(AppError)
}

enum RestoreOutcome: Equatable {
    case restored
    case nothingFound
    case failed(AppError)
}

/// StoreKit 2 is the only source of entitlement (PAY-04). No UserDefaults flags, no device-clock
/// renewal logic. Access follows `Transaction.currentEntitlements`, which works offline with the
/// locally verified transactions; no network does not mean "no purchases".
@MainActor
@Observable
final class EntitlementService {
    enum ProductsState: Equatable {
        case idle
        case loading
        case loaded
        case failed(AppErrorCode)
    }

    enum DisplayState: Equatable {
        case unknown
        case notSubscribed
        case active(renewsOn: Date?)
        /// Introductory free trial; renews into the paid period unless cancelled.
        case trial(endsOn: Date?)
        case cancelledAutoRenew(accessUntil: Date?)
        case inGracePeriod(until: Date?)
        case billingRetry
        case expired
        case revoked
        case pending
        case verificationFailed
    }

    private(set) var products: [Product] = []
    private(set) var productsState: ProductsState = .idle
    /// Verified Pro access (subscribed or in billing grace period).
    private(set) var isPro = false
    /// False until the first entitlement check finished.
    private(set) var isDetermined = false
    private(set) var displayState: DisplayState = .unknown
    private(set) var activeProductID: String?
    /// Product the subscription will renew to, when the user scheduled a change in Apple's settings.
    private(set) var nextRenewalProductID: String?
    private(set) var isPurchasing = false
    private(set) var pendingProductID: String?
    /// Free-trial introductory offers the user is eligible for, by product ID (from StoreKit;
    /// eligibility ends after any subscription in the group was used).
    private(set) var trialOffers: [String: Product.SubscriptionOffer] = [:]

    #if DEBUG
    /// Marketing captures only (`-uitest-pro-preview`): shows the app as a subscriber sees it.
    /// Compiled out of Release, so production never has a fake entitlement.
    var debugProPreview = false
    #endif

    private var updatesTask: Task<Void, Never>?
    private var determinedWaiters: [CheckedContinuation<Void, Never>] = []

    init() {}

    /// Starts the transaction listener for the whole app lifetime and checks entitlements.
    func start() {
        guard updatesTask == nil else { return }
        updatesTask = Task { [weak self] in
            for await update in Transaction.updates {
                await self?.handle(update)
            }
        }
        Task { await refreshEntitlements() }
    }

    func waitUntilDetermined() async {
        if isDetermined { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            determinedWaiters.append(continuation)
        }
    }

    var monthly: Product? { products.first { $0.id == ProductCatalog.monthly } }
    var yearly: Product? { products.first { $0.id == ProductCatalog.yearly } }

    func loadProducts() async {
        if productsState == .loading { return }
        productsState = .loading
        do {
            let loaded = try await Product.products(for: ProductCatalog.all)
            products = loaded.sorted { lhs, rhs in
                (ProductCatalog.all.firstIndex(of: lhs.id) ?? 0) < (ProductCatalog.all.firstIndex(of: rhs.id) ?? 0)
            }
            await refreshTrialEligibility()
            productsState = products.isEmpty ? .failed(.productsUnavailable) : .loaded
        } catch {
            productsState = .failed(.productsUnavailable)
        }
    }

    func trialOffer(for productID: String) -> Product.SubscriptionOffer? {
        trialOffers[productID]
    }

    private func refreshTrialEligibility() async {
        var offers: [String: Product.SubscriptionOffer] = [:]
        for product in products {
            guard let subscription = product.subscription, let offer = subscription.introductoryOffer,
                  offer.paymentMode == .freeTrial, await subscription.isEligibleForIntroOffer else { continue }
            offers[product.id] = offer
        }
        trialOffers = offers
    }

    /// Savings of yearly vs 12 × monthly, only when both prices are in the same currency.
    var yearlySavingsPercent: Int? {
        guard let monthly, let yearly,
              monthly.priceFormatStyle.currencyCode == yearly.priceFormatStyle.currencyCode else { return nil }
        return PriceMath.yearlySavingsPercent(monthly: monthly.price, yearly: yearly.price)
    }

    // MARK: Entitlements

    func refreshEntitlements() async {
        var active: Transaction?
        var sawUnverified = false
        for await result in Transaction.currentEntitlements {
            switch result {
            case .verified(let transaction):
                guard ProductCatalog.all.contains(transaction.productID), transaction.revocationDate == nil else { continue }
                if active == nil || (transaction.expirationDate ?? .distantPast) > (active?.expirationDate ?? .distantPast) {
                    active = transaction
                }
            case .unverified(let transaction, _):
                if ProductCatalog.all.contains(transaction.productID) { sawUnverified = true }
            }
        }
        var verified = active != nil
        #if DEBUG
        if debugProPreview { verified = true }
        #endif
        isPro = verified
        activeProductID = active?.productID
        if isPro { pendingProductID = nil }
        await refreshDisplayState(activeTransaction: active, sawUnverified: sawUnverified)
        #if DEBUG
        if debugProPreview { displayState = .active(renewsOn: Calendar.current.date(byAdding: .year, value: 1, to: Date())) }
        #endif
        if !isDetermined {
            isDetermined = true
            let waiters = determinedWaiters
            determinedWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
    }

    private func refreshDisplayState(activeTransaction: Transaction?, sawUnverified: Bool) async {
        nextRenewalProductID = nil
        // Detailed renewal state (may need the network); entitlement above never depends on it.
        var product = products.first
        if product == nil { product = (try? await Product.products(for: [ProductCatalog.monthly]))?.first }
        if let product, let statuses = try? await product.subscription?.status, !statuses.isEmpty {
            let relevant = statuses.compactMap { status -> (Product.SubscriptionInfo.Status, Transaction, Product.SubscriptionInfo.RenewalInfo?)? in
                guard case .verified(let transaction) = status.transaction, ProductCatalog.all.contains(transaction.productID) else { return nil }
                var renewal: Product.SubscriptionInfo.RenewalInfo?
                if case .verified(let info) = status.renewalInfo { renewal = info }
                return (status, transaction, renewal)
            }
            if let best = relevant.max(by: { rank($0.0.state) < rank($1.0.state) }) {
                let expiration = best.1.expirationDate
                switch best.0.state {
                case .subscribed:
                    if best.2?.willAutoRenew == false {
                        displayState = .cancelledAutoRenew(accessUntil: expiration)
                    } else if best.1.offerType == .introductory {
                        displayState = .trial(endsOn: expiration)
                    } else {
                        displayState = .active(renewsOn: expiration)
                    }
                    if let next = best.2?.autoRenewPreference, next != best.1.productID { nextRenewalProductID = next }
                case .inGracePeriod:
                    displayState = .inGracePeriod(until: best.2?.gracePeriodExpirationDate ?? expiration)
                case .inBillingRetryPeriod:
                    displayState = .billingRetry
                case .revoked:
                    displayState = .revoked
                case .expired:
                    displayState = .expired
                default:
                    displayState = isPro ? .active(renewsOn: expiration) : .notSubscribed
                }
                if !isPro, pendingProductID != nil { displayState = .pending }
                return
            }
        }
        if isPro {
            displayState = .active(renewsOn: activeTransaction?.expirationDate)
        } else if pendingProductID != nil {
            displayState = .pending
        } else if sawUnverified {
            displayState = .verificationFailed
        } else {
            displayState = .notSubscribed
        }
    }

    private func rank(_ state: Product.SubscriptionInfo.RenewalState) -> Int {
        switch state {
        case .subscribed: return 5
        case .inGracePeriod: return 4
        case .inBillingRetryPeriod: return 3
        case .expired: return 2
        case .revoked: return 1
        default: return 0
        }
    }

    private func handle(_ result: VerificationResult<Transaction>) async {
        switch result {
        case .verified(let transaction):
            await transaction.finish()
        case .unverified:
            break
        }
        await refreshEntitlements()
        await refreshTrialEligibility()
    }

    // MARK: Purchase / restore

    /// One purchase at a time; repeated taps do not start a second purchase.
    func purchase(_ product: Product) async -> PurchaseOutcome {
        guard !isPurchasing else { return .failed(AppError(.operationBusy)) }
        isPurchasing = true
        defer { isPurchasing = false }
        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                switch verification {
                case .verified(let transaction):
                    await transaction.finish()
                    pendingProductID = nil
                    await refreshEntitlements()
                    await refreshTrialEligibility()
                    return .success
                case .unverified:
                    await refreshEntitlements()
                    return .unverified
                }
            case .pending:
                pendingProductID = product.id
                displayState = .pending
                return .pending
            case .userCancelled:
                return .cancelled
            @unknown default:
                return .failed(AppError(.purchaseFailed))
            }
        } catch {
            return .failed(AppError(.purchaseFailed))
        }
    }

    /// Explicit user action only (never on launch).
    func restore() async -> RestoreOutcome {
        do {
            try await AppStore.sync()
        } catch {
            if let storeError = error as? StoreKitError, case .userCancelled = storeError {
                await refreshEntitlements()
                return isPro ? .restored : .nothingFound
            }
            return .failed(AppError(.restoreFailed))
        }
        await refreshEntitlements()
        await refreshTrialEligibility()
        return isPro ? .restored : .nothingFound
    }
}
