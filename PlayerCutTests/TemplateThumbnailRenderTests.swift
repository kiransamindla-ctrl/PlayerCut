//
//  TemplateThumbnailRenderTests.swift
//  PlayerCutTests
//
//  DEV-only utility — runs the keystone end-to-end against each of the
//  6 ReelTemplates and writes a 600×800 mid-reel JPEG to the test
//  bundle's Documents directory. The engineer extracts the JPGs via
//  `xcrun simctl get_app_container booted com.playercut.app data`
//  and commits them under PlayerCut/Resources/Thumbnails/.
//
//  Cost — each template export takes 25–40 s. The 6-template sweep
//  takes ~3 minutes; well past the xcodebuild MCP's 100 s ceiling,
//  so we run from the shell:
//
//      xcodebuild test -only-testing:PlayerCutTests/TemplateThumbnailRenderTests
//          -destination 'platform=iOS Simulator,id=<simID>'
//
//  Skip by default to keep CI / dev runs green. Same flip-the-guard
//  workflow as BPMManifestRebuildTests (env vars don't reach xctest
//  via xcodebuild CLI — verified 2026-05-31).
//

import AVFoundation
import CoreImage
import ImageIO
import MobileCoreServices
import UniformTypeIdentifiers
import XCTest
@testable import PlayerCut

@MainActor
final class TemplateThumbnailRenderTests: XCTestCase {

    func testRenderAllTemplateThumbnails() async throws {
        throw XCTSkip("DEV-only — un-comment the loop below to render Resources/Thumbnails JPGs; extract via `xcrun simctl get_app_container booted com.playercut.app data`.")
        // for template in TemplateRegistry.shared.list() {
        //     try await renderOne(template: template)
        // }
    }

    // MARK: - Per-template rendering helper (also useful for one-off
    // re-renders during template tweaks).

    func renderOne(template: ReelTemplate) async throws {
        let spec = SampleVideoFactory.Spec()  // 8 s, 1280×720, 30 fps
        let videoURL = try await SampleVideoFactory.makeSampleVideo(spec: spec)
        defer { try? FileManager.default.removeItem(at: videoURL) }

        let player = PlayerEnrollment(
            id: UUID(), name: "Thumb", jerseyNumber: "0",
            jerseyColorHSV: HSVHistogram(bins: [Float](repeating: 0, count: 256)),
            faceEmbedding: [Float](repeating: 0, count: 128),
            sport: .soccer, createdAt: Date())
        let game = GameSession(
            id: UUID(), playerId: player.id, sport: .soccer,
            startedAt: Date(), endedAt: Date(),
            rawVideoURL: videoURL, audioLoudnessURL: videoURL,
            stage1Result: nil, stage2Result: nil,
            status: .completed, triggerSource: .manual, sceneType: .outdoor)
        let reelPlan = ReelPlan(
            selected: [
                makeClip(0.5, 3.0, 0.82),
                makeClip(3.0, 5.5, 0.70),
                makeClip(5.5, 7.8, 0.64),
            ],
            totalDuration: 8, tier: .normal)

        let settings = ReelSettings.defaults.applying(template)
        let music = MusicLibrary.shared.pick(vibe: template.musicVibe,
                                             playerId: player.id,
                                             length: .sixtySeconds)
        let builder = EditPlanBuilder(
            style: .energetic,
            output: OutputSpec(size: CGSize(width: 1080, height: 1920), fps: 30),
            sourceDuration: 8,
            profile: .highEnd,
            settings: settings,
            template: template)
        let editPlan = builder.build(from: reelPlan, player: player, game: game,
                                     musicURL: music?.url,
                                     musicBPM: music.map { Double($0.bpm) })

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("thumb-source-\(template.id).mp4")
        try? FileManager.default.removeItem(at: outputURL)
        let composer = ReelComposer()
        composer.savesToPhotos = false
        let result = try await composer.compose(
            plan: editPlan, game: game, player: player, outputURL: outputURL)

        // Mid-reel frame: sit at totalDuration / 2 so the snapshot lands
        // INSIDE the body (past the cold open / title card).
        let asset = AVURLAsset(url: result.localURL)
        let duration = try await asset.load(.duration).seconds
        let mid = CMTime(seconds: duration / 2, preferredTimescale: 600)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        // Target the spec'd thumbnail short edge so we don't waste pixels.
        generator.maximumSize = CGSize(width: 1200, height: 1600)
        let cg = try generator.copyCGImage(at: mid, actualTime: nil)

        // Resize / crop to exactly 600 × 800 (3:4 portrait) to match the
        // PreRecordSheet tile aspect (110 × 140 ≈ 1:1.27 ≈ 600 × 760;
        // 600 × 800 leaves a tiny vertical margin which the SwiftUI tile
        // crops away).
        let target = CGSize(width: 600, height: 800)
        let resized = try resize(cg, to: target)

        // JPEG out to Documents so simctl get_app_container can extract it.
        let docs = try FileManager.default.url(
            for: .documentDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true)
        let thumbDir = docs.appendingPathComponent("PlayerCutThumbnails", isDirectory: true)
        try FileManager.default.createDirectory(at: thumbDir,
                                                withIntermediateDirectories: true)
        let outJPG = thumbDir.appendingPathComponent("\(template.id).jpg")
        try writeJPEG(cgImage: resized, to: outJPG, quality: 0.85)

        FileHandle.standardError.write(Data(
            "THUMB[\(template.id)]: wrote \(outJPG.path)\n".utf8))
    }

    // MARK: - Helpers

    private func makeClip(_ start: Double, _ end: Double,
                          _ score: Float) -> SelectedClip {
        let w = CandidateWindow(id: UUID(),
                                startTime: start, endTime: end,
                                audioScore: score, motionScore: score)
        let m = ScoredMoment(id: UUID(), window: w,
                             identificationConfidence: score,
                             activityScore: score,
                             playerBoundingBoxes: [],
                             compositeScore: score)
        return SelectedClip(moment: m, clipStart: start, clipEnd: end)
    }

    /// Aspect-preserving resize-and-center-crop onto `target` via CIImage.
    private func resize(_ cg: CGImage, to target: CGSize) throws -> CGImage {
        let src = CIImage(cgImage: cg)
        let srcW = CGFloat(cg.width)
        let srcH = CGFloat(cg.height)
        let scale = max(target.width / srcW, target.height / srcH)
        let scaled = src.transformed(by: CGAffineTransform(scaleX: scale,
                                                           y: scale))
        // Center crop onto the target rect.
        let scaledExt = scaled.extent
        let originX = (scaledExt.width  - target.width)  / 2 + scaledExt.origin.x
        let originY = (scaledExt.height - target.height) / 2 + scaledExt.origin.y
        let cropped = scaled.cropped(to: CGRect(
            x: originX, y: originY,
            width: target.width, height: target.height))
        let ctx = CIContext(options: [.useSoftwareRenderer: false])
        guard let out = ctx.createCGImage(cropped,
                                          from: CGRect(origin: .zero,
                                                       size: target))
        else { throw NSError(domain: "thumb", code: 1) }
        return out
    }

    private func writeJPEG(cgImage: CGImage,
                           to url: URL,
                           quality: Double) throws {
        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else { throw NSError(domain: "thumb", code: 2) }
        let opts: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        CGImageDestinationAddImage(dest, cgImage, opts as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            throw NSError(domain: "thumb", code: 3)
        }
    }
}
