import Foundation

/// Back / Forward history for one tab, like Explorer's.
struct NavigationHistory {
    private(set) var backStack: [Location] = []
    private(set) var forwardStack: [Location] = []
    private(set) var current: Location
    let limit: Int

    init(start: Location, limit: Int = 64) {
        current = start
        self.limit = limit
    }

    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }

    mutating func visit(_ location: Location) {
        guard location != current else { return }
        backStack.append(current)
        if backStack.count > limit { backStack.removeFirst(backStack.count - limit) }
        current = location
        forwardStack.removeAll()
    }

    /// Replaces the current entry without adding history (used while refining a search).
    mutating func replaceCurrent(with location: Location) {
        current = location
    }

    @discardableResult
    mutating func goBack(steps: Int = 1) -> Location? {
        guard steps > 0, steps <= backStack.count else { return nil }
        for _ in 0..<steps {
            forwardStack.append(current)
            current = backStack.removeLast()
        }
        return current
    }

    @discardableResult
    mutating func goForward(steps: Int = 1) -> Location? {
        guard steps > 0, steps <= forwardStack.count else { return nil }
        for _ in 0..<steps {
            backStack.append(current)
            current = forwardStack.removeLast()
        }
        return current
    }
}
