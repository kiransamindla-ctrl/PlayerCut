//
//  PricingModel.swift
//  PlayerCut/Pricing
//
//  Subscription plans and free-trial accounting. StoreKit 2 calls are
//  stubbed pending real product IDs in App Store Connect — every
//  paywall path is tagged `// TODO StoreKit2-LAUNCH:` so the real
//  integration is greppable.
//

import Foundation
import SwiftUI

enum PricingPlan: String, CaseIterable, Codable {
    case freeTrial
    case singleMonthly
    case familyMonthly
    case singleAnnual
    case familyAnnual
    case lifetime

    var displayName: String {
        switch self {
        case .freeTrial:     return "Free trial"
        case .singleMonthly: return "Single — Monthly"
        case .familyMonthly: return "Family — Monthly"
        case .singleAnnual:  return "Single — Annual"
        case .familyAnnual:  return "Family — Annual"
        case .lifetime:      return "Lifetime"
        }
    }

    var priceLine: String {
        switch self {
        case .freeTrial:     return "3 reels free"
        case .singleMonthly: return "$5.99/mo"
        case .familyMonthly: return "$9.99/mo"
        case .singleAnnual:  return "$29/yr"
        case .familyAnnual:  return "$49/yr"
        case .lifetime:      return "$79 once"
        }
    }

    var includesLine: String {
        switch self {
        case .freeTrial:     return "1 player · first 3 reels"
        case .singleMonthly: return "1 player · cancel anytime"
        case .familyMonthly: return "Up to 3 players"
        case .singleAnnual:  return "1 player · best value"
        case .familyAnnual:  return "Up to 3 players"
        case .lifetime:      return "1 player · no future bill"
        }
    }

    var maxPlayers: Int {
        switch self {
        case .freeTrial, .singleMonthly, .singleAnnual, .lifetime: return 1
        case .familyMonthly, .familyAnnual: return 3
        }
    }

    /// App Store Connect product identifier. The five paid plans below
    /// match the IDs in `Configuration.storekit` (sim sandbox) AND the
    /// IDs the maintainer creates in App Store Connect for production.
    /// Returns nil for `.freeTrial` (it's not a purchasable SKU).
    var productID: String? {
        switch self {
        case .freeTrial:     return nil
        case .singleMonthly: return "com.playercut.app.single.monthly"
        case .familyMonthly: return "com.playercut.app.family.monthly"
        case .singleAnnual:  return "com.playercut.app.single.annual"
        case .familyAnnual:  return "com.playercut.app.family.annual"
        case .lifetime:      return "com.playercut.app.lifetime"
        }
    }

    /// Reverse map for Transaction.productID → PricingPlan.
    static func fromProductID(_ id: String) -> PricingPlan? {
        PricingPlan.allCases.first { $0.productID == id }
    }
}

enum PricingKeys {
    static let currentPlan      = "playercut.plan"
    static let freeReelsUsed    = "playercut.free_reels_used"
    static let paywallDismissed = "playercut.paywall_dismissed_count"
}

/// Free trial allowance and gate logic. The paywall surfaces after the
/// 3rd completed free reel; Maybe-Later grants one extra reel up to a
/// hard cap of 5 lifetime free reels.
enum PricingGate {
    static let freeReelInitialAllowance = 3
    static let freeReelHardCap          = 5

    static var currentPlan: PricingPlan {
        guard let raw = UserDefaults.standard.string(forKey: PricingKeys.currentPlan),
              let plan = PricingPlan(rawValue: raw) else {
            return .freeTrial
        }
        return plan
    }

    static var freeReelsUsed: Int {
        UserDefaults.standard.integer(forKey: PricingKeys.freeReelsUsed)
    }

    /// True when the user can still produce reels without a paid plan.
    static var hasFreeReelsRemaining: Bool {
        guard currentPlan == .freeTrial else { return true }
        return freeReelsUsed < freeReelHardCap
    }

    /// Whether the paywall should appear now (called from the
    /// orchestrator after a reel completes).
    static var shouldShowPaywall: Bool {
        guard currentPlan == .freeTrial else { return false }
        return freeReelsUsed >= freeReelInitialAllowance
    }

    static func recordFreeReelConsumed() {
        let next = freeReelsUsed + 1
        UserDefaults.standard.set(next, forKey: PricingKeys.freeReelsUsed)
    }

