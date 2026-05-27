//
//  TitleFrameTests.swift
//  PlayerCutTests
//
//  Bug #1: the title-card text rendered UPSIDE-DOWN in the exported reel.
//  This composes a reel with a title card, extracts the title-card frame,
//  asserts the overlay actually rendered (frame isn't all black), and
//  writes the frame to the app's Documents dir as title-frame.png so its
//  orientation can be pulled off the simulator and eyeballed.
//

import AVFoundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import PlayerCut

final class TitleFrameTests: XCTestCase {

    func testTitleCardFrameRenders() async throws {
        let videoURL = try await SampleVideoFactory.makeSampleVideo()
        defer { try? FileManager.default.removeItem(at: videoURL) }
        let srcDuration = try await AVURLAsset(url: videoURL).load(.duration).seconds

        let player = PlayerEnrollment(
            id: UUID(), name: "Marcus", jerseyNumber: "55",
            jerseyColorHSV: HSVHistogram(bins: [Float](repeating: 0, count: 256)),
            faceEmbedding: [Float](repeating: 0, count: 128),
            sport: .soccer, createdAt: Date())
        let game = GameSession(
            id: UUID(), playerId: player.id, sport: .soccer,
            startedAt: Date(), endedAt: Date(),
            rawVideoURL: videoURL, audioLoudnessURL: videoURL,
            stage1Result: nil, stage2Result: nil,
            status: .completed, triggerSource: .manual, sceneType: .outdoor)

        func clip(_ s: Double, _ e: Double, _ c: Float) -> SelectedClip {
            let w = CandidateWindow(id: UUID(), startTime: s, endTime: e,
                                    audioScore: c, motionScore: c)
            let m = ScoredMoment(id: UUID(), window: w,
                                 identificationConfidence: c, activityScore: c,
                                 playerBoundingBoxes: SampleVideoFactory.playerBoxes(start: s, end: e),
                                 compositeScore: c)
            return SelectedClip(moment: m, clipStart: s, clipEnd: e)
        }
        // Mirror the proven keystone: 3 clips (highest → cold open, two
        // body) + real bundled music, which composes cleanly on the sim.
        let music = await MainActor.run {
            MusicLibrary.shared.pick(vibe: player.musicVibe,
                                     playerId: player.id, length: .sixtySeconds)
        }
        let plan = ReelPlan(selected: [clip(0.5, 3.0, 0.82),
                                       clip(3.0, 5.5, 0.70),
                                       clip(5.5, 7.8, 0.64)],
                            totalDuration: srcDuration, tier: .normal)
        let builder = EditPlanBuilder(
            style: .energetic,
            output: OutputSpec(size: CGSize(width: 1080, height: 1920), fps: 30),
            sourceDuration: srcDuration, profile: .highEnd)
        let editPlan = builder.build(from: plan, player: player, game: game,
                                     musicURL: music?.url,
                                     musicBPM: music.map { Double($0.bpm) })

        // The title card is inserted right after the cold open.
        let titleStart = editPlan.coldOpen?.renderedDuration ?? 0
        let titleMid = titleStart + TitleCardSpec.duration / 2

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("title-check-\(UUID().uuidString).mp4")

        let composer = ReelComposer()
        composer.savesToPhotos = false
        let result = try await composer.compose(plan: editPlan, game: game,
                                                player: player, outputURL: outputURL)

        // Confirm compose produced a playable reel before extracting.
        let outAsset = AVURLAsset(url: result.localURL)
        let playable = try await outAsset.load(.isPlayable)
        XCTAssertTrue(playable, "Compose should produce a playable reel")

        // Extract the title-card frame. Infinite tolerance → always returns
        // the nearest decodable frame (no exact-seek failure).
        let gen = AVAssetImageGenerator(asset: outAsset)
        gen.appliesPreferredTrackTransform = true
        gen.requestedTimeToleranceBefore = .positiveInfinity
        gen.requestedTimeToleranceAfter = .positiveInfinity
        let cg = try gen.copyCGImage(
            at: CMTime(seconds: titleMid, preferredTimescale: 600),
            actualTime: nil)
        try? FileManager.default.removeItem(at: outputURL)

        // Write to the app's Documents dir so it can be pulled off the sim.
        let docs = FileManager.default.urls(for: .documentDirectory,
                                            in: .userDomainMask)[0]
        let pngURL = docs.appendingPathComponent("title-frame.png")
        if let dest = CGImageDestinationCreateWithURL(
            pngURL as CFURL, UTType.png.identifier as CFString, 1, nil) {
            CGImageDestinationAddImage(dest, cg, nil)
            CGImageDestinationFinalize(dest)
        }

        // The title card sits on a black field, so a correctly-composited
        // frame must have bright (text) pixels somewhere.
        let bright = Self.brightPixelFraction(cg)
        XCTAssertGreaterThan(bright, 0.0005,
                             "Title frame is essentially all black — overlay didn't render")
    }

    private static func brightPixelFraction(_ cg: CGImage) -> Double {
        let w = cg.width, h = cg.height
        let bpr = w * 4
        var buf = [UInt8](repeating: 0, count: bpr * h)
        guard let ctx = CGContext(
            data: &buf, width: w, height: h, bitsPerComponent: 8,
            bytesPerRow: bpr, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return 0 }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        var bright = 0
        var i = 0
        while i < buf.count {
            let lum = Int(buf[i]) + Int(buf[i + 1]) + Int(buf[i + 2])
            if lum > 384 { bright += 1 }
            i += 4
        }
        return Double(bright) / Double(w * h)
    }
}
