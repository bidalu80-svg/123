# iOS Streaming Optimization Log

Last updated: 2026-04-22
Branch: `codex/office-suite-ipa-20260420`

## 1) Goals

This round focused on two core issues:

1. User message should appear immediately after tapping send.
2. Long streaming output should stay smooth and reduce frame drops.

Also improved:

1. More natural streaming fade behavior.
2. Lower cache pressure during long responses.

## 2) What Was Changed

### A. Immediate user-message visibility

- Added local outgoing echo staging before `sendCurrentMessage()`.
- Merged pending local echo into the same history render source (`displayMessages`) instead of relying on extra overlay rows.
- Added reconciliation logic to clear local echo once the real user message arrives.

Main files:

- `ios/App/Sources/ChatScreen.swift`

### B. Streaming smoothness and frame-drop reduction

- Reduced heavy re-layout pressure in text view:
  - Added size caching reuse thresholds based on text length.
  - Reduced expensive per-character color updates for very long text.
- Added adaptive streaming output pacing with character budget.
- Reduced parser cache pressure:
  - Lowered snapshot TTL and count.
  - Added parse-cache trimming under streaming pressure.
- For very long streaming text:
  - Render only tail window during generation.
  - Keep full content after completion.

Main files:

- `ios/App/Sources/SelectableLinkTextView.swift`
- `ios/App/Sources/MessageContentParser.swift`
- `ios/App/Sources/MessageBubbleView.swift`
- `ios/App/Sources/ChatViewModel.swift`

### C. Markdown symbol exposure reduction during streaming

- Streaming text with markdown-like control symbols is routed to parser path earlier.
- Avoided heavy list-decoration transforms during streaming stage to reduce churn.

Main files:

- `ios/App/Sources/MessageBubbleView.swift`
- `ios/App/Sources/MessageContentParser.swift`

## 3) Commit Timeline (this optimization cycle)

1. `d715e99` feat(ios): make streaming smoother and show user messages instantly  
Files:
`ChatScreen.swift`, `ChatService.swift`, `ChatViewModel.swift`, `MessageBubbleView.swift`, `MessageContentParser.swift`, `SelectableLinkTextView.swift`

2. `9a96df9` fix(ios): make streaming segment selection ViewBuilder-compatible  
Files:
`MessageBubbleView.swift`

3. `c53f0ee` fix(ios): improve streaming smoothness and immediate user echo  
Files:
`ChatScreen.swift`, `ChatViewModel.swift`, `MessageBubbleView.swift`, `MessageContentParser.swift`, `SelectableLinkTextView.swift`

4. `83db7c5` fix(ios): render pending user echo in history and reduce long-stream parser load  
Files:
`ChatScreen.swift`, `ChatViewModel.swift`, `MessageContentParser.swift`

5. `25c3e88` perf(ios): harden long-stream rendering and cache pressure control  
Files:
`ChatScreen.swift`, `MessageBubbleView.swift`, `MessageContentParser.swift`, `SelectableLinkTextView.swift`

## 4) Build / IPA Records

1. Run: https://github.com/bidalu80-svg/123/actions/runs/24774013530  
Result: success  
Artifact: `chatapp-ipa`  
Artifact ID: `6576193668`

2. Run: https://github.com/bidalu80-svg/123/actions/runs/24774642939  
Result: success  
Artifact: `chatapp-ipa`  
Artifact ID: `6576456868`

3. Run: https://github.com/bidalu80-svg/123/actions/runs/24775179032  
Result: success  
Artifact: `chatapp-ipa`  
Artifact ID: `6576715780`

4. Run: https://github.com/bidalu80-svg/123/actions/runs/24776080191  
Result: success  
Artifact: `chatapp-ipa`  
Artifact ID: `6577080913`

## 5) Repro / Verification Checklist

After installing IPA, verify in this order:

1. Send a short text: user bubble appears immediately.
2. Send a long prompt (very long answer): no obvious freeze while streaming.
3. During long streaming: app remains responsive when scrolling.
4. End of streaming: final text formatting is correct.
5. Code blocks: still auto-follow tail while generating, manual scroll after completion.

## 6) Next-Step Playbook (if still lagging)

If frame drops still happen, continue with these in order:

1. Add segmented frozen rendering for old paragraphs (only active tail remains mutable).
2. Move markdown parse to background staged pipeline and commit UI-ready blocks in batches.
3. Disable per-char fade on low-power / thermal states automatically.
4. Add telemetry counters (render cost, parse cost, dropped-frame estimate) for tuning by data.

## 7) Useful Commands

Build IPA (current branch, wait result):

```bat
build_ipa_action.bat codex/office-suite-ipa-20260420 -Wait
```

Trigger workflow directly:

```powershell
powershell -ExecutionPolicy Bypass -File .\trigger_ipa_build.ps1 `
  -Branch codex/office-suite-ipa-20260420 `
  -Workflow build-ios-ipa.yml `
  -NoAutoSync `
  -Wait
```

