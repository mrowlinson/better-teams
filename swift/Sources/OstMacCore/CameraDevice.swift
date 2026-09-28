// CameraDevice.swift — P4 split: verbatim move from CameraCapture.swift.

/// One built-in/external/Continuity camera, listed for the picker.
public struct CameraDevice: Identifiable, Hashable, Sendable {
    public let id: String // AVCaptureDevice.uniqueID (stable across launches)
    public let name: String // localizedName ("FaceTime HD Camera")
    public init(id: String, name: String) { self.id = id; self.name = name }
}
