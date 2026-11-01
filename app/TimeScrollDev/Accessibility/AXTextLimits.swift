/// Bounds on one Accessibility text extraction. Depth and budgets are this high because deeply
/// nested web and Electron content needs them; frame culling keeps the work to what is visible.
struct AXTextLimits {
    let maxWindows: Int
    let maxCharsPerWindow: Int
    let maxTotalChars: Int
    let maxDepth: Int
    /// Elements read per window, a backstop for trees whose frames cannot be culled.
    let maxElementsPerWindow: Int
    /// Per window: no new element is started after the soft budget, no IPC runs past the hard one.
    let softTimeBudgetMs: Int
    let hardTimeBudgetMs: Int

    static let `default` = AXTextLimits(
        maxWindows: 16,
        maxCharsPerWindow: 50_000,
        maxTotalChars: 200_000,
        maxDepth: 48,
        maxElementsPerWindow: 20_000,
        softTimeBudgetMs: 200,
        hardTimeBudgetMs: 400
    )
}
