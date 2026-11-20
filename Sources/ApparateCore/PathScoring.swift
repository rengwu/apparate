/// Every completed alignment matches queryCount ancestors between its first
/// match and the item's parent. All other ancestors in that suffix are gaps,
/// regardless of where the later matches fall. Charge the capped penalty at
/// the first match so the DP optimizes the adjusted score, not a raw-score winner.
@inline(__always) func pathGapPenalty(chainCount: Int, firstMatch: Int, queryCount: Int) -> Double {
    0.1 * Double(min(4, max(0, chainCount - firstMatch - queryCount)))
}
