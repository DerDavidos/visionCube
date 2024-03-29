import Foundation

struct QVisFileException: Error {
    var message: String
}

struct QVisDatLine {
    var id: String
    var value: String
    
    init(_ input: String) {
        if let found = input.firstIndex(of: ":") {
            id = String(input[..<found])
            value = String(input[input.index(after: found)...])
            id = id.trimmingCharacters(in: .whitespaces)
            value = value.trimmingCharacters(in: .whitespaces)
            id = id.lowercased()
            value = value.lowercased()
        } else {
            id = ""
            value = ""
        }
    }
    
    private func ltrim(_ s: inout String) {
        s = String(s.drop(while: { $0.isWhitespace }))
    }
    
    private func rtrim(_ s: inout String) {
        if let lastNonWhitespaceIndex = s.lastIndex(where: { !$0.isWhitespace }) {
            s.removeSubrange(lastNonWhitespaceIndex..<s.endIndex)
        }
    }

    private func trim(_ s: inout String) {
        ltrim(&s)
        rtrim(&s)
    }
}

class QVis {
    var volume: Volume
    
    init(filename: String) throws {
        self.volume = Volume()
        try load(filename: filename)
    }
    
    func load(filename: String) throws {
        guard let datfile = FileManager.default.contents(atPath: filename) else {
            throw QVisFileException(message: "Unable to read file \(filename)")
        }
        
        var needsConversion: Bool = false
        let p = URL(fileURLWithPath: filename)
        var rawFilename = ""
        
        if let lines = String(data: datfile, encoding: .utf8)?.components(separatedBy: .newlines) {
            for line in lines {
                let l = QVisDatLine(line)
                if l.id == "objectfilename" {
                    if p.deletingLastPathComponent().path.isEmpty {
                        rawFilename = l.value
                    } else {
                        rawFilename = p.deletingLastPathComponent().path + "/" + l.value
                    }
                } else if l.id == "resolution" {
                    let t = l.value.components(separatedBy: " ")
                    if t.count != 3 {
                        throw QVisFileException(message: "invalid resolution tag")
                    }
                    guard let width = UInt(t[0]), let height = UInt(t[1]), let depth = UInt(t[2]) else {
                        throw QVisFileException(message: "invalid resolution tag")
                    }
                    volume.width = width
                    volume.height = height
                    volume.depth = depth
                } else if l.id == "slicethickness" {
                    let t = l.value.components(separatedBy: " ")
                    if t.count != 3 {
                        throw QVisFileException(message: "invalid slicethickness tag")
                    }
                    guard let x = Float(t[0]), let y = Float(t[1]), let z = Float(t[2]) else {
                        throw QVisFileException(message: "invalid slicethickness tag")
                    }
                    volume.scale = Vec3(x: x, y: y, z: z)
                    volume.normalizeScale()
                } else if l.id == "format" {
                    if l.value != "char" && l.value != "uchar" && l.value != "byte" {
                        needsConversion = true
                    }
                } else if l.id == "endianess" {
                    if l.value != "little" {
                        throw QVisFileException(message: "only little endian data supported by this mini-reader")
                    }
                }
            }
        }
        
        if rawFilename.isEmpty {
            throw QVisFileException(message: "object filename not found")
        }
        
        guard let rawFile = FileManager.default.contents(atPath: rawFilename) else {
            throw QVisFileException(message: "Unable to read file \(rawFilename)")
        }
        
        if needsConversion {
            throw QVisFileException(message: "only supports 8 bit")
        }
        volume.data = [UInt8](rawFile)
        volume.computeNormals()
    }
    
    func tokenize(_ str: String) -> [String] {
        return str.components(separatedBy: " ")
    }
}

func getFromResource(strFileName: String, ext: String) -> String {
    guard let cfFilename = CFStringCreateWithCString(kCFAllocatorDefault, strFileName, CFStringGetSystemEncoding()) else {
        return ""
    }
    
    guard let cfExt = CFStringCreateWithCString(kCFAllocatorDefault, ext, CFStringGetSystemEncoding()) else {
        return ""
    }
    
    guard let imageURL = CFBundleCopyResourceURL(CFBundleGetMainBundle(), cfFilename, cfExt, nil) else {
        return ""
    }
    
    let macPath = CFURLCopyFileSystemPath(imageURL, CFURLPathStyle.cfurlposixPathStyle)
    let pathPtr = CFStringGetCStringPtr(macPath, CFStringGetSystemEncoding())
    
    if let pathPtr = pathPtr, let result = String(validatingUTF8: pathPtr) {
        return result
    } else {
        return ""
    }
}
