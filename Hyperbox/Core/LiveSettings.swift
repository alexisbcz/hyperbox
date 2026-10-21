import Virtualization

/// Applies settings that can change while a machine runs: the name, shared folders, the network, port forwards.
/// Everything else in the config waits for the next boot.
enum LiveSettings {
    static func apply(old: MachineConfig, new: MachineConfig, to machine: Machine) {
        // The name needs nothing here: the window title follows `config`, and the library rereads config.json.
        defer { machine.network.update() }
        guard let vm = machine.virtualMachine else { return }
        if old.sharedFolders != new.sharedFolders {
            let tag = new.os == .macOS ? VZVirtioFileSystemDeviceConfiguration.macOSGuestAutomountTag : VirtualMachineBuilder.sharedFoldersTag
            for device in vm.directorySharingDevices {
                if let device = device as? VZVirtioFileSystemDevice, device.tag == tag {
                    device.share = VirtualMachineBuilder.share(for: new)
                }
            }
        }
        // Like pulling the cable out and plugging it back in: the guest sees the link go down, then asks DHCP again.
        if old.network.enabled != new.network.enabled, let device = vm.networkDevices.first {
            device.attachment = new.network.enabled ? VZNATNetworkDeviceAttachment() : nil
        }
    }
}
