import StoreKit
import StoreKitTest
import SwiftUI
import XCTest
@testable import TimestampCameraWorkPhotos

final class LocalizationTests: XCTestCase {
    func testAllLanguagesHaveCompiledStrings() {
        for language in AppLanguage.allCases {
            let strings = LocalizedStrings(language: language)
            XCTAssertNotEqual(strings.t("report.field.taken"), "report.field.taken", "\(language)")
            XCTAssertNotEqual(strings.t("tab.camera"), "tab.camera", "\(language)")
        }
        XCTAssertEqual(LocalizedStrings(language: .de).t("report.before"), "VORHER")
        XCTAssertEqual(LocalizedStrings(language: .fr).t("report.after"), "APRÈS")
        XCTAssertEqual(LocalizedStrings(language: .es).t("provenance.time.device"), "Hora del dispositivo")
    }

    func testRussianPluralsUseCLDRForms() {
        let ru = LocalizedStrings(language: .ru)
        XCTAssertEqual(ru.t("report.pages", 1), "1 страница")
        XCTAssertEqual(ru.t("report.pages", 3), "3 страницы")
        XCTAssertEqual(ru.t("report.pages", 5), "5 страниц")
        XCTAssertEqual(ru.t("report.pages", 21), "21 страница")
        XCTAssertEqual(ru.t("period.months", 12), "12 месяцев")
        let en = LocalizedStrings(language: .en)
        XCTAssertEqual(en.t("report.pages", 1), "1 page")
        XCTAssertEqual(en.t("report.pages", 2), "2 pages")
        XCTAssertEqual(en.t("period.months", 1), "month")
        XCTAssertEqual(LocalizedStrings(language: .de).t("period.years", 1), "Jahr")
    }

    func testFormatsWithArguments() {
        XCTAssertEqual(LocalizedStrings(language: .en).t("paywall.savings", 49), "Save 49%")
        XCTAssertEqual(LocalizedStrings(language: .ru).t("report.footer.createdWith", "App"), "Создано в App")
    }

    func testUnknownKeyFallsBackToEnglishThenKey() {
        XCTAssertEqual(LocalizedStrings(language: .ru).t("does.not.exist"), "does.not.exist")
    }

    func testEveryErrorCodeHasAMessage() {
        for code in AppErrorCode.allCases {
            let message = L(code.messageKey)
            XCTAssertNotEqual(message, code.messageKey, code.rawValue)
        }
    }
}

final class ConfigAndAnalyticsTests: XCTestCase {
    func testMissingAndPlaceholderValuesAreRejected() {
        let empty = EnvironmentConfig(info: ["WPSupportEmail": "", "WPPrivacyPolicyURL": "$(WP_PRIVACY_POLICY_URL)", "WPTermsURL": ""])
        XCTAssertNil(empty.supportEmail)
        XCTAssertEqual(empty.missingReleaseItems, ["WP_SUPPORT_EMAIL", "WP_PRIVACY_POLICY_URL", "WP_TERMS_URL"])
        let placeholder = EnvironmentConfig(info: ["WPSupportEmail": "support@example.com", "WPPrivacyPolicyURL": "https://example.com/privacy",
                                                   "WPTermsURL": "http://insecure.test/terms"])
        XCTAssertNil(placeholder.supportEmail)
        XCTAssertNil(placeholder.privacyPolicyURL)
        XCTAssertNil(placeholder.termsURL, "Only https is accepted")
        let ok = EnvironmentConfig(info: ["WPSupportEmail": "help@workphotos.app", "WPPrivacyPolicyURL": "https://workphotos.app/privacy",
                                          "WPTermsURL": "https://workphotos.app/terms", "WPAppEnvironment": "production", "WPAppStoreID": "123456"])
        XCTAssertTrue(ok.isReleaseReady)
        XCTAssertEqual(ok.environment, .production)
        XCTAssertEqual(ok.appStoreURL?.absoluteString, "https://apps.apple.com/app/id123456")
    }

