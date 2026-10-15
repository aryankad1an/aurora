import SwiftUI
import UniformTypeIdentifiers

/// Settings → Export Data: everything the database holds for this account,
/// saved to a place on the device the user picks (Files, iCloud Drive, a USB
/// drive). Reads the database first and shows what's in it, so what's about to
/// be saved is known before the file picker opens.
struct DataExportView: View {
    @Environment(JobStore.self) private var jobStore
    @Environment(\.dismiss) private var dismiss

    @State private var format = ExportFormat.json
    @State private var snapshot: DataExport?
    @State private var loadError: String?
    @State private var document: ExportDocument?
    @State private var isPreparing = false
    @State private var isPickingPlace = false
    @State private var savedName: String?
    @State private var saveError: String?
    /// The finished save, said out loud: the footer line alone sat under the
    /// button, out of sight once the file picker closed.
    @State private var savedMessage: String?

    enum ExportFormat: String, CaseIterable, Hashable {
        case json, csv

        var title: String {
            switch self {
            case .json: "JSON"
            case .csv: "Spreadsheets"
            }
        }

        var detail: String {
            switch self {
            case .json: "One file with every table, every column. Best for keeping a backup or loading into another tool."
            case .csv: "A .zip of CSV files, one per table — opens in Numbers, Excel or Google Sheets."
            }
        }

        var contentType: UTType { self == .json ? .json : .zip }
    }

    var body: some View {
        NavigationStack {
            PaperForm {
                Section {
                    HStack(spacing: 14) {
                        IconTile(systemImage: "square.and.arrow.down.on.square.fill", tint: .clay, size: 52)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Export your data")
                                .displayFont(20)
                                .foregroundStyle(.ink)
                            Text("A copy of the database, saved where you choose. Nothing is changed or deleted.")
                                .font(.caption)
                                .foregroundStyle(.inkMuted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section {
                    if let snapshot {
                        ForEach(snapshot.summary, id: \.label) { item in
                            LabeledContent(item.label) {
                                Text(item.count.formatted())
                                    .monospacedDigit()
                                    .foregroundStyle(.ink)
                            }
                        }
                    } else if let loadError {
                        Label(loadError, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(Color.danger)
                        Button("Try Again", systemImage: "arrow.clockwise") {
                            Task { await gather() }
                        }
                    } else {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Reading the database…")
                                .foregroundStyle(.inkMuted)
                        }
                    }
                } header: {
                    Text("What's included")
                } footer: {
                    Text("The shared catalog — companies, their contacts and hiring sources — and your own sent mails, templates, profile and Home list. Other people's mail and templates aren't included.")
                }

                Section {
                    Picker("Format", selection: $format) {
                        ForEach(ExportFormat.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
                } footer: {
                    Text(format.detail)
                }

                Section {
                    Button {
                        prepare()
                    } label: {
                        HStack {
                            Spacer()
                            if isPreparing {
                                ProgressView().tint(.white)
                            } else {
                                Label("Choose Where to Save…", systemImage: "folder.badge.plus")
                                    .font(.body.weight(.semibold))
                            }
                            Spacer()
                        }
                        .padding(.vertical, 4)
                    }
                    .filledButton()
                    .disabled(snapshot == nil || isPreparing)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                } footer: {
                    if let savedName {
                        Label("Saved “\(savedName)”.", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(Color.statusDone)
                    } else if let saveError {
                        Text(saveError).foregroundStyle(Color.danger)
                    }
                }
            }
            .navigationTitle("Export Data")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await gather() }
            .messageAlert("Export Saved", message: savedMessage) { savedMessage = nil }
            .onChange(of: format) {
                savedName = nil
                saveError = nil
            }
            .fileExporter(isPresented: $isPickingPlace, document: document,
                          contentType: format.contentType,
                          defaultFilename: snapshot.map { $0.baseFilename } ?? "Aurora export") { result in
                switch result {
                case .success(let url):
                    Haptics.success()
                    savedName = url.lastPathComponent
                    saveError = nil
                    // The file's name only: the picker's URL names the folder
                    // by its internal name ("File Provider Storage" for On My
                    // iPhone), not the one the user just picked.
                    savedMessage = "“\(url.lastPathComponent)” was saved where you chose."
                case .failure(let error):
                    // Cancelling the picker isn't a failure worth a word.
                    if (error as NSError).code != NSUserCancelledError {
                        Haptics.failure()
                        saveError = error.localizedDescription
                    }
                }
            }
        }
    }

    private func gather() async {
        loadError = nil
        do {
            snapshot = try await jobStore.exportSnapshot()
        } catch {
            if !error.isCancellation { loadError = error.localizedDescription }
        }
    }

    /// Build the file, then let the user pick where it goes.
    private func prepare() {
        guard let snapshot else { return }
        Haptics.tap()
        isPreparing = true
        savedName = nil
        saveError = nil
        let format = format
        Task {
            do {
                let data: Data
                switch format {
                case .json:
                    data = try snapshot.json()
                case .csv:
                    let files = snapshot.csvFiles()
                    let folder = snapshot.baseFilename
                    data = try await Task.detached(priority: .userInitiated) {
                        try ExportDocument.zip(files, folderName: folder)
                    }.value
                }
                document = ExportDocument(data: data)
                isPreparing = false
                isPickingPlace = true
            } catch {
                isPreparing = false
                Haptics.failure()
                saveError = "The export couldn't be put together: \(error.localizedDescription)"
            }
        }
    }
}

/// The finished export, as the file picker saves it.
nonisolated struct ExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json, .zip] }

    let data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }

    /// `files` in a folder called `folderName`, zipped. The system zips a
    /// folder itself when one is read "for uploading", so no archive code is
    /// needed here.
    static func zip(_ files: [String: Data], folderName: String) throws -> Data {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let folder = root.appendingPathComponent(folderName, isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        for (name, data) in files {
            try data.write(to: folder.appendingPathComponent(name), options: .atomic)
        }
        var coordinatorError: NSError?
        var zipped: Result<Data, Error>?
        NSFileCoordinator().coordinate(readingItemAt: folder, options: .forUploading, error: &coordinatorError) { url in
            zipped = Result { try Data(contentsOf: url) }
        }
        if let coordinatorError { throw coordinatorError }
        guard let zipped else { throw CocoaError(.fileReadUnknown) }
        return try zipped.get()
    }
}
