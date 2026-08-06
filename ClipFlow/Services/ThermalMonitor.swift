//
//  ThermalMonitor.swift
//  ClipFlow
//
//  Surveillance : température, batterie, économie d'énergie, mémoire.
//  La file de rendu consulte ce moniteur entre chaque passage et pendant
//  les rendus longs.
//

import Foundation
import UIKit
import Observation

@MainActor
@Observable
final class ThermalMonitor {

    static let shared = ThermalMonitor()

    private(set) var thermalState: ProcessInfo.ThermalState = ProcessInfo.processInfo.thermalState
    private(set) var isLowPowerMode: Bool = ProcessInfo.processInfo.isLowPowerModeEnabled
    private(set) var batteryLevel: Float = 1.0

    private init() {
        UIDevice.current.isBatteryMonitoringEnabled = true
        batteryLevel = UIDevice.current.batteryLevel

        NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.thermalState = ProcessInfo.processInfo.thermalState
            }
        }
        NotificationCenter.default.addObserver(
            forName: .NSProcessInfoPowerStateDidChange,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.isLowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
            }
        }
        NotificationCenter.default.addObserver(
            forName: UIDevice.batteryLevelDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.batteryLevel = UIDevice.current.batteryLevel
            }
        }
    }

    /// Politique de rendu selon l'état système.
    enum RenderPolicy {
        /// Rendu autorisé normalement.
        case proceed
        /// Rendu autorisé mais avec pause entre chaque passage (état "serious").
        case throttle
        /// Suspendre : température critique ou batterie < 10 % hors charge.
        case pause(reason: String)
    }

    var renderPolicy: RenderPolicy {
        switch thermalState {
        case .critical:
            return .pause(reason: "Température critique — rendu suspendu, il reprendra automatiquement.")
        case .serious:
            return .throttle
        default:
            break
        }
        if batteryLevel >= 0, batteryLevel < 0.10,
           UIDevice.current.batteryState == .unplugged {
            return .pause(reason: "Batterie faible (< 10 %) — branchez l'iPhone pour poursuivre le rendu.")
        }
        return .proceed
    }

    /// Empêche la mise en veille pendant un rendu, puis restaure.
    func setRenderingActive(_ active: Bool) {
        UIApplication.shared.isIdleTimerDisabled = active
    }
}