    /// Section 16 / A28: events carry only allowed, content-free parameters.
    func testAnalyticsParametersAreWhitelisted() {
        let allowed: Set<String> = ["source", "templateType", "photoCountRange", "failedRange", "processingDurationBucket", "errorCode", "result"]
        let events: [AnalyticsEvent] = [
            .onboardingCompleted, .projectCreated, .captureSaved, .importCompleted(photoCount: 12, failedCount: 1), .pairCompleted,
            .reportPreviewed(template: .beforeAfter), .reportGenerated(template: .standard, photoCount: 210, duration: 12),
            .shareSheetOpened(source: .report), .shareCompleted(source: .report), .paywallViewed(trigger: .photoLimit),
            .purchaseResult(result: "failed", errorCode: .purchaseFailed), .restoreResult(found: false, errorCode: nil),
            .backupCreated(photoCount: 3), .backupRestored(photoCount: 3), .supportOpened(source: .settings),
            .error(code: .reportPhotoMissing, source: .report)
        ]
        for event in events {
            XCTAssertTrue(Set(event.parameters.keys).isSubset(of: allowed), event.name)
        }
        XCTAssertEqual(AnalyticsEvent.countBucket(210), "200+")
        XCTAssertEqual(AnalyticsEvent.durationBucket(12), "5-15s")
    }

    @MainActor
    func testDiagnosticsContainNoUserContent() throws {
        let env = try TestEnvironment()
        defer { env.cleanup() }
        let diagnostics = Diagnostics.collect(category: .pdf, files: env.files)
        let text = diagnostics.text
        XCTAssertTrue(text.contains("Category: pdf"))
        XCTAssertFalse(text.contains("@"), "No emails")
        XCTAssertTrue(["<1 GB", "1–5 GB", "5–20 GB", ">20 GB", "unknown"].contains(diagnostics.freeSpaceRange))
    }
}

/// StoreKit 2 flows with the local StoreKit configuration (development/tests only).
@MainActor
final class StoreKitFlowTests: XCTestCase {
    private var session: SKTestSession!

    override func setUp() async throws {
        let bundle = Bundle(for: StoreKitFlowTests.self)
        guard let url = bundle.url(forResource: "Products", withExtension: "storekit")
                ?? bundle.url(forResource: "Products", withExtension: "storekit", subdirectory: "StoreKit") else {
            throw XCTSkip("Products.storekit is not in the test bundle")
        }
        session = try SKTestSession(contentsOf: url)
        session.resetToDefaultState()
        session.clearTransactions()
        session.disableDialogs = true
        session.askToBuyEnabled = false
        // Note: the deprecated `failTransactionsEnabled` must not be touched — on iOS 17+ even setting it to
        // false makes purchases fail. Simulated errors use `setSimulatedError(_:forAPI:)`.
    }

    override func tearDown() async throws {
        session?.clearTransactions()
    }

    /// StoreKit Test applies expiry/refund/renewal changes asynchronously; poll the real entitlement check.
    private func waitFor(_ store: EntitlementService, timeout: TimeInterval = 8, until condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            await store.refreshEntitlements()
            if condition() { return }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
    }

    func testProductsPricesAndSavings() async throws {
        let store = EntitlementService()
        await store.loadProducts()
        XCTAssertEqual(store.productsState, .loaded)
        XCTAssertEqual(store.products.map(\.id), [ProductCatalog.monthly, ProductCatalog.yearly])
        XCTAssertEqual(store.monthly?.price, Decimal(string: "4.99"))
        XCTAssertEqual(store.yearly?.price, Decimal(string: "29.99"))
        XCTAssertEqual(store.yearlySavingsPercent, 49)
        XCTAssertEqual(store.monthly?.subscription?.subscriptionPeriod.unit, .month)
    }

