import Virtualization

/// Applies settings that can change while a machine runs: shared folders, the network, port forwards.
enum LiveSettings {
    static func apply(old: MachineConfig, new: MachineConfig, to machine: Machine) {
        guard let vm = machine.virtualMachine else { return }
        if old.sharedFolders != new.sharedFolders {
            let tag = new.os == .macOS ? VZVirtioFileSystemDeviceConfiguration.macOSGuestAutomountTag : VirtualMachineBuilder.sharedFoldersTag
            for device in vm.directorySharingDevices {
                if let device = device as? VZVirtioFileSystemDevice, device.tag == tag {
                    device.share = VirtualMachineBuilder.share(for: new)
                }
            }
        }
    }
}
