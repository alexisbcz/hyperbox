import Foundation

// convert <image> <out.raw>: converts a disk image as the importer does. A .pvm or .hdd is a Parallels machine or disk.
let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    FileHandle.standardError.write(Data("usage: convert <image> <out.raw>\n".utf8))
    exit(2)
}
let url = URL(fileURLWithPath: arguments[1])
do {
    let image: DiskImage = switch url.pathExtension {
    case "pvm": try ParallelsMachine(url).open()
    case "hdd": try ParallelsDisk(url)
    default: try DiskImages.open(url)
    }
    try DiskConverter.convert(image, to: URL(fileURLWithPath: arguments[2]))
} catch {
    FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
    exit(1)
}
