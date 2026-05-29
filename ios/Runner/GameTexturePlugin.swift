import CoreVideo
import Flutter
import UIKit

/// IOSurface-backed double buffer; libretro writes directly into the back buffer (one convert pass).
@objc final class PixelBufferGameTexture: NSObject, FlutterTexture {
  private let width: Int
  private let height: Int
  private var frontBuffer: CVPixelBuffer?
  private var backBuffer: CVPixelBuffer?
  private let lock = NSLock()
  private var backLocked = false

  init(width: Int, height: Int) {
    self.width = width
    self.height = height
    super.init()
    recreateBuffers()
  }

  func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>? {
    lock.lock()
    defer { lock.unlock() }
    guard let frontBuffer else { return nil }
    return Unmanaged.passRetained(frontBuffer)
  }

  /// Lock back buffer for direct BGRA writes from the emulation thread.
  @objc func lockBackBuffer(
    _ outBase: UnsafeMutablePointer<UnsafeMutableRawPointer?>,
    pitch outPitch: UnsafeMutablePointer<Int32>,
    width outWidth: UnsafeMutablePointer<Int32>,
    height outHeight: UnsafeMutablePointer<Int32>
  ) -> Bool {
    lock.lock()
    if backLocked {
      lock.unlock()
      return false
    }
    if frontBuffer == nil || backBuffer == nil {
      recreateBuffers()
    }
    guard let backBuffer else {
      lock.unlock()
      return false
    }

    CVPixelBufferLockBaseAddress(backBuffer, CVPixelBufferLockFlags(rawValue: 0))
    guard let base = CVPixelBufferGetBaseAddress(backBuffer) else {
      CVPixelBufferUnlockBaseAddress(backBuffer, CVPixelBufferLockFlags(rawValue: 0))
      lock.unlock()
      return false
    }

    backLocked = true
    outBase.pointee = base
    outPitch.pointee = Int32(CVPixelBufferGetBytesPerRow(backBuffer))
    outWidth.pointee = Int32(width)
    outHeight.pointee = Int32(height)
    lock.unlock()
    return true
  }

  @objc func commitBackBufferAndSwap() {
    lock.lock()
    defer { lock.unlock() }
    guard backLocked, let buf = backBuffer else { return }
    CVPixelBufferUnlockBaseAddress(buf, CVPixelBufferLockFlags(rawValue: 0))
    backLocked = false
    swap(&frontBuffer, &backBuffer)
    game_texture_ios_mark_frame_ready()
  }

  @objc func cancelBackBufferLock() {
    lock.lock()
    defer { lock.unlock() }
    if backLocked, let buf = backBuffer {
      CVPixelBufferUnlockBaseAddress(buf, CVPixelBufferLockFlags(rawValue: 0))
      backLocked = false
    }
  }

  private func recreateBuffers() {
    frontBuffer = makePixelBuffer()
    backBuffer = makePixelBuffer()
    backLocked = false
  }

  private func makePixelBuffer() -> CVPixelBuffer? {
    var buffer: CVPixelBuffer?
    let attrs: [String: Any] = [
      kCVPixelBufferIOSurfacePropertiesKey as String: [:],
    ]
    let status = CVPixelBufferCreate(
      kCFAllocatorDefault,
      width,
      height,
      kCVPixelFormatType_32BGRA,
      attrs as CFDictionary,
      &buffer
    )
    return status == kCVReturnSuccess ? buffer : nil
  }
}

final class GameTexturePlugin: NSObject, FlutterPlugin {
  static weak var shared: GameTexturePlugin?

  private var textures: [Int64: PixelBufferGameTexture] = [:]
  private var registry: FlutterTextureRegistry?
  private var displayLink: CADisplayLink?

  static func register(with registrar: FlutterPluginRegistrar) {
    let instance = GameTexturePlugin()
    instance.registry = registrar.textures()
    shared = instance
    let channel = FlutterMethodChannel(
      name: "game_texture",
      binaryMessenger: registrar.messenger()
    )
    registrar.addMethodCallDelegate(instance, channel: channel)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "createTexture":
      guard let args = call.arguments as? [String: Any],
            let width = args["width"] as? Int,
            let height = args["height"] as? Int,
            width > 0,
            height > 0,
            let registry else {
        result(FlutterError(code: "invalid_args", message: nil, details: nil))
        return
      }
      let texture = PixelBufferGameTexture(width: width, height: height)
      let id = registry.register(texture)
      textures[id] = texture
      game_texture_ios_set_active(Unmanaged.passUnretained(texture).toOpaque())
      game_texture_ios_set_flutter_texture(
        Unmanaged.passUnretained(registry).toOpaque(),
        id
      )
      startDisplayLink()
      result(id)
    case "disposeTexture":
      guard let args = call.arguments as? [String: Any],
            let id = args["textureId"] as? Int64,
            let registry else {
        result(FlutterError(code: "invalid_args", message: nil, details: nil))
        return
      }
      if textures.removeValue(forKey: id) != nil {
        stopDisplayLink()
        registry.unregisterTexture(id)
        game_texture_ios_set_active(nil)
        game_texture_ios_set_flutter_texture(nil, 0)
      }
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func startDisplayLink() {
    stopDisplayLink()
    let link = CADisplayLink(target: self, selector: #selector(onDisplayLink(_:)))
    if #available(iOS 15.0, *) {
      link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 60, preferred: 60)
    } else {
      link.preferredFramesPerSecond = 60
    }
    link.add(to: .main, forMode: .common)
    displayLink = link
  }

  private func stopDisplayLink() {
    displayLink?.invalidate()
    displayLink = nil
  }

  @objc private func onDisplayLink(_ sender: CADisplayLink) {
    game_texture_ios_on_display_link()
  }
}
