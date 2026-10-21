import AppKit
import Virtualization

/// Gets a new macOS machine from the installer to a desktop with Hyperbox Tools running, without a click.
///
/// macOS 27 guests set themselves up from `VZMacGuestProvisioningOptions` on their first boot: they make
/// the user in `config.guestUser`, skip Setup Assistant, log in, and turn on Remote Login. Hyperbox then
/// signs in over SSH, runs `Install Hyperbox Tools.command` from the shared folder, and turns Remote
/// Login off again: from then on the agent does everything SSH could. Older guests show
/// Setup Assistant as usual, and Hyperbox Tools installs with a double-click.
enum MacSetup {
    /// A user like the one on the Mac, with a password of its own (shown in the machine's settings).
    static func newGuestUser() -> MachineConfig.GuestUser {
        let name = NSUserName().lowercased().filter { $0.isLetter || $0.isNumber }
        // No look-alike characters, so it can be read off the screen and typed.
        let alphabet = Array("abcdefghjkmnpqrstuvwxyz23456789")
        let groups = (0..<3).map { _ in String((0..<4).map { _ in alphabet.randomElement()! }) }
        return .init(name: name.isEmpty ? "hyperbox" : name, password: groups.joined(separator: "-"))
    }

    /// How to start a macOS machine: with the guest user to create, the first time.
    static func startOptions(for config: MachineConfig) -> VZMacOSVirtualMachineStartOptions? {
        guard config.os == .macOS, let user = config.guestUser else { return nil }
        guard #available(macOS 27, *) else { return nil }
        let provisioning = VZMacGuestProvisioningOptions()
        provisioning.fullName = NSFullUserName().isEmpty ? user.name : NSFullUserName()
        provisioning.username = user.name
        provisioning.password = user.password
        provisioning.logsInAutomatically = true
        provisioning.enablesRemoteLogin = true
        let options = VZMacOSVirtualMachineStartOptions()
        // A guest already set up ignores these, so passing them on every boot is harmless, and still
        // works if the first boot was cut short.
        do { try options.setGuestProvisioning(provisioning) } catch { return nil }
        return options
    }

    /// Once the machine is up, installs Hyperbox Tools over SSH if its agent doesn't answer yet.
    static func installToolsWhenReady(_ machine: Machine) {
        guard machine.config.os == .macOS, let user = machine.config.guestUser, HyperboxTools.folder != nil else { return }
        Task {
            // The first boot takes a few minutes to make the user and log in.
            let deadline = Date.now.addingTimeInterval(15 * 60)
            var installed = false
            while Date.now < deadline, machine.state == .running || machine.state == .installing {
                if await GuestAgent.ping(machine) != nil {
                    if installed { await turnOffRemoteLogin(machine) }
                    return
                }
                if !installed, let address = machine.ipAddress ?? DHCPLeases.address(for: machine.config.network.macAddress) {
                    installed = (try? await install(at: address, user: user)) != nil
                }
                // launchd takes a moment to start the agent.
                try? await Task.sleep(for: .seconds(installed ? 2 : 10))
            }
        }
    }

    /// Remote Login was only for installing Hyperbox Tools, and an SSH server that takes a password is
    /// best left off unless you want it; System Settings › General › Sharing turns it back on.
    private static func turnOffRemoteLogin(_ machine: Machine) async {
        let command = "launchctl disable system/com.openssh.sshd && { launchctl bootout system/com.openssh.sshd 2>/dev/null; true; }"
        // The administrator helper has only just started, so give it a few tries.
        for _ in 0..<10 {
            let reply = try? await GuestAgent.request(["op": "exec", "command": .string(command), "admin": true, "timeout": 30], machine: machine, timeout: 35)
            if reply?["exitCode"]?.int == 0 { return }
            try? await Task.sleep(for: .seconds(2))
        }
    }

    /// Runs the installer from the shared folder over SSH, as the guest user, administrator helper included.
    private static func install(at address: String, user: MachineConfig.GuestUser) async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "hyperbox-ssh-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        // ssh asks this script for the password instead of a terminal.
        let askpass = folder.appending(path: "askpass")
        try "#!/bin/sh\ncat \"$(dirname \"$0\")/password\"\n".write(to: askpass, atomically: true, encoding: .utf8)
        try user.password.write(to: folder.appending(path: "password"), atomically: true, encoding: .utf8)
        chmod(askpass.path, 0o700)
        chmod(folder.appending(path: "password").path, 0o600)

        // The guest reads the password from standard input for sudo, so it never shows in a command line.
        let script = """
            set -e
            t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
            cat > "$t/password"; printf '#!/bin/sh\\ncat "%s/password"\\n' "$t" > "$t/askpass"; chmod 700 "$t/askpass"
            SUDO_ASKPASS="$t/askpass" "\(HyperboxTools.guestPath)/\(HyperboxTools.installer)" --admin
            """
        let arguments = [
            "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null", "-o", "LogLevel=ERROR",
            "-o", "PubkeyAuthentication=no", "-o", "PreferredAuthentications=keyboard-interactive,password",
            "-o", "ConnectTimeout=5", "-o", "NumberOfPasswordPrompts=1",
            "\(user.name)@\(address)", script,
        ]
        let environment = ["SSH_ASKPASS": askpass.path, "SSH_ASKPASS_REQUIRE": "force", "DISPLAY": ":0"]
        let password = user.password
        try await Task.detached { try ssh(arguments, environment: environment, input: Data(password.utf8)) }.value
    }

    private nonisolated static func ssh(_ arguments: [String], environment: [String: String], input: Data) throws {
        let process = Process(), stdin = Pipe(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 }
        process.standardInput = stdin
        process.standardOutput = output
        process.standardError = output
        try process.run()
        try stdin.fileHandleForWriting.write(contentsOf: input)
        try stdin.fileHandleForWriting.close()
        let printed = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ControlError("Installing Hyperbox Tools over SSH failed: \(String(decoding: printed, as: UTF8.self))")
        }
    }
}
