import AVFoundation
import Virtualization

/// Turns a machine's config into a Virtualization framework configuration.
enum VirtualMachineBuilder {
    /// The virtiofs tag Linux guests mount shared folders from: `mount -t virtiofs hyperbox /mnt/hyperbox`.
    static let sharedFoldersTag = "hyperbox"
    static let rosettaTag = "rosetta"
    /// vsock port the guest agent listens on, for running commands and passing files.
    static let agentPort: UInt32 = 7070

    struct Extras {
        /// Installer media attached as a read-only USB drive.
        var installerISO: URL?
    }

    static func make(_ config: MachineConfig, bundle: MachineBundle, extras: Extras = Extras()) throws -> VZVirtualMachineConfiguration {
        let vm = VZVirtualMachineConfiguration()
        vm.cpuCount = min(max(config.cpuCount, VZVirtualMachineConfiguration.minimumAllowedCPUCount), VZVirtualMachineConfiguration.maximumAllowedCPUCount)
        vm.memorySize = min(max(config.memorySize, VZVirtualMachineConfiguration.minimumAllowedMemorySize), VZVirtualMachineConfiguration.maximumAllowedMemorySize)

        var storage: [VZStorageDeviceConfiguration] = [
            VZVirtioBlockDeviceConfiguration(attachment: try VZDiskImageStorageDeviceAttachment(
                url: bundle.disk, readOnly: false, cachingMode: .automatic, synchronizationMode: .fsync)),
        ]

        switch config.os {
        case .macOS:
            let platform = VZMacPlatformConfiguration()
            guard let model = VZMacHardwareModel(dataRepresentation: try Data(contentsOf: bundle.hardwareModel)) else {
                throw ControlError("The machine's hardware model is damaged.")
            }
            guard model.isSupported else { throw ControlError("This Mac can't run this version of macOS.") }
            platform.hardwareModel = model
            platform.auxiliaryStorage = VZMacAuxiliaryStorage(url: bundle.auxiliaryStorage)
            guard let identifier = VZMacMachineIdentifier(dataRepresentation: try Data(contentsOf: bundle.machineIdentifier)) else {
                throw ControlError("The machine's identifier is damaged.")
            }
            platform.machineIdentifier = identifier
            vm.platform = platform
            vm.bootLoader = VZMacOSBootLoader()

            let graphics = VZMacGraphicsDeviceConfiguration()
            graphics.displays = [VZMacGraphicsDisplayConfiguration(
                widthInPixels: config.display.width, heightInPixels: config.display.height, pixelsPerInch: config.display.pixelsPerInch)]
            vm.graphicsDevices = [graphics]
            vm.keyboards = [VZMacKeyboardConfiguration()]
            vm.pointingDevices = [VZMacTrackpadConfiguration(), VZUSBScreenCoordinatePointingDeviceConfiguration()]

        case .linux:
            let platform = VZGenericPlatformConfiguration()
            if let data = try? Data(contentsOf: bundle.machineIdentifier), let identifier = VZGenericMachineIdentifier(dataRepresentation: data) {
                platform.machineIdentifier = identifier
            } else {
                try platform.machineIdentifier.dataRepresentation.write(to: bundle.machineIdentifier)
            }
            if config.nestedVirtualization, VZGenericPlatformConfiguration.isNestedVirtualizationSupported {
                platform.isNestedVirtualizationEnabled = true
            }
            vm.platform = platform

            let boot = VZEFIBootLoader()
            if FileManager.default.fileExists(atPath: bundle.efiVariables.path) {
                boot.variableStore = VZEFIVariableStore(url: bundle.efiVariables)
            } else {
                boot.variableStore = try VZEFIVariableStore(creatingVariableStoreAt: bundle.efiVariables)
            }
            vm.bootLoader = boot

            let graphics = VZVirtioGraphicsDeviceConfiguration()
            graphics.scanouts = [VZVirtioGraphicsScanoutConfiguration(widthInPixels: config.display.width, heightInPixels: config.display.height)]
            vm.graphicsDevices = [graphics]
            vm.keyboards = [VZUSBKeyboardConfiguration()]
            vm.pointingDevices = [VZUSBScreenCoordinatePointingDeviceConfiguration()]

            // Clipboard sharing, through spice-vdagent in the guest.
            let console = VZVirtioConsoleDeviceConfiguration()
            let port = VZVirtioConsolePortConfiguration()
            port.name = VZSpiceAgentPortAttachment.spiceAgentPortName
            let spice = VZSpiceAgentPortAttachment()
            spice.sharesClipboard = true
            port.attachment = spice
            console.ports[0] = port
            vm.consoleDevices = [console]

            if let iso = extras.installerISO {
                storage.append(VZUSBMassStorageDeviceConfiguration(attachment: try VZDiskImageStorageDeviceAttachment(url: iso, readOnly: true)))
            }
            if FileManager.default.fileExists(atPath: bundle.seed.path) {
                storage.append(VZVirtioBlockDeviceConfiguration(attachment: try VZDiskImageStorageDeviceAttachment(url: bundle.seed, readOnly: true)))
            }
        }
        vm.storageDevices = storage

        if config.network.enabled {
            let network = VZVirtioNetworkDeviceConfiguration()
            network.attachment = VZNATNetworkDeviceAttachment()
            if let mac = VZMACAddress(string: config.network.macAddress) { network.macAddress = mac }
            vm.networkDevices = [network]
        }

        if config.sound {
            let sound = VZVirtioSoundDeviceConfiguration()
            let output = VZVirtioSoundDeviceOutputStreamConfiguration()
            output.sink = VZHostAudioOutputStreamSink()
            var streams: [VZVirtioSoundDeviceStreamConfiguration] = [output]
            if config.microphone {
                let input = VZVirtioSoundDeviceInputStreamConfiguration()
                input.source = VZHostAudioInputStreamSource()
                streams.append(input)
            }
            sound.streams = streams
            vm.audioDevices = [sound]
        }

        vm.directorySharingDevices = directorySharing(config)
        vm.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
        vm.memoryBalloonDevices = [VZVirtioTraditionalMemoryBalloonDeviceConfiguration()]
        vm.socketDevices = [VZVirtioSocketDeviceConfiguration()]
        vm.serialPorts = [serialConsole(bundle)].compactMap { $0 }

        try vm.validate()
        if #available(macOS 14, *) { try vm.validateSaveRestoreSupport() }
        return vm
    }

