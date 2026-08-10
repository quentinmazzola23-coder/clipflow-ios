//
//  ClipFlowWidgetsBundle.swift
//  ClipFlowWidgets
//
//  Point d'entrée de l'extension : uniquement la Live Activity d'export.
//

import WidgetKit
import SwiftUI

@main
struct ClipFlowWidgetsBundle: WidgetBundle {
    var body: some Widget {
        ExportLiveActivity()
    }
}
