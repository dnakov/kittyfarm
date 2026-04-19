import SwiftUI
import AppKit

struct TestScriptView: View {
    @Bindable var store: KittyFarmStore

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            HSplitView {
                editor
                    .frame(minWidth: 280)
                resultsList
                    .frame(minWidth: 220)
            }
        }
        .onAppear {
            prefillBundleIDIfEmpty()
        }
    }

    private var hasIOSDevice: Bool {
        store.activeDevices.contains { $0.descriptor.platform == .iOSSimulator }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            if hasIOSDevice {
                HStack(spacing: 4) {
                    Text("iOS App:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("com.example.app", text: $store.testTargetBundleID)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.caption, design: .monospaced))
                        .frame(width: 220)
                        .help("Bundle identifier of the iOS app to inspect. Leave blank to query SpringBoard. (Android uses whatever's on screen — this field is ignored.)")
                }

                if store.isRunningTest {
                    ProgressView()
                        .controlSize(.small)
                }
            } else if store.isRunningTest {
                ProgressView()
                    .controlSize(.small)
            }

            Spacer()

            syntaxHelpMenu

            Button("Clear Results") {
                withAnimation(.smooth(duration: 0.25)) {
                    store.testResults = []
                    store.testStatusMessage = nil
                }
            }
            .buttonStyle(.glass)
            .controlSize(.small)
            .disabled(store.testResults.isEmpty)

            Button(store.isRunningTest ? "Running..." : "Run") {
                Task { await store.runTestScript() }
            }
            .buttonStyle(.glass)
            .controlSize(.small)
            .disabled(store.isRunningTest || store.activeDevices.isEmpty)
            .keyboardShortcut(.return, modifiers: .command)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.bar)
        .animation(.smooth(duration: 0.2), value: hasIOSDevice)
        .animation(.smooth(duration: 0.2), value: store.isRunningTest)
    }

    private var editor: some View {
        CodeEditor(text: $store.testScript)
            .padding(6)
    }

    private var syntaxHelpMenu: some View {
        Menu {
            Button("tap \"element\"") { insert("tap \"\"") }
            Button("type \"text\" in \"field\"") { insert("type \"\" in \"\"") }
            Button("swipe up/down/left/right") { insert("swipe up") }
            Button("wait for \"element\"") { insert("wait for \"\"") }
            Button("assert visible \"element\"") { insert("assert visible \"\"") }
            Button("assert not visible \"element\"") { insert("assert not visible \"\"") }
            Button("press home") { insert("press home") }
            Button("pause 2") { insert("pause 2") }
            Divider()
            Button("open \"App Name\"") { insert("open \"\"") }
            Button("double tap \"element\"") { insert("double tap \"\"") }
            Button("long press \"element\"") { insert("long press \"\"") }
        } label: {
            Label("Insert", systemImage: "plus.circle")
                .font(.caption)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var resultsList: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let errorMessage = store.testStatusMessage,
               store.testResults.isEmpty,
               !store.isRunningTest {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.title3)
                        .foregroundStyle(.yellow)
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
                .transition(.opacity)
            } else if store.testResults.isEmpty {
                VStack(spacing: 4) {
                    Image(systemName: "checklist")
                        .font(.title3)
                        .foregroundStyle(.tertiary)
                    Text("No results yet")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(store.activeDevices.isEmpty ? "Add a device to run tests" : "Press ⌘↩ to run")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
                .transition(.opacity)
            } else {
                List(Array(store.testResults.enumerated()), id: \.offset) { _, step in
                    HStack(spacing: 8) {
                        Image(systemName: step.status == .passed ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(step.status == .passed ? .green : .red)
                            .font(.system(size: 12))
                            .contentTransition(.symbolEffect(.replace))

                        VStack(alignment: .leading, spacing: 1) {
                            Text(step.action.description)
                                .font(.system(.caption, design: .monospaced))
                                .lineLimit(1)

                            HStack(spacing: 6) {
                                Text(String(format: "%.0fms", step.duration * 1000))
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)

                                if let message = step.message {
                                    Text(message)
                                        .font(.caption2)
                                        .foregroundStyle(.red)
                                        .lineLimit(2)
                                }
                            }
                        }
                    }
                    .listRowInsets(EdgeInsets(top: 3, leading: 8, bottom: 3, trailing: 8))
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .move(edge: .top)),
                        removal: .opacity
                    ))
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .animation(.smooth(duration: 0.25), value: store.testResults.count)

                if let statusMessage = store.testStatusMessage {
                    Divider()
                    Text(statusMessage)
                        .font(.caption)
                        .foregroundStyle(
                            store.testResults.contains(where: { $0.status == .failed })
                                ? .red : .green
                        )
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
        }
        .animation(.smooth(duration: 0.3), value: store.testResults.isEmpty)
        .animation(.smooth(duration: 0.25), value: store.testStatusMessage)
    }

    private func insert(_ text: String) {
        if store.testScript.isEmpty || store.testScript.hasSuffix("\n") {
            store.testScript += text
        } else {
            store.testScript += "\n" + text
        }
    }

    private func prefillBundleIDIfEmpty() {
        // Migrate stale Android-derived value from an earlier bug where we prefilled from Android.
        if let androidID = store.selectedAndroidProject?.applicationID,
           store.testTargetBundleID == androidID {
            store.testTargetBundleID = ""
        }
        guard store.testTargetBundleID.isEmpty else { return }
        // Only prefill from iOS — Android's uiautomator dump ignores the bundle ID.
        if let iosBundleID = store.selectedIOSProject?.bundleIdentifier {
            store.testTargetBundleID = iosBundleID
        }
    }
}

/// Monospaced text editor with smart-quote / dash / spelling corrections disabled.
/// `TextEditor` uses NSTextView under the hood with macOS's substitution settings
/// enabled by default — which mangles `"..."` into `"..."` and breaks the DSL parser.
private struct CodeEditor: NSViewRepresentable {
    @Binding var text: String

    func makeNSView(context: Context) -> NSScrollView {
        let textView = NSTextView()
        textView.delegate = context.coordinator
        textView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.allowsUndo = true
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 4, height: 4)
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.textContainer?.widthTracksTextView = true
        textView.autoresizingMask = [.width]

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false

        textView.string = text
        context.coordinator.textView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = context.coordinator.textView else { return }
        if textView.string != text {
            let selectedRanges = textView.selectedRanges
            textView.string = text
            textView.selectedRanges = selectedRanges
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        private let text: Binding<String>
        weak var textView: NSTextView?

        init(text: Binding<String>) {
            self.text = text
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text.wrappedValue = textView.string
        }
    }
}
