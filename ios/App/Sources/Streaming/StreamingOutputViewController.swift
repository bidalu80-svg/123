import UIKit

final class StreamingOutputViewController: UIViewController, UITextViewDelegate, UITextFieldDelegate {
    private let streamingService: StreamingServiceProviding
    private let markdownPostProcessor: MarkdownPostProcessing

    private let streamBuffer = StreamBuffer(maxBufferedCharacters: 140_000)
    private let segmentStore = StreamSegmentStore(segmentCharacterLimit: 5_000, maxArchivedCharacters: 140_000)
    private let markdownQueue = DispatchQueue(label: "chatapp.streaming.markdown", qos: .userInitiated)

    private lazy var renderer: StreamRenderer = {
        StreamRenderer(
            buffer: streamBuffer,
            configuration: StreamRenderer.Configuration(
                refreshInterval: 0.05,
                maxCharactersPerFrame: 50,
                maxCharactersFetchedPerTick: 1_400
            ),
            onBackgroundBatch: { [weak self] batch in
                self?.segmentStore.append(batch)
            },
            onFrameRender: { [weak self] delta in
                self?.appendRenderedDelta(delta)
            },
            onDrainComplete: { [weak self] in
                self?.handleRendererDrainComplete()
            }
        )
    }()

    private var activeStream: StreamCancellable?
    private var streamGeneration = 0
    private var isStreaming = false
    private var shouldStickToBottom = true

    private let maxVisibleCharacters = 16_000
    private let textFont = UIFont.monospacedSystemFont(ofSize: 16, weight: .regular)

    private let promptField = UITextField()
    private let profileControl = UISegmentedControl(items: MockStreamProfile.allCases.map(\.title))
    private let startButton = UIButton(type: .system)
    private let stopButton = UIButton(type: .system)
    private let clearButton = UIButton(type: .system)
    private let statusLabel = UILabel()
    private let textView = UITextView()

    init(
        streamingService: StreamingServiceProviding = MockStreamingService(),
        markdownPostProcessor: MarkdownPostProcessing = DeferredMarkdownPostProcessor()
    ) {
        self.streamingService = streamingService
        self.markdownPostProcessor = markdownPostProcessor
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        activeStream?.cancel()
        renderer.cancel(clearBuffer: false)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        applyInitialState()
    }

    // MARK: - UI Setup