    /// The Settings banner follows the verified StoreKit state: Free (with the trial chip) before the
    /// purchase, "You have Pro" with the trial end date after it. Images go to SAMPLES_DIR when set.
    func testProBannerFollowsEntitlement() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("wp-banner-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let files = FileStore(root: base.appendingPathComponent("data"), cachesRoot: base.appendingPathComponent("caches"),
                              tempRoot: base.appendingPathComponent("tmp"))
        let env = AppEnvironment(files: files, inMemory: true)
        await env.entitlements.loadProducts()
        await env.entitlements.refreshEntitlements()
        XCTAssertFalse(env.entitlements.isPro)
        let free = try XCTUnwrap(render(env, name: "banner_free"))
        XCTAssertGreaterThan(free.size.height, 100)

        let outcome = await env.entitlements.purchase(try XCTUnwrap(env.entitlements.yearly))
        XCTAssertEqual(outcome, .success)
        await waitFor(env.entitlements) { if case .trial = env.entitlements.displayState { return true } else { return false } }
        XCTAssertTrue(env.entitlements.isPro)
        let pro = try XCTUnwrap(render(env, name: "banner_pro"))
        XCTAssertGreaterThan(pro.size.height, 60)
    }

    private func render(_ env: AppEnvironment, name: String) -> UIImage? {
        for scheme in [ColorScheme.light, .dark] {
            let renderer = ImageRenderer(content: ProStatusBanner(onUpgrade: {})
                .environment(env)
                .environment(\.colorScheme, scheme)
                .frame(width: 361)
                .padding(16)
                .background(scheme == .dark ? Color.black : Color(white: 0.95)))
            renderer.scale = 3
            if let directory = ProcessInfo.processInfo.environment["SAMPLES_DIR"], let data = renderer.uiImage?.pngData() {
                try? data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name)_\(scheme == .dark ? "dark" : "light").png"))
            }
        }
        return ImageRenderer(content: ProStatusBanner(onUpgrade: {}).environment(env).frame(width: 361)).uiImage
    }

    /// Owner decision: a 3-day free trial for new subscribers, offered only while eligible.
    func testFreeTrialOfferAndEligibility() async throws {
        let store = EntitlementService()
        await store.loadProducts()
        let offer = try XCTUnwrap(store.trialOffer(for: ProductCatalog.yearly))
        XCTAssertEqual(offer.paymentMode, .freeTrial)
        XCTAssertEqual(offer.period.unit, .day)
        XCTAssertEqual(offer.period.value, 3)
        XCTAssertNotNil(store.trialOffer(for: ProductCatalog.monthly))
        XCTAssertTrue(TrialText.duration(offer).contains("3"), TrialText.duration(offer))

        let outcome = await store.purchase(try XCTUnwrap(store.yearly))
        XCTAssertEqual(outcome, .success)
        XCTAssertTrue(store.isPro)
        await waitFor(store) { if case .trial = store.displayState { return true } else { return false } }
        if case .trial = store.displayState {} else { XCTFail("Expected the trial state, got \(store.displayState)") }
        XCTAssertNil(store.trialOffer(for: ProductCatalog.yearly), "The trial is offered only once")
        XCTAssertNil(store.trialOffer(for: ProductCatalog.monthly), "Eligibility covers the whole subscription group")
    }

    /// A17 success, A18 expiry/refund.
    func testPurchaseThenExpireAndRefund() async throws {
        let store = EntitlementService()
        await store.loadProducts()
        await store.refreshEntitlements()
        XCTAssertFalse(store.isPro)
        let monthly = try XCTUnwrap(store.monthly)
        let outcome = await store.purchase(monthly)
        XCTAssertEqual(outcome, .success)
        XCTAssertTrue(store.isPro)
        XCTAssertEqual(store.activeProductID, ProductCatalog.monthly)

        try session.expireSubscription(productIdentifier: ProductCatalog.monthly)
        await waitFor(store) { !store.isPro }
        XCTAssertFalse(store.isPro, "Expired subscriptions are not active")

        let second = await store.purchase(monthly)
        XCTAssertEqual(second, .success)
        XCTAssertTrue(store.isPro)
        let transaction = try XCTUnwrap(session.allTransactions().last)
        try session.refundTransaction(identifier: UInt(transaction.identifier))
        await waitFor(store) { !store.isPro }
        XCTAssertFalse(store.isPro, "Refunded/revoked purchases are not active")
    }

    func testAskToBuyIsPendingWithoutPro() async throws {
        session.askToBuyEnabled = true
        let store = EntitlementService()
        await store.loadProducts()
        let outcome = await store.purchase(try XCTUnwrap(store.yearly))
        XCTAssertEqual(outcome, .pending)
        XCTAssertFalse(store.isPro)
        XCTAssertEqual(store.displayState, .pending)
    }

    func testFailedPurchaseKeepsFree() async throws {
        try await session.setSimulatedError(.generic(.unknown), forAPI: .purchase)
        let store = EntitlementService()
        await store.loadProducts()
        let outcome = await store.purchase(try XCTUnwrap(store.monthly))
        if case .failed = outcome {} else { XCTFail("Expected failure, got \(outcome)") }
        XCTAssertFalse(store.isPro)
        XCTAssertFalse(store.isPurchasing, "No endless spinner")
        try await session.setSimulatedError(nil, forAPI: .purchase)
    }

    /// PAY-04: an unverified transaction never unlocks Pro.
    func testUnverifiedPurchaseDoesNotUnlock() async throws {
        try await session.setSimulatedError(.verification(.invalidSignature), forAPI: .verification)
        let store = EntitlementService()
        await store.loadProducts()
        let outcome = await store.purchase(try XCTUnwrap(store.monthly))
        XCTAssertEqual(outcome, .unverified)
        XCTAssertFalse(store.isPro)
        try await session.setSimulatedError(nil, forAPI: .verification)
    }

    func testRestoreWithoutPurchasesFindsNothing() async throws {
        let store = EntitlementService()
        let outcome = await store.restore()
        XCTAssertNotEqual(outcome, .restored)
        XCTAssertFalse(store.isPro)
    }

    /// A18: billing grace keeps Pro; billing retry without grace does not.
    func testGracePeriodAndBillingRetry() async throws {
        session.shouldEnterBillingRetryOnRenewal = true
        session.billingGracePeriodIsEnabled = true
        let store = EntitlementService()
        await store.loadProducts()
        _ = await store.purchase(try XCTUnwrap(store.monthly))
        XCTAssertTrue(store.isPro)
        try session.forceRenewalOfSubscription(productIdentifier: ProductCatalog.monthly)
        await waitFor(store) { if case .inGracePeriod = store.displayState { return true } else { return false } }
        if case .inGracePeriod = store.displayState {} else { XCTFail("Unexpected state \(store.displayState)") }
        XCTAssertTrue(store.isPro, "Grace period keeps access as confirmed by StoreKit")

        session.clearTransactions()
        session.billingGracePeriodIsEnabled = false
        let second = EntitlementService()
        await second.loadProducts()
        _ = await second.purchase(try XCTUnwrap(second.monthly))
        try session.forceRenewalOfSubscription(productIdentifier: ProductCatalog.monthly)
        await waitFor(second) { !second.isPro }
        XCTAssertFalse(second.isPro, "Billing retry is not treated as active")
        XCTAssertEqual(second.displayState, .billingRetry)
        session.shouldEnterBillingRetryOnRenewal = false
    }

    func testAutoRenewOffKeepsAccessUntilExpiry() async throws {
        let store = EntitlementService()
        await store.loadProducts()
        _ = await store.purchase(try XCTUnwrap(store.monthly))
        XCTAssertTrue(store.isPro)
        try session.disableAutoRenewForTransaction(identifier: UInt(try XCTUnwrap(session.allTransactions().last).identifier))
        await waitFor(store) { if case .cancelledAutoRenew = store.displayState { return true } else { return false } }
        XCTAssertTrue(store.isPro, "A20: Pro stays until the paid period ends")
        if case .cancelledAutoRenew = store.displayState {} else { XCTFail("Unexpected state \(store.displayState)") }
    }
}
