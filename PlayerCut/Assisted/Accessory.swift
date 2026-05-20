//
//  Accessory.swift
//  PlayerCut/Assisted
//
//  Data describing recommended accessories. Affiliate URLs are
//  placeholders — populate `affiliateURL` with a real Amazon Associates
//  link before ship. Per CLAUDE.md POLICY 1, no PlayerCut-branded
//  hardware is recommended; the suggestions are off-the-shelf parts.
//
//  SOURCE: prices observed on amazon.com 2026-05-19 — replace with
//  current values periodically.
//

import Foundation

struct Accessory: Identifiable {
    let id: String
    let title: String
    let summary: String
    let priceRange: String
    let category: Category
    let affiliateURL: URL?    // TODO Assisted-LAUNCH: real Associates URL
    let systemImage: String   // placeholder icon

    enum Category: String, CaseIterable {
        case mount = "Mount & lenses"
        case beacon = "Beacon (Assisted)"
        case audio = "Audio"
        case device = "Device reuse"
    }
}

enum AccessoryCatalog {
    /// Curated recommendations. Order matters — higher items render
    /// first in the gear list.
    static let all: [Accessory] = [
        Accessory(
            id: "tripod",
            title: "Tripod with phone mount",
            summary: "Any sturdy tripod with a 1/4\"-20 mount and a smartphone clamp. Match the height to head-of-shoulder when the kid is on the field.",
            priceRange: "$30–$60",
            category: .mount,
            affiliateURL: URL(string: "https://www.amazon.com/?tag=playercut-20-PLACEHOLDER"),
            systemImage: "tripod.fill"),
        Accessory(
            id: "telephoto",
            title: "Telephoto clip-on lens (Moment 58mm / ShiftCam ProLens)",
            summary: "Pulls distant kids closer without cropping. Worth it for soccer or football sidelines >20 m.",
            priceRange: "$50–$100",
            category: .mount,
            affiliateURL: URL(string: "https://www.amazon.com/?tag=playercut-20-PLACEHOLDER"),
            systemImage: "camera.aperture"),
        Accessory(
            id: "wide-lens",
            title: "Wide-angle clip-on lens",
            summary: "Indoor courts where you can't back up. Captures the full play without a tripod move.",
            priceRange: "$30–$60",
            category: .mount,
            affiliateURL: URL(string: "https://www.amazon.com/?tag=playercut-20-PLACEHOLDER"),
            systemImage: "circle.dashed"),
        Accessory(
            id: "beacon",
            title: "BLE iBeacon-compatible tracker (AltBeacon / Estimote / Aprilbeacon)",
            summary: "Pinned to the kid's bag or jersey. PlayerCut uses proximity to lock identification with no OCR or face match needed — biggest accuracy unlock for the Assisted tier.",
            priceRange: "$15–$40",
            category: .beacon,
            affiliateURL: URL(string: "https://www.amazon.com/?tag=playercut-20-PLACEHOLDER"),
            systemImage: "dot.radiowaves.left.and.right"),
        Accessory(
            id: "mic",
            title: "External Bluetooth mic (Røde Wireless GO II)",
            summary: "Optional. Cleaner crowd audio means tighter Stage 1 detection. Skip unless you're picking up too much wind.",
            priceRange: "$150–$200",
            category: .audio,
            affiliateURL: URL(string: "https://www.amazon.com/?tag=playercut-20-PLACEHOLDER"),
            systemImage: "mic.fill"),
        Accessory(
            id: "old-iphone",
            title: "Old iPhone (drawer-grade)",
            summary: "Free. Use a phone you don't need during the game. Battery only needs to last one half — iPhone 13 or newer.",
            priceRange: "$0",
            category: .device,
            affiliateURL: nil,
            systemImage: "iphone.gen3"),
    ]
}
