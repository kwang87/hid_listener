import AppKit
import CoreGraphics
import Foundation
import HidListenerShared

var listenerInstance: HidListener?
var gIsHidListenerEnabled = true
var prevFlags = UInt64(256)


// ===========================================================
// MARK: Keyboard Callback
// ===========================================================
func keyboardEventCallback(
  proxy: CGEventTapProxy,
  type: CGEventType,
  event: CGEvent,
  userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? 
{
  NSLog("✅ keyboardEventCallback") //
  if !gIsHidListenerEnabled {
    NSLog("✅ keyboardEventCallback isListenerEnabled is disable") //
    return Unmanaged.passRetained(event)
  }
  // NSEvent 생성은 반드시 메인 큐
  DispatchQueue.main.async {
    guard let nsEvent = NSEvent(cgEvent: event) else { return }

    let eventType: MacOsKeyboardEventType
    var characters = ""
    var charactersIgnoringModifiers = ""

    // ---- flagsChanged 특별 처리 ----
    if type == .flagsChanged {
      eventType = (prevFlags < event.flags.rawValue)
        ? .KeyDown
        : .KeyUp
      
      // flagsChanged 시 IME 조합문자 접근 금지 (Crash 방지)
      characters = ""
      charactersIgnoringModifiers = ""

    } else if type == .keyDown {
      eventType = .KeyDown
      characters = nsEvent.characters ?? ""
      charactersIgnoringModifiers = nsEvent.charactersIgnoringModifiers ?? ""

    } else {
      eventType = .KeyUp
      characters = nsEvent.characters ?? ""
      charactersIgnoringModifiers = nsEvent.charactersIgnoringModifiers ?? ""
    }

    let keyCode = Int(nsEvent.keyCode)
    let modifiers = Int(nsEvent.modifierFlags.rawValue)

    NSLog("keyevent: native: keyCode=\(keyCode), chars=\(characters), ignore=\(charactersIgnoringModifiers), flags=\(modifiers)")

    let keyboardEvent = Unmanaged.passRetained(
      MacOsKeyboardEvent(
        eventType: eventType,
        characters: characters,
        charactersIgnoringModifiers: charactersIgnoringModifiers,
        keyCode: keyCode,
        modifiers: modifiers,
        isMedia: false,
        mediaEventType: .Play
      )
    )

    NSLog("notifyDart → port: \(keyboardListenerPort)")
    
    let pointerEvent = UnsafeMutablePointer<MacOsKeyboardEvent>.allocate(capacity: 1)
    pointerEvent.initialize(to: keyboardEvent.takeRetainedValue())

    notifyDart(port: keyboardListenerPort, data: pointerEvent)

    // modifier key 판별을 위해 반드시 갱신
    prevFlags = event.flags.rawValue
  }
  NSLog("✅ end keyboardEventCallback") //
  return Unmanaged.passRetained(event)
}


// ===========================================================
// MARK: Media Key Callback
// ===========================================================
func mediaEventCallback(
  proxy: CGEventTapProxy,
  type: CGEventType,
  event: CGEvent,
  userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? 
{
  if !gIsHidListenerEnabled {
    NSLog("✅ mediaEventCallback isListenerEnabled is disable") //
    return Unmanaged.passRetained(event)
  }
  
  DispatchQueue.main.async {
    NSLog("✅ mediaEventCallback") // 
    NSLog("event \(event)") 
    guard let nsEvent = NSEvent(cgEvent: event) else { return }

    let keyCode = (UInt32(bitPattern: Int32(nsEvent.data1)) & 0xFFFF0000) >> 16
    let isKeyDown = ((nsEvent.data1 & 0xFF00) >> 8) == 0xA

    let mediaEventType: MacOsMediaEventType? = {
      switch Int32(keyCode) {
      case NX_KEYTYPE_PLAY: return .Play
      case NX_KEYTYPE_PREVIOUS: return .Previous
      case NX_KEYTYPE_NEXT: return .Next
      case NX_KEYTYPE_REWIND: return .Rewind
      case NX_KEYTYPE_FAST: return .Fast
      case NX_KEYTYPE_MUTE: return .Mute
      case NX_KEYTYPE_BRIGHTNESS_UP: return .BrightnessUp
      case NX_KEYTYPE_BRIGHTNESS_DOWN: return .BrightnessDown
      case NX_KEYTYPE_SOUND_UP: return .VolumeUp
      case NX_KEYTYPE_SOUND_DOWN: return .VolumeDown
      default: return nil
      }
    }()

    guard let mediaType = mediaEventType else { return }

    let eventType: MacOsKeyboardEventType = isKeyDown ? .KeyDown : .KeyUp

    let keyboardEvent = Unmanaged.passRetained(
      MacOsKeyboardEvent(
        eventType: eventType,
        characters: " ",
        charactersIgnoringModifiers: " ",
        keyCode: 0,
        modifiers: 0,
        isMedia: true,
        mediaEventType: mediaType
      )
    )

    let pointerEvent = UnsafeMutablePointer<MacOsKeyboardEvent>.allocate(capacity: 1)
    pointerEvent.initialize(to: keyboardEvent.takeRetainedValue())

    notifyDart(port: keyboardListenerPort, data: pointerEvent)
  }
  NSLog("✅ end mediaEventCallback") //

  return Unmanaged.passRetained(event)
}


// ===========================================================
// MARK: Mouse Callback (즉시 처리 = 성능 유지)
// ===========================================================
func mouseEventCallback(
  proxy: CGEventTapProxy,
  type: CGEventType,
  event: CGEvent,
  userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? 
{

  if !gIsHidListenerEnabled {
    NSLog("✅ mouseEventCallback isListenerEnabled is disable") //
    return Unmanaged.passRetained(event)
  }
  

  let mouseLoc = NSEvent.mouseLocation
  let mouseEvent = UnsafeMutablePointer<MouseEvent>.allocate(capacity: 1)

  mouseEvent.pointee.x = mouseLoc.x
  mouseEvent.pointee.y = mouseLoc.y

  if type == .leftMouseDown {
    mouseEvent.pointee.eventType = MouseEventType(0)
  } else if type == .leftMouseUp {
    mouseEvent.pointee.eventType = MouseEventType(1)
  } else if type == .rightMouseDown {
    mouseEvent.pointee.eventType = MouseEventType(2)
  } else if type == .rightMouseUp {
    mouseEvent.pointee.eventType = MouseEventType(3)
  } else if type == .mouseMoved || type == .leftMouseDragged || type == .rightMouseDragged {
    mouseEvent.pointee.eventType = MouseEventType(4)
  } else if type == .scrollWheel {
    let v = event.getIntegerValueField(.scrollWheelEventDeltaAxis1)
    let h = event.getIntegerValueField(.scrollWheelEventDeltaAxis2)
    if v != 0 {
      mouseEvent.pointee.eventType = MouseEventType(5)
      mouseEvent.pointee.wheelDelta = v
    } else if h != 0 {
      mouseEvent.pointee.eventType = MouseEventType(6)
      mouseEvent.pointee.wheelDelta = h
    }
  }

  notifyDart(port: mouseListenerPort, data: mouseEvent)

  return Unmanaged.passRetained(event)
}


// ===========================================================
// MARK: Listener Class (두 버전 구조 그대로 유지)
// ===========================================================
public class HidListener {
  let keyboardQueue = DispatchQueue(label: "HidListener Keyboard Queue")
  var initialized = false
  var rootInitializer = false 

  // 🚩 이벤트 탭 참조 저장용 변수 추가
  private var keyboardTap: CFMachPort?
  private var mediaTap: CFMachPort?
  private var mouseTap: CFMachPort?

  public init() {
    if listenerInstance != nil { return }
    rootInitializer = true
    listenerInstance = self
  }

  public func initialize() -> Bool {
    NSLog("✅ initialize called") //

    // flagsChanged 포함 → modifier key 지원
    let keyboardEventMask =
      (1 << CGEventType.keyDown.rawValue) |
      (1 << CGEventType.keyUp.rawValue) |
      (1 << CGEventType.flagsChanged.rawValue) 

    let mouseMask =
      (1 << CGEventType.leftMouseDown.rawValue) |
      (1 << CGEventType.leftMouseUp.rawValue) |
      (1 << CGEventType.rightMouseDown.rawValue) |
      (1 << CGEventType.rightMouseUp.rawValue) |
      (1 << CGEventType.mouseMoved.rawValue) |
      (1 << CGEventType.scrollWheel.rawValue) |
      (1 << CGEventType.leftMouseDragged.rawValue) |
      (1 << CGEventType.rightMouseDragged.rawValue)

    // 🚩 guard let을 제거하고 클래스 변수에 저장
    self.keyboardTap = CGEvent.tapCreate(
        tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
        eventsOfInterest: CGEventMask(keyboardEventMask), callback: keyboardEventCallback, userInfo: nil
    )
    self.mediaTap = CGEvent.tapCreate(
        tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
        eventsOfInterest: CGEventMask(1 << NX_SYSDEFINED), callback: mediaEventCallback, userInfo: nil
    )
    self.mouseTap = CGEvent.tapCreate(
        tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
        eventsOfInterest: CGEventMask(mouseMask), callback: mouseEventCallback, userInfo: nil
    )

    guard let kTap = keyboardTap, let mTap = mediaTap, let moTap = mouseTap else { return false }

    keyboardQueue.async {
        let kr = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, kTap, 0)
        let mr = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, mTap, 0)
        let rr = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, moTap, 0)

        CFRunLoopAddSource(CFRunLoopGetCurrent(), kr, .commonModes)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), mr, .commonModes)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), rr, .commonModes)

        CGEvent.tapEnable(tap: kTap, enable: true)
        CGEvent.tapEnable(tap: mTap, enable: true)
        CGEvent.tapEnable(tap: moTap, enable: true)

        CFRunLoopRun()
    }

    initialized = true
    return true 
  }

  // 🚩 On/Off 제어 메서드 추가
  public func setEnabled(_ enabled: Bool) {
      gIsHidListenerEnabled = enabled

      if let k = keyboardTap { CGEvent.tapEnable(tap: k, enable: enabled) }
      if let m = mediaTap { CGEvent.tapEnable(tap: m, enable: enabled) }
      if let mo = mouseTap { CGEvent.tapEnable(tap: mo, enable: enabled) }
      // 추가: enabled == false 일 때 즉시 포트 비우기 (선택적이지만 강력 추천)
      // if !enabled {
      //     keyboardListenerPort = 0
      //     mouseListenerPort = 0
      // }
    
      NSLog("✅ HidListener setEnabled: \(enabled)")
  }

  deinit { if rootInitializer { listenerInstance = nil } }
}


