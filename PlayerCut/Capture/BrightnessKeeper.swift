//
//  BrightnessKeeper.swift
//  PlayerCut/Capture
//
//  Persistent guardrail around UIScreen.main.brightness. The capture
//  flow dims the screen to 10% so a 90-minute sideline recording isn't
//  driving a 600-nit panel nobody is looking at, but if the user
//  switches to another app mid-recording (or the app gets evicted)
//  there's no view-level lifecycle that fires to restore brightness.
//
//  Persisting the pre-dim brightness in UserDefaults means we can
//  always restore — from scenePhase background, from a fresh launch,
//  from anywhere — without ever stranding the user at 10%.
//

import Foundation
import UIKit

enum BrightnessKeeper {

    private static let savedKey = "com.playercut.brightness.saved"
    private static let activeKey = "com.playercut.brightness.dimActive"
    private static let dimLevel: CGFloat = 0.1

    /// Capture the user's current brightness (only on the first call;
    /// subsequent calls do not overwrite) and dim the screen.
    static func dim() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: savedKey) == nil {
            defaults.set(Double(UIScreen.main.brightness), forKey: savedKey)
        }
        defaults.set(true, forKey: activeKey)
        UIScreen.main.brightness = dimLevel
    }

    /// Restore the captured pre-dim brightness if we ever dimmed; otherwise
    /// no-op. Safe to call repeatedly and from any lifecycle hook.
    static func restore() {
        let defaults = UserDefaults.standard
        guard let saved = defaults.object(forKey: savedKey) as? Double else {
            // Nothing to restore — but be sure the active flag is cleared.
            defaults.removeObject(forKey: activeKey)
            return
        }
        UIScreen.main.brightness = CGFloat(saved)
        defaults.removeObject(forKey: savedKey)
        defaults.removeObject(forKey: activeKey)
    }

    /// True iff dim() has been called and restore() has not yet run.
    /// Used by scene-phase handlers to decide whether to re-apply the
    /// dim on return to active.
    static var isDimmed: Bool {
        UserDefaults.standard.bool(forKey: activeKey)
    }
}
