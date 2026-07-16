import CircuiteFoundation
import Foundation

/// Creates integrity-backed Foundation references for CLI inputs and outputs.
struct CoreSpiceCLIArtifactReferencer: Sendable {
  private let referencer: LocalArtifactReferencer
  private let producer: ProducerIdentity

  init(referencer: LocalArtifactReferencer = LocalArtifactReferencer()) throws {
    self.referencer = referencer
    self.producer = try ProducerIdentity(
      kind: .tool,
      identifier: "CoreSpiceCLI",
      version: "0.1.0"
    )
  }

  func input(
    path: String,
    kind: ArtifactKind,
    format: ArtifactFormat
  ) throws -> ArtifactReference {
    try reference(path: path, role: .input, kind: kind, format: format, producer: nil)
  }

  func output(
    path: String,
    kind: ArtifactKind,
    format: ArtifactFormat
  ) throws -> ArtifactReference {
    try reference(path: path, role: .output, kind: kind, format: format, producer: producer)
  }

  private func reference(
    path: String,
    role: ArtifactRole,
    kind: ArtifactKind,
    format: ArtifactFormat,
    producer: ProducerIdentity?
  ) throws -> ArtifactReference {
    let url = URL(fileURLWithPath: path).standardizedFileURL
    let locator = ArtifactLocator(
      location: try ArtifactLocation(fileURL: url),
      role: role,
      kind: kind,
      format: format
    )
    return try referencer.reference(locator, producer: producer)
  }
}
