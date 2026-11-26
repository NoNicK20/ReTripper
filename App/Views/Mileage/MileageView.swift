//
//  MileageView.swift
//  ReTripper
//
//  Fuel & mileage log. Replaces the old fuel-refill action: record fills
//  (odometer, petrol price, litres, total ₹, full-tank) and see tank-to-tank
//  mileage worked out automatically.
//

import SwiftUI
import UniformTypeIdentifiers

struct MileageView: View {
    @EnvironmentObject private var dataManager: DataManager
    @State private var showingEntrySheet = false
    @State private var editingFill: FuelLog?

    // Import / export / backup
    @State private var showCSVImporter = false
    @State private var showCSVExporter = false
    @State private var showBackupImporter = false
    @State private var showBackupExporter = false
    @State private var csvExportText = ""
    @State private var backupData = Data()
    @State private var transferMessage: String?
    @State private var pendingRestore: Data?

    private let dateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .none
        return df
    }()

    private var unit: String { dataManager.distanceUnit.shortLabel }
    private var economyUnit: String { "\(unit)/L" }

    private var intervalsByFill: [UUID: FuelMileage.Interval] {
        Dictionary(uniqueKeysWithValues: FuelMileage.intervals(from: dataManager.fuelLogs).map { ($0.fillID, $0) })
    }

    private var latestEconomy: Double? { FuelMileage.latest(from: dataManager.fuelLogs)?.economy }
    private var averageEconomy: Double? { FuelMileage.average(from: dataManager.fuelLogs) }
    private var totalLiters: Double { dataManager.fuelLogs.reduce(0) { $0 + $1.liters } }
    private var totalSpent: Double { dataManager.fuelLogs.reduce(0) { $0 + $1.totalCost } }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 14) {
                        header

                        // Mileage summary
                        VStack(alignment: .leading, spacing: 12) {
                            Text("TANK-TO-TANK MILEAGE")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundColor(Theme.textTertiary)
                                .tracking(1.2)

                            HStack(spacing: 10) {
                                StatBox(
                                    title: "LATEST",
                                    value: latestEconomy.map { String(format: "%.1f", $0) } ?? "—",
                                    caption: economyUnit
                                )
                                StatBox(
                                    title: "AVERAGE",
                                    value: averageEconomy.map { String(format: "%.1f", $0) } ?? "—",
                                    caption: economyUnit
                                )
                                StatBox(
                                    title: "TOTAL FUEL",
                                    value: String(format: "%.1f", totalLiters),
                                    caption: "litres"
                                )
                            }

                            if latestEconomy == nil {
                                Text("Record at least two full-tank fills to see mileage.")
                                    .font(.system(size: 11))
                                    .foregroundColor(Theme.textTertiary)
                            }
                        }
                        .darkCard(padding: 14)

                        // Fill history or empty state
                        if dataManager.fuelLogs.isEmpty {
                            emptyState
                        } else {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("FILL HISTORY")
                                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                                    .foregroundColor(Theme.textTertiary)
                                    .tracking(1.2)

                                Text("Tap a fill to edit it, or swipe left to delete.")
                                    .font(.system(size: 11))
                                    .foregroundColor(Theme.textTertiary)

                                ForEach(dataManager.fuelLogs) { fill in
                                    SwipeToDeleteRow(cornerRadius: Theme.smallCornerRadius) {
                                        dataManager.deleteFuelLog(id: fill.id)
                                    } content: {
                                        Button { editingFill = fill } label: {
                                            FuelFillCard(
                                                fill: fill,
                                                unit: unit,
                                                economyUnit: economyUnit,
                                                economy: intervalsByFill[fill.id]?.economy,
                                                dateString: dateFormatter.string(from: fill.date)
                                            )
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 32)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $showingEntrySheet) {
                MileageEntrySheet()
            }
            .sheet(item: $editingFill) { fill in
                MileageEntrySheet(editing: fill)
            }
            .fileImporter(isPresented: $showCSVImporter,
                          allowedContentTypes: [.commaSeparatedText, .plainText, .text],
                          allowsMultipleSelection: false) { result in
                handleCSVImport(result)
            }
            .fileExporter(isPresented: $showCSVExporter,
                          document: MileageCSVDocument(text: csvExportText),
                          contentType: .commaSeparatedText,
                          defaultFilename: "ReTripper-Mileage") { _ in }
            .fileExporter(isPresented: $showBackupExporter,
                          document: BackupDocument(data: backupData),
                          contentType: .json,
                          defaultFilename: backupFilename) { _ in }
            .fileImporter(isPresented: $showBackupImporter,
                          allowedContentTypes: [.json],
                          allowsMultipleSelection: false) { result in
                handleBackupPick(result)
            }
            .alert("Restore backup?", isPresented: Binding(get: { pendingRestore != nil },
                                                           set: { if !$0 { pendingRestore = nil } })) {
                Button("Cancel", role: .cancel) { pendingRestore = nil }
                Button("Replace all data", role: .destructive) {
                    if let data = pendingRestore, dataManager.restoreBackup(from: data) {
                        transferMessage = "Backup restored."
                    } else {
                        transferMessage = "That file couldn't be read as a ReTripper backup."
                    }
                    pendingRestore = nil
                }
            } message: {
                Text("This replaces all current fills, service records, rides and your bike profile with the backup's contents. It can't be undone.")
            }
            .alert("Import & backup",
                   isPresented: Binding(get: { transferMessage != nil }, set: { if !$0 { transferMessage = nil } })) {
                Button("OK", role: .cancel) { transferMessage = nil }
            } message: {
                Text(transferMessage ?? "")
            }
        }
    }

    private func handleCSVImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let text = try String(contentsOf: url, encoding: .utf8)
                let outcome = dataManager.importFuelCSV(text)
                if outcome.imported == 0 && outcome.skipped == 0 {
                    transferMessage = "No fuel fills were found in that file."
                } else {
                    transferMessage = "Imported \(outcome.imported) fill\(outcome.imported == 1 ? "" : "s")"
                        + (outcome.skipped > 0 ? ", skipped \(outcome.skipped) already in your log." : ".")
                }
            } catch {
                transferMessage = "Couldn't read that file: \(error.localizedDescription)"
            }
        case .failure(let error):
            transferMessage = "Import cancelled: \(error.localizedDescription)"
        }
    }

    private func handleBackupPick(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            if let data = try? Data(contentsOf: url) {
                pendingRestore = data
            } else {
                transferMessage = "Couldn't read that backup file."
            }
        case .failure(let error):
            transferMessage = "Restore cancelled: \(error.localizedDescription)"
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("MILEAGE")
                    .font(.system(size: 22, weight: .black, design: .rounded))
                    .foregroundColor(Theme.textPrimary)
                Text("FUEL & ECONOMY LOG")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(Theme.textTertiary)
                    .tracking(1.2)
            }
            Spacer()
            dataMenu
            Button(action: { showingEntrySheet = true }) {
                HStack(spacing: 5) {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .bold))
                    Text("Add Fill")
                        .font(.system(size: 13, weight: .bold))
                }
                .foregroundColor(Theme.textPrimary)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Theme.apexRed)
                .clipShape(Capsule())
            }
        }
        .padding(.top, 8)
    }

    private var dataMenu: some View {
        Menu {
            Section("Mileage (CSV)") {
                Button { showCSVImporter = true } label: { Label("Import from CSV", systemImage: "square.and.arrow.down") }
                Button {
                    csvExportText = dataManager.fuelLogsCSV()
                    showCSVExporter = true
                } label: { Label("Export to CSV", systemImage: "square.and.arrow.up") }
                .disabled(dataManager.fuelLogs.isEmpty)
            }
            Section("All app data") {
                Button {
                    backupData = dataManager.backupData() ?? Data()
                    showBackupExporter = true
                } label: { Label("Save backup file", systemImage: "externaldrive.badge.plus") }
                Button(role: .destructive) { showBackupImporter = true } label: {
                    Label("Restore from backup", systemImage: "arrow.counterclockwise")
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 20, weight: .semibold))
                .foregroundColor(Theme.textSecondary)
                .frame(width: 36, height: 36)
        }
        .accessibilityLabel("Import, export and backup")
    }

    private var backupFilename: String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd-HHmm"
        return "ReTripper-Backup-\(df.string(from: Date()))"
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(Theme.surfaceSecondary)
                    .frame(width: 64, height: 64)
                Image(systemName: "fuelpump.fill")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundColor(Theme.apexRed)
            }
            VStack(spacing: 6) {
                Text("No fills logged yet")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(Theme.textPrimary)
                Text("Log each refuel with the odometer and petrol price. After two full-tank fills, ReTripper shows your real mileage.")
                    .font(.system(size: 13))
                    .foregroundColor(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
            }
            Button(action: { showingEntrySheet = true }) {
                HStack(spacing: 6) {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 14, weight: .bold))
                    Text("Log First Fill")
                        .font(.system(size: 14, weight: .bold))
                }
                .foregroundColor(Theme.textPrimary)
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .background(Theme.apexRed)
                .clipShape(Capsule())
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
        .darkCard(padding: 16)
    }
}

