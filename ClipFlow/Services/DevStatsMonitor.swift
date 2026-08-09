//
//  DevStatsMonitor.swift
//  ClipFlow
//
//  Statistiques développeur en continu : état thermique, mémoire de l'app,
//  mémoire disponible, CPU de l'app. iOS n'expose AUCUNE API publique de
//  charge GPU — affiché comme tel plutôt que d'inventer un chiffre.
//

import Foundation
import UIKit
import Observation
import os

@MainActor
@Observable
final class DevStatsMonitor {

    static let shared = DevStatsMonitor()

    private(set) var thermal: ProcessInfo.ThermalState = .nominal
    private(set) var footprintMB: Double = 0
    private(set) var availableMB: Double = 0
    private(set) var cpuPercent: Double = 0

    private var timer: Timer?
    private init() {}

    var thermalLabel: String {
        switch thermal {
        case .nominal: return "nominale"
        case .fair: return "modérée"
        case .serious: return "élevée"
        case .critical: return "CRITIQUE"
        @unknown default: return "?"
        }
    }

    func start() {
        guard timer == nil else { return }
        tick()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            Task { @MainActor in DevStatsMonitor.shared.tick() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        thermal = ProcessInfo.processInfo.thermalState
        footprintMB = Self.memoryFootprintBytes() / 1_000_000
        availableMB = Double(os_proc_available_memory()) / 1_000_000
        cpuPercent = Self.appCPUPercent()
    }

    /// Empreinte mémoire réelle de l'app (phys_footprint — la métrique jetsam).
    nonisolated private static func memoryFootprintBytes() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Double(info.phys_footprint) : 0
    }

    /// CPU de l'app (somme des threads, 100 % = un cœur saturé).
    nonisolated private static func appCPUPercent() -> Double {
        var threadList: thread_act_array_t?
        var threadCount = mach_msg_type_number_t(0)
        guard task_threads(mach_task_self_, &threadList, &threadCount) == KERN_SUCCESS,
              let threads = threadList else { return 0 }
        defer {
            vm_deallocate(
                mach_task_self_,
                vm_address_t(UInt(bitPattern: threads)),
                vm_size_t(Int(threadCount) * MemoryLayout<thread_t>.stride)
            )
        }
        var total: Double = 0
        for index in 0..<Int(threadCount) {
            var info = thread_basic_info()
            var infoCount = mach_msg_type_number_t(THREAD_INFO_MAX)
            let result = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(infoCount)) {
                    thread_info(threads[index], thread_flavor_t(THREAD_BASIC_INFO), $0, &infoCount)
                }
            }
            if result == KERN_SUCCESS, info.flags & TH_FLAGS_IDLE == 0 {
                total += Double(info.cpu_usage) / Double(TH_USAGE_SCALE) * 100
            }
        }
        return total
    }
}

/// Panneau flottant des stats — verre, monospace, mise à jour 1 Hz.
struct DevStatsOverlay: View {
    let stats: DevStatsMonitor

    private var thermalColor: Color {
        switch stats.thermal {
        case .nominal: return .green
        case .fair: return .yellow
        case .serious: return .orange
        case .critical: return .red
        @unknown default: return .gray
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Circle().fill(thermalColor).frame(width: 7, height: 7)
                Text("Temp. \(stats.thermalLabel)")
            }
            Text(String(format: "RAM app %.0f Mo", stats.footprintMB))
            Text(String(format: "RAM dispo %.0f Mo", stats.availableMB))
            Text(String(format: "CPU %.0f %%", stats.cpuPercent))
            Text("GPU non exposé (iOS)")
                .foregroundStyle(.secondary)
        }
        .font(.caption2.monospaced())
        .padding(10)
        .glassEffect(in: RoundedRectangle(cornerRadius: 12))
        .allowsHitTesting(false)
    }
}
