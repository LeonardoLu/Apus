//
//  VMDelegateHandler.swift
//  Apus
//

import Foundation
import Virtualization

// MARK: - VZ 虚拟机代理

class VMDelegateHandler: NSObject, VZVirtualMachineDelegate {
    let instanceID: UUID
    weak var manager: VMManager?

    init(instanceID: UUID, manager: VMManager) {
        self.instanceID = instanceID
        self.manager = manager
    }

    func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        AppLog.log("[VZ 代理] didStopWithError id=\(instanceID): \(error.localizedDescription)")
        manager?.handleVMError(instanceID: instanceID, error: error)
    }

    func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        AppLog.log("[VZ 代理] guestDidStop id=\(instanceID)")
        manager?.handleGuestStopped(instanceID: instanceID)
    }
}