    private func setupUI() {
        view.backgroundColor = .systemBackground

        promptField.translatesAutoresizingMaskIntoConstraints = false
        promptField.borderStyle = .roundedRect
        promptField.placeholder = "输入主题（回车开始流式输出）"
        promptField.clearButtonMode = .whileEditing
        promptField.returnKeyType = .go
        promptField.autocapitalizationType = .none
        promptField.autocorrectionType = .no
        promptField.delegate = self

        profileControl.translatesAutoresizingMaskIntoConstraints = false
        profileControl.selectedSegmentIndex = MockStreamProfile.standard.rawValue

        configureButton(startButton, title: "开始", tint: .systemBlue, action: #selector(didTapStart))
        configureButton(stopButton, title: "停止", tint: .systemRed, action: #selector(didTapStop))
        configureButton(clearButton, title: "清空", tint: .systemGray, action: #selector(didTapClear))

        let buttonRow = UIStackView(arrangedSubviews: [startButton, stopButton, clearButton])
        buttonRow.axis = .horizontal
        buttonRow.spacing = 10
        buttonRow.distribution = .fillEqually
        buttonRow.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.font = .systemFont(ofSize: 13, weight: .medium)
        statusLabel.textColor = .secondaryLabel
        statusLabel.numberOfLines = 2

        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.isEditable = false
        textView.isSelectable = true
        textView.isScrollEnabled = true
        textView.alwaysBounceVertical = true
        textView.keyboardDismissMode = .interactive
        textView.backgroundColor = UIColor.secondarySystemBackground
        textView.layer.cornerRadius = 12
        textView.textContainerInset = UIEdgeInsets(top: 14, left: 12, bottom: 14, right: 12)
        textView.textContainer.lineFragmentPadding = 0
        textView.layoutManager.allowsNonContiguousLayout = true
        textView.delegate = self
        textView.attributedText = NSAttributedString(string: "", attributes: streamingTextAttributes)

        let topStack = UIStackView(arrangedSubviews: [promptField, profileControl, buttonRow, statusLabel])
        topStack.axis = .vertical
        topStack.spacing = 10
        topStack.translatesAutoresizingMaskIntoConstraints = false

        let rootStack = UIStackView(arrangedSubviews: [topStack, textView])
        rootStack.axis = .vertical
        rootStack.spacing = 12
        rootStack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(rootStack)

        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            rootStack.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 12),
            rootStack.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -12),
            rootStack.topAnchor.constraint(equalTo: guide.topAnchor, constant: 10),
            rootStack.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -8),

            textView.heightAnchor.constraint(greaterThanOrEqualToConstant: 360)
        ])
    }

    private func configureButton(_ button: UIButton, title: String, tint: UIColor, action: Selector) {
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setTitle(title, for: .normal)
        button.setTitleColor(.white, for: .normal)
        button.backgroundColor = tint
        button.layer.cornerRadius = 10
        button.titleLabel?.font = .systemFont(ofSize: 15, weight: .semibold)
        button.contentEdgeInsets = UIEdgeInsets(top: 11, left: 10, bottom: 11, right: 10)
        button.addTarget(self, action: action, for: .touchUpInside)
    }

    private func applyInitialState() {
        navigationItem.largeTitleDisplayMode = .never
        title = "流式渲染实验室"
        promptField.text = "请用流式方式解释为什么这个架构不卡顿"
        statusLabel.text = "就绪：UIKit + UITextView + 50ms 定时渲染 + 打字机增量"
        updateControlState()
    }

    // MARK: - Actions

    @objc
    private func didTapStart() {
        beginStreaming()
    }

    @objc
    private func didTapStop() {
        stopStreaming(userInitiated: true)
    }

    @objc
    private func didTapClear() {
        stopStreaming(userInitiated: false)
        streamBuffer.clear()
        segmentStore.clear()
        clearVisibleText()
        statusLabel.text = "已清空。"
    }

    // MARK: - Streaming Orchestration

    private func beginStreaming() {
        guard !isStreaming else { return }

        streamGeneration &+= 1
        let generation = streamGeneration
        isStreaming = true
        shouldStickToBottom = true
        streamBuffer.clear()
        segmentStore.clear()
        clearVisibleText()
        updateControlState()

        let prompt = normalizedPrompt(promptField.text)
        let profile = selectedProfile
        statusLabel.text = "流式输出中（UI ≤ 20 次/秒，每帧最多 50 字符）..."

        renderer.start()
        activeStream = streamingService.startStreaming(
            prompt: prompt,
            profile: profile,
            onStreamChunk: { [weak self] chunk in
                self?.streamBuffer.append(chunk)
            },
            onComplete: { [weak self] in
                self?.renderer.markInputCompleted()
            },
            onError: { [weak self] error in
                self?.handleStreamError(error, generation: generation)
            }
        )
    }

    private func stopStreaming(userInitiated: Bool) {
        guard isStreaming || activeStream != nil else { return }

        activeStream?.cancel()
        activeStream = nil
        renderer.cancel(clearBuffer: true)
        isStreaming = false
        updateControlState()

        if userInitiated {
            statusLabel.text = "已停止流式输出。"
        }
    }

    private func handleStreamError(_ error: Error, generation: Int) {
        DispatchQueue.main.async {
            guard generation == self.streamGeneration else { return }
            self.statusLabel.text = "流错误：\(error.localizedDescription)"
            self.renderer.markInputCompleted()
        }
    }

    private func handleRendererDrainComplete() {
        isStreaming = false
        activeStream = nil
        updateControlState()

        let generation = streamGeneration
        let recentMarkdown = segmentStore.recentText(maxCharacters: maxVisibleCharacters, includeDropNotice: true)
        statusLabel.text = "流结束，正在延迟解析 Markdown..."

        markdownQueue.async {
            let rendered = self.markdownPostProcessor.render(
                markdown: recentMarkdown,
                baseFont: self.textFont,
                textColor: .label
            )
            let snapshot = self.segmentStore.snapshot()
            DispatchQueue.main.async {
                guard generation == self.streamGeneration else { return }
                self.applyFinalMarkdown(rendered)
                self.statusLabel.text = "完成：归档 \(snapshot.totalArchivedCharacters) 字符，已省略 \(snapshot.droppedCharacters) 字符"
            }
        }
    }

    // MARK: - Render

    private func appendRenderedDelta(_ delta: String) {
        guard isStreaming, !delta.isEmpty else { return }
        let storage = textView.textStorage
        storage.beginEditing()
        storage.append(NSAttributedString(string: delta, attributes: streamingTextAttributes))
        trimVisibleTextIfNeeded(storage: storage)
        storage.endEditing()
        scrollToBottomIfNeeded(force: false)
    }

    private func applyFinalMarkdown(_ attributed: NSAttributedString) {
        let storage = textView.textStorage
        storage.beginEditing()
        storage.setAttributedString(attributed)
        trimVisibleTextIfNeeded(storage: storage)
        storage.endEditing()
        scrollToBottomIfNeeded(force: true)
    }

    private func clearVisibleText() {
        let storage = textView.textStorage
        storage.beginEditing()
        storage.setAttributedString(NSAttributedString(string: "", attributes: streamingTextAttributes))
        storage.endEditing()
    }

    private func trimVisibleTextIfNeeded(storage: NSTextStorage) {
        let overflow = storage.length - maxVisibleCharacters
        guard overflow > 0 else { return }
        storage.deleteCharacters(in: NSRange(location: 0, length: overflow))
    }

    private func scrollToBottomIfNeeded(force: Bool) {
        guard force || shouldStickToBottom else { return }
        textView.layoutIfNeeded()
        let adjustedTop = -textView.adjustedContentInset.top
        let bottom = max(
            adjustedTop,
            textView.contentSize.height - textView.bounds.height + textView.adjustedContentInset.bottom
        )
        textView.setContentOffset(CGPoint(x: 0, y: bottom), animated: false)
    }

    // MARK: - Helpers

    private func normalizedPrompt(_ raw: String?) -> String {
        let value = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? "请演示流式输出与增量渲染" : value
    }

    private var selectedProfile: MockStreamProfile {
        MockStreamProfile(rawValue: profileControl.selectedSegmentIndex) ?? .standard
    }

    private var streamingTextAttributes: [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 4
        paragraph.paragraphSpacing = 6
        return [
            .font: textFont,
            .foregroundColor: UIColor.label,
            .paragraphStyle: paragraph
        ]
    }

    private func updateControlState() {
        startButton.isEnabled = !isStreaming
        stopButton.isEnabled = isStreaming
        promptField.isEnabled = !isStreaming
        profileControl.isEnabled = !isStreaming

        startButton.alpha = startButton.isEnabled ? 1 : 0.55
        stopButton.alpha = stopButton.isEnabled ? 1 : 0.55
        promptField.alpha = promptField.isEnabled ? 1 : 0.8
        profileControl.alpha = profileControl.isEnabled ? 1 : 0.8
    }

    // MARK: - UITextFieldDelegate

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        beginStreaming()
        return true
    }

    // MARK: - UIScrollViewDelegate

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        shouldStickToBottom = isNearBottom(scrollView: scrollView)
    }

    private func isNearBottom(scrollView: UIScrollView, threshold: CGFloat = 48) -> Bool {
        let maxY = scrollView.contentSize.height - scrollView.bounds.height + scrollView.adjustedContentInset.bottom
        let current = scrollView.contentOffset.y
        return current >= (maxY - threshold)
    }
}