struct FuelFillCard: View {
    let fill: FuelLog
    let unit: String
    let economyUnit: String
    let economy: Double?
    let dateString: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(String(format: "%.2f L", fill.liters))
                            .font(.system(size: 16, weight: .bold))
                            .foregroundColor(Theme.textPrimary)
                        if fill.isFullTank {
                            Text("FULL")
                                .font(.system(size: 8, weight: .black, design: .monospaced))
                                .foregroundColor(Theme.apexRed)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Theme.apexRed.opacity(0.15))
                                .clipShape(Capsule())
                        }
                    }
                    Text(dateString)
                        .font(.system(size: 11))
                        .foregroundColor(Theme.textTertiary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(String(format: "₹%.2f", fill.totalCost))
                        .font(.system(size: 16, weight: .heavy, design: .rounded))
                        .foregroundColor(Theme.apexRed)
                    if let price = fill.pricePerLiter, price > 0 {
                        Text(String(format: "₹%.2f/L", price))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(Theme.textSecondary)
                    }
                }
            }

            HStack(spacing: 12) {
                Text(String(format: "Odo %.0f %@", fill.odometer, unit))
                if let economy, economy > 0 {
                    Text(String(format: "%.1f %@", economy, economyUnit))
                        .foregroundColor(Theme.apexRed)
                }
            }
            .font(.system(size: 11, design: .monospaced))
            .foregroundColor(Theme.textSecondary)

            if !fill.notes.isEmpty {
                Text(fill.notes)
                    .font(.system(size: 12))
                    .foregroundColor(Theme.textSecondary)
            }
        }
        .padding(14)
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: Theme.smallCornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.smallCornerRadius, style: .continuous)
                .stroke(Theme.borderSubtle, lineWidth: 0.8)
        )
    }
}

#Preview {
    MileageView()
        .environmentObject(DataManager.shared)
}
