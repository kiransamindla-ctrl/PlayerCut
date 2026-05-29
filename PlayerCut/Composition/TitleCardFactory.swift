//
//  TitleCardFactory.swift
//  PlayerCut/Composition
//
//  Animated title + closing cards and the lower-third overlay, built
//  out of CALayer / CATextLayer / CAKeyframeAnimation. The renderer
//  hands the parent layer to AVVideoCompositionCoreAnimationTool so
//  AVFoundation drives the timeline.
//
//  Coordinate space note: Core Animation rendering inside the
//  composition tool uses BOTTOM-LEFT origin, like Vision and unlike
//  UIKit. We position layers accordingly.
//

import AVFoundation
import CoreGraphics
import QuartzCore
import UIKit

enum TitleCardFactory {

    // MARK: - Static rasterization (MetalPetal unified render path)

    /// Returns a CALayer of the title card in its fully-visible state,
    /// suitable for rasterization via UIGraphicsImageRenderer. No
    /// CAAnimations attached — the MetalPetal compositor owns
    /// fade-in / fade-out via Overlay.alphaAt(outputTime:).
    static func staticTitleLayer(size: CGSize,
                                 spec: TitleCardSpec) -> CALayer {
        makeTitleCardLayer(size: size,
                           spec: spec,
                           startSeconds: 0,
                           duration: TitleCardSpec.duration,
                           animated: false)
    }

    static func staticClosingLayer(size: CGSize,
                                   spec: ClosingCardSpec) -> CALayer {
        makeClosingCardLayer(size: size,
                             spec: spec,
                             startSeconds: 0,
                             duration: ClosingCardSpec.duration,
                             animated: false)
    }

    static func staticLowerThirdLayer(size: CGSize,
                                      spec: LowerThirdSpec) -> CALayer {
        makeLowerThirdLayer(size: size,
                            spec: spec,
                            startSeconds: 0,
                            animated: false)
    }

    // (Removed the legacy AVVideoCompositionCoreAnimationTool `buildOverlay`
    //  path — it was unused dead code. The cinematic render path rasterizes
    //  staticTitleLayer / staticClosingLayer / staticLowerThirdLayer through
    //  the MetalPetal compositor instead.)

    // MARK: - Title card

    private static func makeTitleCardLayer(size: CGSize,
                                           spec: TitleCardSpec,
                                           startSeconds: Double,
                                           duration: Double,
                                           animated: Bool) -> CALayer {
        let host = CALayer()
        host.frame = CGRect(origin: .zero, size: size)

        // Solid black backplate (the title card sits *between* clips so
        // we render onto a black field, not on top of video).
        let bg = CALayer()
        bg.frame = host.bounds
        bg.backgroundColor = UIColor.black.cgColor
        host.addSublayer(bg)

        // Accent bar — animated width.
        let accent = CALayer()
        let accentColor = UIColor(hexString: spec.accentHex)
            ?? UIColor.systemOrange
        accent.backgroundColor = accentColor.cgColor
        let accentH: CGFloat = max(8, size.height * 0.012)
        let accentW = size.width * 0.18
        accent.frame = CGRect(x: (size.width - accentW) / 2,
                              y: size.height * 0.40,
                              width: accentW,
                              height: accentH)
        accent.cornerRadius = accentH / 2
        host.addSublayer(accent)

        // Primary name text.
        let primary = makeTextLayer(text: spec.primaryText,
                                    size: size,
                                    font: boldFont(of: size.height * 0.085),
                                    color: .white,
                                    yFraction: 0.46)
        host.addSublayer(primary)

        // Secondary metadata.
        let secondary = makeTextLayer(text: spec.secondaryText,
                                      size: size,
                                      font: boldFont(of: size.height * 0.025,
                                                     tracking: 4),
                                      color: UIColor(white: 0.85, alpha: 1),
                                      yFraction: 0.56)
        host.addSublayer(secondary)

        if animated {
            // Fade in / out (legacy CoreAnimationTool path).
            host.opacity = 0
            let fade = CAKeyframeAnimation(keyPath: "opacity")
            fade.beginTime = startSeconds
            fade.duration = duration
            fade.values = [0.0, 1.0, 1.0, 0.0]
            fade.keyTimes = [0.0, 0.15, 0.85, 1.0]
            fade.isRemovedOnCompletion = false
            fade.fillMode = .forwards
            host.add(fade, forKey: "fade")

            // Subtle parallax: text slides up slightly during the card.
            let slide = CABasicAnimation(keyPath: "transform.translation.y")
            slide.beginTime = startSeconds
            slide.duration = duration
            slide.fromValue = size.height * 0.01
            slide.toValue = -size.height * 0.005
            slide.isRemovedOnCompletion = false
            slide.fillMode = .forwards
            primary.add(slide, forKey: "slide")
        }
        // Static rasterization path leaves host opacity at the default
        // (1.0) so a single render captures the fully-visible card.
        return host
    }

    // MARK: - Lower third

