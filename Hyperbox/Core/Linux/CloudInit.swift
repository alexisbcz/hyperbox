import Carbon
import Foundation

/// The cloud-init seed that turns a distribution's cloud image into a desktop on first boot.
///
/// cloud-init finds it as a disk labelled `cidata` (its NoCloud source) holding `meta-data` and
/// `user-data`. The user-data creates the user and installs Hyperbox's guest agent and the
/// `hyperbox-setup` service, which installs the desktop and reboots into it. The setup is a service
/// rather than a cloud-init `runcmd` because cloud-init runs those once even when the Mac quits halfway:
/// the service runs again each boot until it has finished. Progress shows in console.log, which
/// `LinuxGuest` reads, and the agent reports the install done once the guest has rebooted.
enum CloudInit {
    /// Where the guest agent keeps its files, and the setup leaves its marks.
    static let agentPath = "/usr/local/libexec/hyperbox/agent.py"

    static func makeSeed(for config: MachineConfig, distribution: LinuxDistribution, at url: URL) async throws {
        guard let user = config.guestUser else { throw ControlError("The machine has no guest user.") }
        let folder = FileManager.default.temporaryDirectory.appending(path: "hyperbox-seed-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let hostname = hostname(for: config)
        try "instance-id: \(config.id.uuidString.lowercased())\nlocal-hostname: \(hostname)\n"
            .write(to: folder.appending(path: "meta-data"), atomically: true, encoding: .utf8)
        try userData(config: config, user: user, hostname: hostname, distribution: distribution)
            .write(to: folder.appending(path: "user-data"), atomically: true, encoding: .utf8)
        try? FileManager.default.removeItem(at: url)
        try await Shell.run("/usr/bin/hdiutil", ["makehybrid", "-quiet", "-iso", "-joliet", "-default-volume-name", "cidata",
                                                 "-o", url.path, folder.path])
    }

    /// A user for the guest: the Mac's short name, and a random password Hyperbox keeps in the config.
    static func makeUser() -> MachineConfig.GuestUser {
        var name = NSUserName().lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
        if name.first?.isLetter != true || ["root", "daemon", "bin", "sys", "admin", "nobody", "ubuntu", "debian", "fedora"].contains(name) {
            name = "user"
        }
        let alphabet = Array("abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        let password = String((0..<16).map { _ in alphabet.randomElement()! })
        return .init(name: String(name.prefix(32)), password: password)
    }

    static func hostname(for config: MachineConfig) -> String {
        let name = config.name.lowercased().map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" }
        let trimmed = String(name).split(separator: "-").joined(separator: "-").prefix(63)
        return trimmed.isEmpty ? (config.distribution ?? "linux") : String(trimmed)
    }

    // MARK: - user-data

    /// JSON, which YAML reads as it is, so nothing needs quoting by hand.
    static func userData(config: MachineConfig, user: MachineConfig.GuestUser, hostname: String, distribution: LinuxDistribution) throws -> String {
        guard let agent = Bundle.main.url(forResource: "linux-agent", withExtension: "py") else {
            throw ControlError("Hyperbox's Linux agent is missing from the app.")
        }
        let agentScript = try Data(contentsOf: agent)
        func file(_ path: String, _ content: String, permissions: String = "0644") -> JSONValue {
            ["path": .string(path), "content": .string(Data(content.utf8).base64EncodedString()), "encoding": "b64", "permissions": .string(permissions)]
        }
        let data: JSONValue = [
            "hostname": .string(hostname),
            "timezone": .string(TimeZone.current.identifier),
            "users": [[
                "name": .string(user.name),
                "gecos": .string(NSFullUserName()),
                "groups": .string(distribution.adminGroup),
                "shell": "/bin/bash",
                "sudo": "ALL=(ALL) NOPASSWD:ALL",
                "lock_passwd": false,
                "plain_text_passwd": .string(user.password),
            ]],
            "ssh_pwauth": false,
            "growpart": ["mode": "auto", "devices": ["/"]],
            "resize_rootfs": true,
            // Everything cloud-init and the setup print, to the Mac's console.log too.
            "output": ["all": "| tee -a /var/log/cloud-init-output.log /dev/hvc0"],
            "write_files": [
                ["path": .string(agentPath), "content": .string(agentScript.base64EncodedString()), "encoding": "b64", "permissions": "0755"],
                file("/etc/hyperbox/agent.json", #"{"user": "\#(user.name)"}"# + "\n"),
                file("/etc/systemd/system/hyperbox-agent.service", agentUnit),
                file("/etc/systemd/system/hyperbox-rosetta.service", rosettaUnit),
                file("/usr/local/libexec/hyperbox/rosetta.sh", rosettaScript, permissions: "0755"),
                file("/var/lib/hyperbox/setup.sh", setupScript(user: user.name, distribution: distribution), permissions: "0755"),
                file("/etc/systemd/system/hyperbox-setup.service", setupUnit),
            ],
            "runcmd": [
                ["systemctl", "daemon-reload"],
                ["systemctl", "enable", "--now", "hyperbox-agent.service"],
                ["systemctl", "enable", "hyperbox-setup.service"],
                ["systemctl", "start", "--no-block", "hyperbox-setup.service"],
            ],
        ]
        let encoder = JSONEncoder()
        // Plain slashes: older YAML parsers don't know JSON's \/ escape.
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let json = String(decoding: try encoder.encode(data), as: UTF8.self)
        return "#cloud-config\n" + json + "\n"
    }

    private static let agentUnit = """
        [Unit]
        Description=Hyperbox guest agent

        [Service]
        ExecStart=/usr/bin/python3 -I \(agentPath)
        Restart=always
        RestartSec=2
        TimeoutStopSec=8

        [Install]
        WantedBy=multi-user.target

        """

    /// Runs each boot until the setup has finished, which it marks with the boot it finished in.
    private static let setupUnit = """
        [Unit]
        Description=Hyperbox first-boot setup
        Wants=network-online.target
        After=network-online.target cloud-final.service
        ConditionPathExists=!/var/lib/hyperbox/install-boot-id

        [Service]
        Type=oneshot
        ExecStart=/bin/sh -c '/var/lib/hyperbox/setup.sh 2>&1 | tee -a /var/log/hyperbox-setup.log /dev/hvc0'
        TimeoutStartSec=infinity

        [Install]
        WantedBy=multi-user.target

        """

    /// Runs only when the Mac shares Rosetta, which it does while the machine's Rosetta setting is on.
    private static let rosettaUnit = """
        [Unit]
        Description=Run Intel binaries with Rosetta
        RequiresMountsFor=/media/rosetta
        ConditionPathExists=/media/rosetta/rosetta

        [Service]
        Type=oneshot
        RemainAfterExit=yes
        ExecStart=/usr/local/libexec/hyperbox/rosetta.sh

        [Install]
        WantedBy=multi-user.target

        """

    /// Registers Rosetta for x86-64 ELF binaries, with the magic and mask from Apple's "Running Intel
    /// Binaries in Linux VMs with Rosetta". The kernel reads the \\x escapes itself.
    private static let rosettaScript = #"""
        #!/bin/sh
        [ -e /proc/sys/fs/binfmt_misc/rosetta ] && exit 0
        [ -e /proc/sys/fs/binfmt_misc/register ] || mount -t binfmt_misc binfmt_misc /proc/sys/fs/binfmt_misc
        printf '%s\n' ':rosetta:M::\x7fELF\x02\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\x3e\x00:\xff\xff\xff\xff\xff\xfe\xfe\x00\xff\xff\xff\xff\xff\xff\xff\xff\xfe\xff\xff\xff:/media/rosetta/rosetta:CF' > /proc/sys/fs/binfmt_misc/register

        """#

    // MARK: - The setup script

    /// Lines starting `hyperbox:` name the step for the Mac's progress; `hyperbox: failed:` stops the install.
    static func setupScript(user: String, distribution: LinuxDistribution) -> String {
        let packages = distribution.packages.joined(separator: " ")
        let install: String
        switch distribution.family {
        case .debian:
            install = """
                export DEBIAN_FRONTEND=noninteractive
                # Finishes what a setup cut short by the Mac quitting had begun.
                dpkg --configure -a
                apt="apt-get -y -o DPkg::Lock::Timeout=900 -o Dpkg::Options::=--force-confold"
                step "Downloading the package list"
                $apt update || { sleep 15; $apt update; } || fail "Couldn't reach the package servers."
                step "Installing the desktop"
                $apt install \(packages) || { sleep 15; $apt update; $apt install \(packages); } || fail "Couldn't install the desktop."
                """
        case .fedora:
            install = """
                step "Installing the desktop"
                dnf -y install \(packages) || { sleep 15; dnf -y install \(packages); } || fail "Couldn't install the desktop."
                systemctl set-default graphical.target
                """
        }
        let bootOptions: String
        switch (distribution.family, distribution.id) {
        case (.fedora, _):
            bootOptions = #"grubby --update-kernel=ALL --remove-args="console=tty0 console=ttyS0,115200n8" --args="console=hvc0 console=tty0 rhgb quiet""#
        case (.debian, "ubuntu"):
            bootOptions = """
                printf '%s\\n' 'GRUB_CMDLINE_LINUX_DEFAULT="quiet splash console=hvc0 console=tty1"' 'GRUB_TIMEOUT=0' > /etc/default/grub.d/90-hyperbox.cfg
                update-grub
                """
        case (.debian, _):
            bootOptions = """
                mkdir -p /etc/default/grub.d
                printf '%s\\n' 'GRUB_CMDLINE_LINUX="console=hvc0 console=tty0"' 'GRUB_CMDLINE_LINUX_DEFAULT="quiet"' 'GRUB_TIMEOUT=0' > /etc/default/grub.d/90-hyperbox.cfg
                update-grub
                """
        }
        let keyboard = Keyboard.current
        return """
            #!/bin/sh
            # Hyperbox's first-boot setup, run once by cloud-init. Its output goes to console.log on the Mac.
            step() { echo "hyperbox: $*"; }
            fail() { echo "hyperbox: failed: $*"; echo "$*" > /var/lib/hyperbox/install-failed; exit 1; }
            mkdir -p /var/lib/hyperbox
            rm -f /var/lib/hyperbox/install-failed

            step "Setting up shared folders"
            mkdir -p /mnt/hyperbox /media/rosetta
            grep -q '^hyperbox ' /etc/fstab || echo 'hyperbox /mnt/hyperbox virtiofs rw,nofail 0 0' >> /etc/fstab
            grep -q '^rosetta ' /etc/fstab || echo 'rosetta /media/rosetta virtiofs ro,nofail 0 0' >> /etc/fstab
            systemctl daemon-reload
            mount /mnt/hyperbox 2>/dev/null
            mount /media/rosetta 2>/dev/null
            systemctl enable hyperbox-rosetta.service
            systemctl start hyperbox-rosetta.service

            \(install)

            step "Signing in automatically"
            mkdir -p "$(dirname \(distribution.gdmConfig))"
            printf '%s\\n' '[daemon]' 'AutomaticLoginEnable=true' 'AutomaticLogin=\(user)' > \(distribution.gdmConfig)
            for group in adm audio video render kvm lpadmin users; do getent group $group >/dev/null && usermod -aG $group \(user); done
            home=$(getent passwd \(user) | cut -d: -f6)
            mkdir -p "$home/.config"
            echo yes > "$home/.config/gnome-initial-setup-done"
            chown -R \(user): "$home/.config"

            step "Finishing"
            # No lock screen: the password is a random one, kept by Hyperbox. And the Mac's keyboard layout.
            cat > /usr/share/glib-2.0/schemas/90-hyperbox.gschema.override <<'EOF'
            [org.gnome.desktop.screensaver]
            lock-enabled=false

            [org.gnome.desktop.session]
            idle-delay=uint32 0

            [org.gnome.desktop.input-sources]
            sources=[('xkb', '\(keyboard.gnome)')]
            EOF
            glib-compile-schemas /usr/share/glib-2.0/schemas
            localectl set-x11-keymap \(keyboard.layout) "" \(keyboard.variant ?? "") 2>/dev/null
            # The desktop's NetworkManager takes over the network from cloud-init's config.
            if [ -d /etc/netplan ]; then
              rm -f /etc/netplan/50-cloud-init.yaml
              printf '%s\\n' 'network:' '  version: 2' '  renderer: NetworkManager' > /etc/netplan/01-network-manager-all.yaml
              chmod 600 /etc/netplan/01-network-manager-all.yaml
            fi
            rm -f /etc/network/interfaces.d/50-cloud-init
            \(bootOptions)
            touch /etc/cloud/cloud-init.disabled
            cat /proc/sys/kernel/random/boot_id > /var/lib/hyperbox/install-boot-id
            sync
            step "Restarting"
            systemctl reboot

            """
    }
}

/// The Mac's keyboard layout in XKB's terms, so the guest types what the keys say.
nonisolated struct Keyboard: Sendable {
    var layout: String
    var variant: String?
    var gnome: String { variant.map { "\(layout)+\($0)" } ?? layout }

    static var current: Keyboard {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return Keyboard(layout: "us") }
        let id = Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
        return map[id.replacingOccurrences(of: "com.apple.keylayout.", with: "")] ?? Keyboard(layout: "us")
    }

    private static let map: [String: Keyboard] = [
        "US": .init(layout: "us"), "ABC": .init(layout: "us"), "USInternational-PC": .init(layout: "us", variant: "intl"),
        "Dvorak": .init(layout: "us", variant: "dvorak"), "Colemak": .init(layout: "us", variant: "colemak"),
        "British": .init(layout: "gb", variant: "mac"), "British-PC": .init(layout: "gb"),
        "French": .init(layout: "fr", variant: "mac"), "French-numerical": .init(layout: "fr", variant: "mac"), "French-PC": .init(layout: "fr"),
        "German": .init(layout: "de", variant: "mac"), "Austrian": .init(layout: "at", variant: "mac"),
        "Spanish": .init(layout: "es", variant: "mac"), "Spanish-ISO": .init(layout: "es", variant: "mac"),
        "Italian": .init(layout: "it", variant: "mac"), "Italian-Pro": .init(layout: "it", variant: "mac"),
        "Portuguese": .init(layout: "pt", variant: "mac"), "Brazilian": .init(layout: "br"),
        "SwissFrench": .init(layout: "ch", variant: "fr_mac"), "SwissGerman": .init(layout: "ch", variant: "de_mac"),
        "Belgian": .init(layout: "be"), "Dutch": .init(layout: "nl", variant: "mac"),
        "Swedish": .init(layout: "se", variant: "mac"), "Swedish-Pro": .init(layout: "se", variant: "mac"),
        "Norwegian": .init(layout: "no", variant: "mac"), "Danish": .init(layout: "dk", variant: "mac"),
        "Finnish": .init(layout: "fi", variant: "mac"), "Canadian-CSA": .init(layout: "ca"), "Polish": .init(layout: "pl"),
    ]
}
