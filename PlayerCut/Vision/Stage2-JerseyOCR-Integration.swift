//
//  Stage2-JerseyOCR-Integration.swift
//  PlayerCut
//
//  This is a patch file showing the precise diff to apply inside
//  Stage2PlayerLocalizer.swift to use the production JerseyOCR module.
//
//  REPLACE the existing scoreJerseyNumber(...) AND restructure
//  processWindow(...) to accumulate frame results, then aggregate at the
//  end of the window.
//

/*
 BEFORE (per-frame, no temporal voting):

     async let numberScore: Float = {
         guard let torso = torsoCrop else { return 0 }
         return await self.scoreJerseyNumber(in: torso, target: enrollment.jerseyNumber)
     }()

 AFTER (per-frame collection, window-level vote):

     // Inside processWindow, before the frame loop:
     let ocr = JerseyOCR()
     var ocrFrameResults: [JerseyOCR.FrameResult] = []

     // Inside the frame loop, replacing the numberScore line:
     for person in people {
         let personCrop = cropPerson(person, from: cgImage)
         let frameResult = await ocr.recognize(in: personCrop,
                                               targetNumber: enrollment.jerseyNumber)
         ocrFrameResults.append(frameResult)
         // ... still compute color and face per-frame
     }

     // After the frame loop:
     let ocrWindowResult = ocr.aggregate(frameResults: ocrFrameResults,
                                         targetNumber: enrollment.jerseyNumber)
     let numberScoreFinal = ocrWindowResult.matchConfidence

  KEY BEHAVIORAL CHANGE: numberScore now reflects evidence ACROSS the window,
  not the best single frame. This dramatically reduces false positives from
  random "23" texts in the crowd background and false negatives from a single
  motion-blurred frame.

  RANKING WEIGHT ADJUSTMENT: When ocrWindowResult.frameCount >= 3, treat the
  jersey number signal as fully reliable (weight 0.5). Below 3, downweight to
  0.2 and redistribute to color (0.5) and face (0.3). Reason: a single-frame
  OCR hit on a blurry frame is the #1 source of false IDs in real footage.
 */

import Foundation
