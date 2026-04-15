import AppKit
import SwiftUI

struct ProjectPickerSheet: View {
    @Bindable var store: KittyFarmStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("iOS App") {
                    LabeledContent("Project") {
                        Text(store.selectedIOSProject?.projectPath ?? "Not selected")
                            .font(.caption.monospaced())
                            .foregroundStyle(store.selectedIOSProject == nil ? .secondary : .primary)
                            .textSelection(.enabled)
                    }

                    TextField(
                        "Scheme",
                        text: Binding(
                            get: { store.selectedIOSProject?.scheme ?? "" },
                            set: { store.updateIOSScheme($0) }
                        )
                    )
                    .disabled(store.selectedIOSProject == nil)

                    HStack {
                        Button("Choose…") {
                            chooseIOSProject()
                        }

                        if store.selectedIOSProject != nil {
                            Button("Clear", role: .destructive) {
                                store.clearIOSProject()
                            }
                        }
                    }
                }

                Section("Android App") {
                    LabeledContent("Project") {
                        Text(store.selectedAndroidProject?.projectDirectoryPath ?? "Not selected")
                            .font(.caption.monospaced())
                            .foregroundStyle(store.selectedAndroidProject == nil ? .secondary : .primary)
                            .textSelection(.enabled)
                    }

                    TextField(
                        "Application ID",
                        text: Binding(
                            get: { store.selectedAndroidProject?.applicationID ?? "" },
                            set: { store.updateAndroidApplicationID($0) }
                        )
                    )
                    .disabled(store.selectedAndroidProject == nil)

                    TextField(
                        "Gradle Task",
                        text: Binding(
                            get: { store.selectedAndroidProject?.gradleTask ?? "" },
                            set: { store.updateAndroidGradleTask($0) }
                        )
                    )
                    .disabled(store.selectedAndroidProject == nil)

                    HStack {
                        Button("Choose…") {
                            chooseAndroidProject()
                        }

                        if store.selectedAndroidProject != nil {
                            Button("Clear", role: .destructive) {
                                store.clearAndroidProject()
                            }
                        }
                    }
                }

                Section("Behavior") {
                    Text("Build & Play uses the selected iOS project for active iOS simulator tiles and the selected Android project for active Android emulator tiles.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Projects")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        dismiss()
                    }
                }
            }
        }
    }

    private func chooseIOSProject() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose iOS Project"
        panel.message = "Choose an .xcodeproj, .xcworkspace, or a folder that contains one."

        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            await store.selectIOSProject(at: url)
        }
    }

    private func chooseAndroidProject() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose Android Project"
        panel.message = "Choose a Gradle project folder, gradlew, or a file inside the Android project."

        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            await store.selectAndroidProject(at: url)
        }
    }
}
