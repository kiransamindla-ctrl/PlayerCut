//
//  StringDistance.swift
//  PlayerCut
//
//  String-distance helpers shared across stages. Kept as free functions
//  so they're trivially testable without spinning up an actor.
//

import Foundation

/// Classic iterative Levenshtein edit distance.
///
/// Two rolling rows so memory stays O(min(m, n)) — matters when fuzzy-matching
/// long OCR strings against a target jersey number across many frames.
func levenshtein(_ a: String, _ b: String) -> Int {
    let aChars = Array(a), bChars = Array(b)
    let m = aChars.count, n = bChars.count
    if m == 0 { return n }
    if n == 0 { return m }
    var prev = Array(0...n)
    var curr = Array(repeating: 0, count: n + 1)
    for i in 1...m {
        curr[0] = i
        for j in 1...n {
            let cost = aChars[i-1] == bChars[j-1] ? 0 : 1
            curr[j] = min(prev[j] + 1, curr[j-1] + 1, prev[j-1] + cost)
        }
        swap(&prev, &curr)
    }
    return prev[n]
}