var keyboardListenerPort: Dart_Port = 0
var mouseListenerPort: Dart_Port = 0

func notifyDart(port: Dart_Port, data: UnsafeMutableRawPointer) {
  if port == 0 {
    return
  }

  var cObject = Dart_CObject()
  cObject.type = Dart_CObject_kInt64
  cObject.value.as_int64 = Int64(UInt(bitPattern: data))

  _ = Dart_PostCObject_DL(port, &cObject)
}

// 🚩 Dart에서 호출할 수 있도록 브릿지 함수 추가
func Internal_SetListenerEnabled(enabled: Bool) -> Bool {
    guard let instance = listenerInstance else { return false }
    instance.setEnabled(enabled)
    return true
}

func Internal_SetKeyboardListener(port: Dart_Port) -> Bool {
  if !(listenerInstance?.initialized ?? false) {
    return false
  }
  keyboardListenerPort = port
  return true
}

func Internal_SetMouseListener(port: Dart_Port) -> Bool {
  if !(listenerInstance?.initialized ?? false) {
    return false
  }
  mouseListenerPort = port
  return true
}

func Internal_InitializeDartAPI(data: UnsafeMutableRawPointer) {
  Dart_InitializeApiDL(data)
}

func Internal_InitializeListeners() -> Bool {
  NSLog("✅ Internal_InitializeListeners called") //
  if listenerInstance == nil {
    listenerInstance = HidListener()
  }
  return listenerInstance?.initialize() ?? false
}

