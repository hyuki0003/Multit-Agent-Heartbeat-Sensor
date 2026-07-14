import Foundation

public struct RemoteFileMetadata: Equatable, Sendable {
    public let path: String
    public let size: Int64
    public let modificationToken: String

    public init(path: String, size: Int64, modificationToken: String) {
        self.path = path
        self.size = size
        self.modificationToken = modificationToken
    }
}

public enum SFTPStatParseError: Error, Equatable, LocalizedError {
    case missingSize(String)
    case missingModificationToken(String)

    public var errorDescription: String? {
        switch self {
        case .missingSize(let output):
            return "Could not parse an SFTP stat size from: \(output)"
        case .missingModificationToken(let output):
            return "Could not parse an SFTP stat modification token from: \(output)"
        }
    }
}

public enum SFTPStatParser {
    public static func parse(output: String, path: String) throws -> RemoteFileMetadata {
        let lines = output.split(whereSeparator: \Character.isNewline).map {
            String($0).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if let listing = parseLongListing(lines: lines, path: path) {
            return listing
        }

        let size = lines.lazy.compactMap { line -> Int64? in
            guard line.hasPrefix("Size:") else { return nil }
            let value = line.dropFirst("Size:".count)
                .split(whereSeparator: \Character.isWhitespace)
                .first
            return value.flatMap { Int64($0) }
        }.first

        guard let size else {
            throw SFTPStatParseError.missingSize(output)
        }

        let modificationToken = lines.lazy.compactMap { line -> String? in
            for prefix in ["Modify:", "MTime:", "mtime:"] where line.hasPrefix(prefix) {
                let token = String(line.dropFirst(prefix.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return token.isEmpty ? nil : token
            }
            return nil
        }.first

        guard let modificationToken else {
            throw SFTPStatParseError.missingModificationToken(output)
        }

        return RemoteFileMetadata(
            path: path,
            size: size,
            modificationToken: modificationToken
        )
    }

    private static func parseLongListing(
        lines: [String],
        path: String
    ) -> RemoteFileMetadata? {
        for line in lines {
            let fields = line.split(whereSeparator: \Character.isWhitespace)
            guard fields.count >= 9,
                  fields[0].count == 10,
                  "-bcdlps".contains(fields[0].first ?? "?"),
                  let size = Int64(fields[4]) else {
                continue
            }
            let token = fields[5...7].joined(separator: " ")
            return RemoteFileMetadata(path: path, size: size, modificationToken: token)
        }
        return nil
    }
}
