import 'dart:ffi' as ffi;
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:flutter/services.dart';
import 'package:hid_listener/src/hid_listener.dart';
import 'package:hid_listener/src/shared/hid_listener_shared.dart' as shared;

import 'hid_listener_bindings_macos.dart' as bindings;

class MacOsHidListenerBackend extends HidListenerBackend {
  MacOsHidListenerBackend(ffi.DynamicLibrary library)
      : _bindings = bindings.HidListenerBindingsSwift(library) {
    bindings.HidListenerBindings.InitializeDartAPIWithData_(
      _bindings,
      ffi.NativeApi.initializeApiDLData,
    );

    final inverse =
        kMacOsToPhysicalKey.map((key, value) => MapEntry(value, key));

    _muteKeyCode = inverse[PhysicalKeyboardKey.audioVolumeMute]!;
    _volumeUpKeyCode = inverse[PhysicalKeyboardKey.audioVolumeUp]!;
    _volumeDownKeyCode = inverse[PhysicalKeyboardKey.audioVolumeDown]!;
  }

  @override
  bool initialize() {
    return bindings.HidListenerBindings.InitializeListeners(_bindings);
  }

  @override
  void setEnabled(bool enabled) {
    bindings.HidListenerBindings.SetListenerEnabled_(_bindings, enabled);
  }

  @override
  bool registerKeyboard() {
    final requests = ReceivePort()..listen(_keyboardProc);
    final int nativePort = requests.sendPort.nativePort;
    print("Dart port: ${requests.sendPort.nativePort}");

    return bindings.HidListenerBindings.SetKeyboardListenerWithPort_(
      _bindings,
      nativePort,
    );
  }

  @override
  bool registerMouse() {
    final requests = ReceivePort()..listen(_mouseProc);
    final int nativePort = requests.sendPort.nativePort;

    return bindings.HidListenerBindings.SetMouseListenerWithPort_(
      _bindings,
      nativePort,
    );
  }

  // ===========================================================
  // Keyboard Event Processor (KeyEvent 기반)
  // ===========================================================
  void _keyboardProc(dynamic e) {
    if (e is! int || e == 0) return;

    // C 포인터 주소 → Pointer<Pointer<ObjCObject>>
    final eventAddr =
        ffi.Pointer<ffi.Pointer<bindings.ObjCObject>>.fromAddress(e);

    try {
      final nativeEvent = bindings.MacOsKeyboardEvent.castFromPointer(
        _bindings,
        eventAddr.value,
      );

      final keyEvent = _toKeyEvent(nativeEvent);
      if (keyEvent == null) return;

      // 기존 listener 들에 KeyEvent 전달
      for (final listener in keyboardListeners.values) {
        listener(keyEvent);
      }
    } finally {
      // 사용 후 반드시 free
      calloc.free(eventAddr);
    }
  }

  // ===========================================================
  // MacOsKeyboardEvent → KeyEvent 변환
  // ===========================================================
  KeyEvent? _toKeyEvent(bindings.MacOsKeyboardEvent event) {
    print(
        'keyevent: toKeyEvent Navite : ${event.keyCode}, ${event.characters}');
    final now = DateTime.now();
    final timeStamp = Duration(milliseconds: now.millisecondsSinceEpoch);

    // MEDIA KEY 처리
    if (event.isMedia) {
      print('keyevent: isMedia ${event.isMedia}');
      final logical = _mediaLogicalKey(event);
      if (logical == null) return null;

      final physical = _mediaPhysicalKey(event, logical);

      if (_isKeyDown(event)) {
        return KeyDownEvent(
          physicalKey: physical,
          logicalKey: logical,
          character: null,
          timeStamp: timeStamp,
        );
      } else {
        return KeyUpEvent(
          physicalKey: physical,
          logicalKey: logical,
          timeStamp: timeStamp,
        );
      }
    }
    print('keyevent: non media');
    // 일반 키 처리
    final physical = _nonMediaPhysicalKey(event);
    final logical = _nonMediaLogicalKey(event);
    final character = event.characters?.toString();
    print(
        "keyevent: dart mapped: physical=${physical.debugName}, logical=${logical.debugName}, char=$character");

    if (_isKeyDown(event)) {
      return KeyDownEvent(
        physicalKey: physical,
        logicalKey: logical,
        character: character,
        timeStamp: timeStamp,
      );
    } else {
      return KeyUpEvent(
        physicalKey: physical,
        logicalKey: logical,
        timeStamp: timeStamp,
      );
    }
  }