@objc public enum MacOsKeyboardEventType: Int {
  case KeyDown, KeyUp
}

@objc public enum MacOsMediaEventType: Int {
  case Play, Previous, Next, Rewind, Fast, Mute, BrightnessUp, BrightnessDown, VolumeUp, VolumeDown
}

@objc public class MacOsKeyboardEvent: NSObject {
  @objc public var eventType: MacOsKeyboardEventType
  @objc public var characters: String
  @objc public var charactersIgnoringModifiers: String
  @objc public var keyCode: Int
  @objc public var modifiers: Int
  @objc public var isMedia: Bool
  @objc public var mediaEventType: MacOsMediaEventType

  init(eventType: MacOsKeyboardEventType, characters: String, charactersIgnoringModifiers: String, keyCode: Int, modifiers: Int, isMedia: Bool, mediaEventType: MacOsMediaEventType) {
    self.eventType = eventType
    self.characters = characters
    self.charactersIgnoringModifiers = charactersIgnoringModifiers
    self.keyCode = keyCode
    self.modifiers = modifiers
    self.isMedia = isMedia
    self.mediaEventType = mediaEventType
  }
}

@objc public class HidListenerBindings: NSObject {
  @objc public static func InitializeDartAPI(data: UnsafeMutableRawPointer) {
    Internal_InitializeDartAPI(data: data)
  }

  @objc public static func InitializeListeners() -> Bool {
    NSLog("✅ InitializeListeners called") //
    return Internal_InitializeListeners()
  }

  @objc public static func SetKeyboardListener(port: Int64) -> Bool {
    return Internal_SetKeyboardListener(port: Dart_Port(port))
  }

  @objc public static func SetMouseListener(port: Int64) -> Bool {
    return Internal_SetMouseListener(port: Dart_Port(port))
  }
 
  @objc public static func SetListenerEnabled(_ enabled: Bool) -> Bool {
    return Internal_SetListenerEnabled(enabled: enabled)
  }
}
