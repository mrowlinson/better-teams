// CameraError.swift — P4 split: verbatim move from CameraCapture.swift.

public enum CameraError: Error, Sendable {
    case noDevice
    case cannotAddInput
    case cannotAddOutput
}
