import AppKit

/// Explorer's "Copying 12 items to Documents" dialog. Appears only when an operation takes a while.
final class ProgressWindowController: NSWindowController {
    private let progress: OperationProgress?
    private let titleLabel = NSTextField.label("", size: 13, weight: .semibold)
    private let detailLabel = NSTextField.label("", size: 11, color: .secondaryLabelColor)
    private let bar = NSProgressIndicator()
    private var timer: Timer?
    private var pendingShow: DispatchWorkItem?
    private var finished = false

    init(title: String, progress: OperationProgress?) {
        self.progress = progress
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 120),
            styleMask: [.titled],
            backing: .buffered,
            defer: true
        )
        panel.title = "Arbor"
        panel.isReleasedWhenClosed = false
        super.init(window: panel)

        titleLabel.stringValue = title
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.isIndeterminate = progress == nil
        bar.minValue = 0
        bar.maxValue = Double(max(progress?.total ?? 1, 1))
        bar.style = .bar

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelPressed))
        cancel.translatesAutoresizingMaskIntoConstraints = false
        cancel.keyEquivalent = "\u{1b}"
        cancel.isHidden = progress == nil

        let content = NSView()
        [titleLabel, detailLabel, bar, cancel].forEach(content.addSubview)
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            titleLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            titleLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            bar.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 12),
            bar.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            detailLabel.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 8),
            detailLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            detailLabel.trailingAnchor.constraint(equalTo: cancel.leadingAnchor, constant: -12),
            cancel.centerYAnchor.constraint(equalTo: detailLabel.centerYAnchor),
            cancel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
        ])
        panel.contentView = content
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func scheduleShow(after delay: TimeInterval, over parent: NSWindow?) {
        let work = DispatchWorkItem { [weak self, weak parent] in
            guard let self, !self.finished, let window = self.window else { return }
            if let parent {
                let frame = parent.frame
                window.setFrameOrigin(NSPoint(x: frame.midX - window.frame.width / 2, y: frame.midY - window.frame.height / 2))
            } else {
                window.center()
            }
            self.showWindow(nil)
            self.bar.startAnimation(nil)
            self.timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in self?.refresh() }
            self.refresh()
        }
        pendingShow = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func refresh() {
        guard let progress else { return }
        let snapshot = progress.snapshot
        bar.doubleValue = Double(snapshot.completed)
        detailLabel.stringValue = snapshot.currentName.isEmpty
            ? "\(snapshot.completed) of \(progress.total)"
            : "\(snapshot.completed + 1) of \(progress.total): \(snapshot.currentName)"
    }

    @objc private func cancelPressed() {
        progress?.cancel()
        detailLabel.stringValue = "Cancelling…"
    }

    func finish() {
        finished = true
        pendingShow?.cancel()
        timer?.invalidate()
        timer = nil
        close()
    }
}
