import Foundation

/// Official Docker Hub images the Containers page installs in one click, with settings that work out
/// of the box: a published port, a named volume for the data, and a generated password.
struct GalleryImage: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let image: String
    let summary: String
    let symbol: String
    /// The port in the container; published on the same port on the Mac when it's free.
    let port: Int
    /// Extra ports, published as they are (RabbitMQ's management UI).
    var extraPorts: [Int] = []
    /// Where the data lives in the container, kept in a named volume.
    var dataPath: String?
    /// Environment, with `{password}` replaced by a generated one.
    var env: [String: String] = [:]
    /// How to connect, with `{port}` and `{password}` filled in.
    var connect: String?

    var needsPassword: Bool { env.values.contains { $0.contains("{password}") } }

    static let all: [GalleryImage] = [
        GalleryImage(id: "postgres", name: "PostgreSQL", image: "postgres:17", summary: "The relational database.",
                     symbol: "cylinder.split.1x2", port: 5432, dataPath: "/var/lib/postgresql/data",
                     env: ["POSTGRES_PASSWORD": "{password}"],
                     connect: "postgresql://postgres:{password}@localhost:{port}/postgres"),
        GalleryImage(id: "mysql", name: "MySQL", image: "mysql:8.4", summary: "The popular open source database.",
                     symbol: "cylinder", port: 3306, dataPath: "/var/lib/mysql",
                     env: ["MYSQL_ROOT_PASSWORD": "{password}"],
                     connect: "mysql://root:{password}@127.0.0.1:{port}"),
        GalleryImage(id: "mariadb", name: "MariaDB", image: "mariadb:11", summary: "MySQL's community fork.",
                     symbol: "cylinder.fill", port: 3306, dataPath: "/var/lib/mysql",
                     env: ["MARIADB_ROOT_PASSWORD": "{password}"],
                     connect: "mysql://root:{password}@127.0.0.1:{port}"),
        GalleryImage(id: "redis", name: "Redis", image: "redis:7", summary: "In-memory key-value store.",
                     symbol: "bolt.horizontal", port: 6379, dataPath: "/data",
                     connect: "redis://localhost:{port}"),
        GalleryImage(id: "mongo", name: "MongoDB", image: "mongo:8", summary: "Document database.",
                     symbol: "leaf", port: 27017, dataPath: "/data/db",
                     env: ["MONGO_INITDB_ROOT_USERNAME": "root", "MONGO_INITDB_ROOT_PASSWORD": "{password}"],
                     connect: "mongodb://root:{password}@localhost:{port}"),
        GalleryImage(id: "nginx", name: "nginx", image: "nginx:latest", summary: "Web server and reverse proxy.",
                     symbol: "globe", port: 80,
                     connect: "http://localhost:{port}"),
        GalleryImage(id: "rabbitmq", name: "RabbitMQ", image: "rabbitmq:4-management", summary: "Message broker, with its web UI.",
                     symbol: "tray.2", port: 5672, extraPorts: [15672], dataPath: "/var/lib/rabbitmq",
                     env: ["RABBITMQ_DEFAULT_USER": "admin", "RABBITMQ_DEFAULT_PASS": "{password}"],
                     connect: "amqp://admin:{password}@localhost:{port} · web UI: http://localhost:15672"),
        GalleryImage(id: "memcached", name: "Memcached", image: "memcached:latest", summary: "Memory object cache.",
                     symbol: "memorychip", port: 11211,
                     connect: "localhost:{port}"),
    ]

    /// Which gallery image a container came from, by its image name.
    static func matching(_ container: ContainerSummary) -> GalleryImage? {
        let name = ContainerEngine.split(container.image).0
        return all.first { ContainerEngine.split($0.image).0 == name }
    }

    static func password() -> String {
        let alphabet = Array("abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        return String((0..<20).map { _ in alphabet.randomElement()! })
    }

    func filled(_ template: String, port: Int, password: String) -> String {
        template.replacingOccurrences(of: "{password}", with: password).replacingOccurrences(of: "{port}", with: String(port))
    }

    /// Installs it: pulls the image and starts a container that comes back when the engine restarts.
    func install(name: String, port: Int, password: String, progress: @escaping @Sendable (String) -> Void) throws -> String {
        var ports = [PortMapping(host: port, container: self.port)]
        ports += extraPorts.map { PortMapping(host: $0, container: $0) }
        var volumes: [String: String] = [:]
        if let dataPath { volumes["\(name)-data"] = dataPath }
        return try ContainerEngine.run(image: image, name: name, ports: ports, env: env.mapValues { filled($0, port: port, password: password) },
                                       volumes: volumes, restart: "unless-stopped", progress: progress)
    }
}