  bool _isKeyDown(bindings.MacOsKeyboardEvent e) {
    return e.eventType ==
        bindings.MacOsKeyboardEventType.MacOsKeyboardEventTypeKeyDown;
  }

  // ===========================================================
  // Non-media 키: physical / logical 계산
  // ===========================================================
  PhysicalKeyboardKey _nonMediaPhysicalKey(bindings.MacOsKeyboardEvent event) {
    // 1) macOS keyCode → HID scan code 매핑 (가장 정확한 방법)
    final mapped = kMacOsToPhysicalKey[event.keyCode];
    if (mapped != null) return mapped;

    // 2) fallback: keyCode 기반 HID usage 생성
    return PhysicalKeyboardKey(event.keyCode | 0x70000);
  }

  // ===========================================================
  // 수정된 Logical Key 계산 로직
  // ===========================================================
  LogicalKeyboardKey _nonMediaLogicalKey(bindings.MacOsKeyboardEvent event) {
    // 1. macOS 가상 키코드(KeyCode) 기반 특수키/기능키 매핑 (Enter, Esc, 방향키 등)
    // 이 매핑 테이블이 Physical ID와 Logical ID의 간극을 해결합니다.
    final specialKey = _kMacOsToLogicalKey[event.keyCode];
    if (specialKey != null) {
      return specialKey;
    }

    // 2. 문자 입력 처리 (A-Z, 0-9, 한글, 특수문자 등)
    final charsIgnoring = event.charactersIgnoringModifiers?.toString() ?? "";
    if (charsIgnoring.isNotEmpty) {
      final int cp = charsIgnoring.codeUnitAt(0);

      // 제어문자(ASCII 0-31)가 아닌 실제 문자인 경우에만 유니코드 값으로 LogicalKey 생성
      if (!_isControlCharacter(cp)) {
        // 'A'를 누르면 65(0x41)가 반환되며, 이는 LogicalKeyboardKey.keyA와 일치함
        return LogicalKeyboardKey(cp);
      }
    }

    // 3. Fallback: 정의되지 않은 키는 KeyCode 기반으로 생성
    // (이 경우 시스템에서 인식은 안 될 수 있지만 Crash는 방지함)
    return LogicalKeyboardKey(event.keyCode | 0x1100000000);
  }

  // ===========================================================
  // macOS 가상 키코드 -> LogicalKeyboardKey 매핑 테이블
  // ===========================================================
  static const Map<int, LogicalKeyboardKey> _kMacOsToLogicalKey = {
    36: LogicalKeyboardKey.enter,
    51: LogicalKeyboardKey.backspace,
    48: LogicalKeyboardKey.tab,
    49: LogicalKeyboardKey.space,
    53: LogicalKeyboardKey.escape,
    71: LogicalKeyboardKey.numLock,
    76: LogicalKeyboardKey.enter, // Numpad Enter
    115: LogicalKeyboardKey.home,
    116: LogicalKeyboardKey.pageUp,
    117: LogicalKeyboardKey.delete,
    119: LogicalKeyboardKey.end,
    121: LogicalKeyboardKey.pageDown,
    122: LogicalKeyboardKey.f1,
    120: LogicalKeyboardKey.f2,
    99: LogicalKeyboardKey.f3,
    118: LogicalKeyboardKey.f4,
    96: LogicalKeyboardKey.f5,
    97: LogicalKeyboardKey.f6,
    98: LogicalKeyboardKey.f7,
    100: LogicalKeyboardKey.f8,
    101: LogicalKeyboardKey.f9,
    109: LogicalKeyboardKey.f10,
    103: LogicalKeyboardKey.f11,
    111: LogicalKeyboardKey.f12,
    123: LogicalKeyboardKey.arrowLeft,
    124: LogicalKeyboardKey.arrowRight,
    125: LogicalKeyboardKey.arrowDown,
    126: LogicalKeyboardKey.arrowUp,
    // Modifier keys (flagsChanged 이벤트 대응)
    54: LogicalKeyboardKey.metaRight,
    55: LogicalKeyboardKey.metaLeft,
    56: LogicalKeyboardKey.shiftLeft,
    57: LogicalKeyboardKey.capsLock,
    58: LogicalKeyboardKey.altLeft,
    59: LogicalKeyboardKey.controlLeft,
    60: LogicalKeyboardKey.shiftRight,
    61: LogicalKeyboardKey.altRight,
    62: LogicalKeyboardKey.controlRight,
  };

