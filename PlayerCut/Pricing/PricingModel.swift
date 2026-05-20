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
}