    static func setPlan(_ plan: PricingPlan) {
        UserDefaults.standard.set(plan.rawValue, forKey: PricingKeys.currentPlan)
    }

    /// Debug-only: reset the free-trial counter so the user can re-test
    /// the gated-paywall flow without uninstalling. Surfaced in
    /// Settings → Debug → "Reset free-trial counter".
    static func resetFreeTrial() {
        UserDefaults.standard.set(0, forKey: PricingKeys.freeReelsUsed)
        UserDefaults.standard.set(0, forKey: PricingKeys.paywallDismissed)
    }
}

#if canImport(StoreKit)
import StoreKit

/// Real StoreKit 2 wiring. Replaces the `// TODO StoreKit2-LAUNCH` stub.
/// - `Product.products(for:)` to load the SKUs (matches Configuration.storekit + ASC).
/// - `Product.purchase()` to actually charge the user.
/// - `Transaction.updates` async stream so renewals/refunds/family-share
///   updates land in PricingGate.plan without an app relaunch.
/// - `Transaction.currentEntitlements` at app launch to restore state.
@MainActor
final class StoreKitManager: ObservableObject {

    static let shared = StoreKitManager()

    @Published private(set) var products: [Product] = []
    @Published private(set) var isLoading = false
    @Published private(set) var lastError: String?

    private var updatesTask: Task<Void, Never>?

    private init() {}

    var productIDs: [String] {
        PricingPlan.allCases.compactMap(\.productID)
    }

    /// Load `Product` objects from the App Store (or Configuration.storekit
    /// in the sim). Idempotent; safe to call multiple times.
    func loadProducts() async {
        isLoading = true
        defer { isLoading = false }
        do {
            products = try await Product.products(for: productIDs)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Reconcile PricingGate.plan with whatever Apple thinks is purchased.
    /// Called at launch + whenever a Transaction.updates event arrives.
    func refreshEntitlements() async {
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result else { continue }
            if let plan = PricingPlan.fromProductID(transaction.productID),
               transaction.revocationDate == nil {
                PricingGate.setPlan(plan)
                return
            }
        }
        // No active entitlement → free trial.
        PricingGate.setPlan(.freeTrial)
    }

    /// Purchase one plan. Caller (PaywallView) shows a sheet/spinner; we
    /// finish the transaction on success and refresh entitlements.
    func purchase(_ plan: PricingPlan) async -> Result<PricingPlan, Error> {
        guard let pid = plan.productID,
              let product = products.first(where: { $0.id == pid }) else {
            return .failure(StoreKitError.productNotFound(plan))
        }
        do {
            let outcome = try await product.purchase()
            switch outcome {
            case .success(let verification):
                guard case .verified(let transaction) = verification else {
                    return .failure(StoreKitError.unverified)
                }
                await transaction.finish()
                PricingGate.setPlan(plan)
                return .success(plan)
            case .userCancelled:
                return .failure(StoreKitError.userCancelled)
            case .pending:
                return .failure(StoreKitError.pending)
            @unknown default:
                return .failure(StoreKitError.unknown)
            }
        } catch {
            return .failure(error)
        }
    }

    /// Restore Purchases — App Store requirement. AppStore.sync() asks
    /// Apple to re-deliver every owned non-consumable / subscription.
    func restorePurchases() async -> Result<PricingPlan, Error> {
        do {
            try await AppStore.sync()
            await refreshEntitlements()
            return .success(PricingGate.currentPlan)
        } catch {
            return .failure(error)
        }
    }

    /// Start listening for renewals/refunds. Call from app launch.
    func startListening() {
        guard updatesTask == nil else { return }
        updatesTask = Task.detached { [weak self] in
            for await result in Transaction.updates {
                guard case .verified(let transaction) = result else { continue }
                await transaction.finish()
                await self?.refreshEntitlements()
            }
        }
    }

    enum StoreKitError: LocalizedError {
        case productNotFound(PricingPlan)
        case unverified
        case userCancelled
        case pending
        case unknown
        var errorDescription: String? {
            switch self {
            case .productNotFound(let p): return "Product not found: \(p.rawValue)"
            case .unverified:             return "Purchase could not be verified by Apple."
            case .userCancelled:          return "Cancelled."
            case .pending:                return "Pending parental approval / payment."
            case .unknown:                return "Unknown purchase outcome."
            }
        }
    }
}
#endif
