//
//  PoseSignal.swift
//  PlayerCut/Pose
//
//  Stub for the MediaPipe-BlazePose-as-CoreML identification signal.
//  The real .mlmodel(c) isn't bundled yet — see Dependencies.md and
//  Tools/convert_blazepose.py (not yet written).
//
//  Stage 2 calls `score(personCrop:enrolled:)` to add a 4th
//  identification signal alongside number / color / face. The stub
//  returns 0 (no contribution), and the existing weight-redistribution
//  logic correctly falls back to the 3-signal stack.
//
//  TODO Pose-LAUNCH:
//   - Convert BlazePose Lite to CoreML via coremltools
//   - Bundle the .mlmodelc under PlayerCut/Models/Pose/
//   - Implement landmark extraction → 33-keypoint vector
//   - Cosine-similarity score against the enrolled reference pose
//     captured during enrollment's optional "pose walkthrough" step
//   - Expose pose weight 0.15 in IdentificationWeights
//

import CoreGraphics
import Foundation

enum PoseSignal {
    /// Cosine similarity in [0, 1] between the detected pose and the
    /// enrolled player's reference pose. 0 when no pose available.
    static func score(personCrop: CGImage,
                      enrolledReferencePose: [Float]?) -> Float {
        guard enrolledReferencePose != nil else { return 0 }
        // TODO Pose-LAUNCH: load CoreML model, run inference, compute
        // similarity. Returning 0 keeps the stub compatible with the
        // existing weight-redistribution behavior.
        return 0
    }
}
