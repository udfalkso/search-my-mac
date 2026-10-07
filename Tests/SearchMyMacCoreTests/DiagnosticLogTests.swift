import Foundation
import Testing
@testable import SearchMyMacCore

@Test func diagnosticLogWritesBoundedPrivateJSONLines() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("timings.log")
    let logger = DiagnosticLog(url: url, maximumBytes: 2_048)
    for index in 0..<40 {
        logger.record("test", requestID: "request-\(index)", details: "query=shoe\nwith a newline")
    }
    logger.flush()
    let data = try Data(contentsOf: url)
    #expect(data.count <= 2_048)
    let lines = String(decoding: data, as: UTF8.self).split(separator: "\n")
    #expect(!lines.isEmpty)
    for line in lines {
        let event = try #require(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        #expect(event["stage"] as? String == "test")
    }
    #expect(String(decoding: data, as: UTF8.self).contains("request-39"))
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
}

@Test func diagnosticLogDoesNotFollowSymlinks() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let target = directory.appendingPathComponent("target")
    let link = directory.appendingPathComponent("log")
    try Data("original".utf8).write(to: target)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
    let logger = DiagnosticLog(url: link)
    logger.record("test")
    logger.flush()
    #expect(try String(contentsOf: target, encoding: .utf8) == "original")
}