  bool _isControlCharacter(int cp) {
    // 0x00 ~ 0x1F = ASCII control characters
    // \r = 13, \n = 10, \t = 9 등
    return cp <= 0x1F || cp == 0x7F;
  }

  // ===========================================================
  // Media 키: logical / physical 계산
  // ===========================================================
  LogicalKeyboardKey? _mediaLogicalKey(bindings.MacOsKeyboardEvent event) {
    print('keyevent: event type: ${event.mediaEventType}');
    switch (event.mediaEventType) {
      case bindings.MacOsMediaEventType.MacOsMediaEventTypePlay:
        return LogicalKeyboardKey.mediaPlayPause;
      case bindings.MacOsMediaEventType.MacOsMediaEventTypePrevious:
        return LogicalKeyboardKey.mediaTrackPrevious;
      case bindings.MacOsMediaEventType.MacOsMediaEventTypeNext:
        return LogicalKeyboardKey.mediaTrackNext;
      case bindings.MacOsMediaEventType.MacOsMediaEventTypeRewind:
        return LogicalKeyboardKey.mediaRewind;
      case bindings.MacOsMediaEventType.MacOsMediaEventTypeFast:
        return LogicalKeyboardKey.mediaFastForward;
      case bindings.MacOsMediaEventType.MacOsMediaEventTypeBrightnessUp:
        return LogicalKeyboardKey.brightnessUp;
      case bindings.MacOsMediaEventType.MacOsMediaEventTypeBrightnessDown:
        return LogicalKeyboardKey.brightnessDown;
      case bindings.MacOsMediaEventType.MacOsMediaEventTypeMute:
        return LogicalKeyboardKey.audioVolumeMute;
      case bindings.MacOsMediaEventType.MacOsMediaEventTypeVolumeUp:
        return LogicalKeyboardKey.audioVolumeUp;
      case bindings.MacOsMediaEventType.MacOsMediaEventTypeVolumeDown:
        return LogicalKeyboardKey.audioVolumeDown;
      default:
        return null;
    }
  }

  PhysicalKeyboardKey _mediaPhysicalKey(
    bindings.MacOsKeyboardEvent event,
    LogicalKeyboardKey logical,
  ) {
    // 음소거/볼륨 키는 _muteKeyCode / _volumeUpKeyCode / _volumeDownKeyCode 사용
    switch (event.mediaEventType) {
      case bindings.MacOsMediaEventType.MacOsMediaEventTypeMute:
        return PhysicalKeyboardKey(_muteKeyCode);
      case bindings.MacOsMediaEventType.MacOsMediaEventTypeVolumeUp:
        return PhysicalKeyboardKey(_volumeUpKeyCode);
      case bindings.MacOsMediaEventType.MacOsMediaEventTypeVolumeDown:
        return PhysicalKeyboardKey(_volumeDownKeyCode);
      default:
        // 나머지는 keyCode 기반으로 대충 physical 만들거나,
        // 필요시 별도 매핑 테이블로 개선 가능
        return PhysicalKeyboardKey(event.keyCode);
    }
  }

  // ===========================================================
  // Mouse Processor (그대로 유지)
  // ===========================================================
  void _mouseProc(dynamic e) {
    if (e is! int || e == 0) return;

    final event = shared.mouseProc(e);
    if (event == null) return;

    for (final listener in mouseListeners.values) {
      listener(event);
    }
  }

  // ===========================================================
  // Fields
  // ===========================================================
  final bindings.HidListenerBindingsSwift _bindings;

  late final int _muteKeyCode;
  late final int _volumeUpKeyCode;
  late final int _volumeDownKeyCode;
}
