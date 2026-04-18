//
//  VMDisplayView.swift
//  Apus
//

import SwiftUI
import Virtualization

/// 将 VZVirtualMachineView 包装为 SwiftUI 视图
struct VMDisplayView: NSViewRepresentable {
    let virtualMachine: VZVirtualMachine

    func makeNSView(context: Context) -> VZVirtualMachineView {
        let view = VZVirtualMachineView()
        view.virtualMachine = virtualMachine
        view.capturesSystemKeys = true
        view.automaticallyReconfiguresDisplay = true
        return view
    }

    func updateNSView(_ nsView: VZVirtualMachineView, context: Context) {
        nsView.virtualMachine = virtualMachine
    }
}