    /// Shared folders, plus Rosetta for Linux. A share can also be swapped while running; see `share(for:)`.
    static func directorySharing(_ config: MachineConfig) -> [VZDirectorySharingDeviceConfiguration] {
        let tag = config.os == .macOS ? VZVirtioFileSystemDeviceConfiguration.macOSGuestAutomountTag : sharedFoldersTag
        let folders = VZVirtioFileSystemDeviceConfiguration(tag: tag)
        folders.share = share(for: config)
        var devices: [VZDirectorySharingDeviceConfiguration] = [folders]
        if config.os == .linux, config.rosetta, VZLinuxRosettaDirectoryShare.availability == .installed,
           let rosetta = try? VZLinuxRosettaDirectoryShare() {
            let device = VZVirtioFileSystemDeviceConfiguration(tag: rosettaTag)
            device.share = rosetta
            devices.append(device)
        }
        return devices
    }

    /// Always a multiple-directory share, even when empty, so folders can be added while the machine runs.
    static func share(for config: MachineConfig) -> VZDirectoryShare {
        var directories: [String: VZSharedDirectory] = [:]
        for folder in config.sharedFolders {
            var name = folder.name
            var n = 2
            while directories[name] != nil { name = "\(folder.name) \(n)"; n += 1 }
            directories[name] = VZSharedDirectory(url: URL(fileURLWithPath: folder.path), readOnly: folder.readOnly)
        }
        return VZMultipleDirectoryShare(directories: directories)
    }

    private static func serialConsole(_ bundle: MachineBundle) -> VZSerialPortConfiguration? {
        FileManager.default.createFile(atPath: bundle.console.path, contents: nil)
        guard let attachment = try? VZFileSerialPortAttachment(url: bundle.console, append: false) else { return nil }
        let port = VZVirtioConsoleDeviceSerialPortConfiguration()
        port.attachment = attachment
        return port
    }
}