    private static func makeLowerThirdLayer(size: CGSize,
                                            spec: LowerThirdSpec,
                                            startSeconds: Double,
                                            animated: Bool) -> CALayer {
        let host = CALayer()
        let height = size.height * 0.10
        host.frame = CGRect(x: 0,
                            y: size.height * 0.12,
                            width: size.width,
                            height: height)

        // Pill background — translucent dark with light blur backing.
        let pill = CALayer()
        let pillW = size.width * 0.70
        pill.frame = CGRect(x: (size.width - pillW) / 2,
                            y: 0,
                            width: pillW,
                            height: height)
        pill.cornerRadius = height / 2
        pill.backgroundColor = UIColor(white: 0, alpha: 0.55).cgColor
        host.addSublayer(pill)

        let primary = makeTextLayer(text: spec.primaryText,
                                    size: size,
                                    font: boldFont(of: height * 0.42),
                                    color: .white,
                                    explicitFrame: CGRect(x: pill.frame.minX,
                                                          y: height * 0.18,
                                                          width: pillW,
                                                          height: height * 0.5))
        host.addSublayer(primary)

        let secondary = makeTextLayer(text: spec.secondaryText,
                                      size: size,
                                      font: boldFont(of: height * 0.22,
                                                     tracking: 3),
                                      color: UIColor(white: 0.85, alpha: 1),
                                      explicitFrame: CGRect(x: pill.frame.minX,
                                                            y: height * 0.05,
                                                            width: pillW,
                                                            height: height * 0.22))
        host.addSublayer(secondary)

        if animated {
            // Slide in from below, hold, slide out.
            host.opacity = 0
            let begin = startSeconds + spec.startOffset
            let visible = spec.visibleDuration

            let slide = CAKeyframeAnimation(keyPath: "transform.translation.y")
            slide.beginTime = begin
            slide.duration = visible
            slide.values = [40, 0, 0, 40]
            slide.keyTimes = [0.0, 0.15, 0.85, 1.0]
            slide.isRemovedOnCompletion = false
            slide.fillMode = .forwards
            host.add(slide, forKey: "slide")

            let fade = CAKeyframeAnimation(keyPath: "opacity")
            fade.beginTime = begin
            fade.duration = visible
            fade.values = [0.0, 1.0, 1.0, 0.0]
            fade.keyTimes = [0.0, 0.18, 0.82, 1.0]
            fade.isRemovedOnCompletion = false
            fade.fillMode = .forwards
            host.add(fade, forKey: "fade")
        }
        return host
    }

    // MARK: - Closing card

    private static func makeClosingCardLayer(size: CGSize,
                                             spec: ClosingCardSpec,
                                             startSeconds: Double,
                                             duration: Double,
                                             animated: Bool) -> CALayer {
        let host = CALayer()
        host.frame = CGRect(origin: .zero, size: size)

        let bg = CALayer()
        bg.frame = host.bounds
        bg.backgroundColor = UIColor.black.cgColor
        host.addSublayer(bg)

        let primary = makeTextLayer(text: spec.primaryText.uppercased(),
                                    size: size,
                                    font: boldFont(of: size.height * 0.055,
                                                   tracking: 6),
                                    color: .white,
                                    yFraction: 0.48)
        host.addSublayer(primary)

        let secondary = makeTextLayer(text: spec.secondaryText,
                                      size: size,
                                      font: boldFont(of: size.height * 0.022,
                                                     tracking: 2),
                                      color: UIColor(white: 0.7, alpha: 1),
                                      yFraction: 0.55)
        host.addSublayer(secondary)

        if animated {
            host.opacity = 0
            let fade = CAKeyframeAnimation(keyPath: "opacity")
            fade.beginTime = startSeconds
            fade.duration = duration
            fade.values = [0.0, 1.0, 1.0]
            fade.keyTimes = [0.0, 0.3, 1.0]
            fade.isRemovedOnCompletion = false
            fade.fillMode = .forwards
            host.add(fade, forKey: "fade")
        }
        return host
    }

    // MARK: - Helpers

    private static func makeTextLayer(text: String,
                                      size: CGSize,
                                      font: UIFont,
                                      color: UIColor,
                                      yFraction: CGFloat? = nil,
                                      explicitFrame: CGRect? = nil) -> CATextLayer {
        let layer = CATextLayer()
        layer.contentsScale = 2 // sharp text at typical output sizes
        layer.alignmentMode = .center
        layer.foregroundColor = color.cgColor
        layer.string = text
        layer.font = font
        layer.fontSize = font.pointSize

        if let f = explicitFrame {
            layer.frame = f
        } else if let y = yFraction {
            let h: CGFloat = font.pointSize * 1.5
            layer.frame = CGRect(x: 0,
                                 y: (1.0 - y) * size.height - h / 2,
                                 width: size.width,
                                 height: h)
        }
        return layer
    }

    private static func boldFont(of size: CGFloat,
                                 tracking: CGFloat = 0) -> UIFont {
        // We can't easily set tracking on CATextLayer without
        // attributed strings; the tracking arg is here so the call
        // sites can document intent — for now we just return a heavy
        // weight system font.
        UIFont.systemFont(ofSize: size, weight: .heavy)
    }
}

// MARK: - UIColor hex parser

extension UIColor {
    convenience init?(hexString: String) {
        var s = hexString.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6 || s.count == 8 else { return nil }
        var rgba: UInt64 = 0
        guard Scanner(string: s).scanHexInt64(&rgba) else { return nil }
        if s.count == 6 {
            let r = CGFloat((rgba & 0xFF0000) >> 16) / 255.0
            let g = CGFloat((rgba & 0x00FF00) >> 8) / 255.0
            let b = CGFloat(rgba & 0x0000FF) / 255.0
            self.init(red: r, green: g, blue: b, alpha: 1)
        } else {
            let r = CGFloat((rgba & 0xFF000000) >> 24) / 255.0
            let g = CGFloat((rgba & 0x00FF0000) >> 16) / 255.0
            let b = CGFloat((rgba & 0x0000FF00) >> 8) / 255.0
            let a = CGFloat(rgba & 0x000000FF) / 255.0
            self.init(red: r, green: g, blue: b, alpha: a)
        }
    }
}
