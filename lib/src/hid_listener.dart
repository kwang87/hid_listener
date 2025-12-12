import 'dart:collection';
import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'package:hid_listener/src/macos/hid_listener_macos.dart';
import 'package:hid_listener/src/windows/hid_listener_windows.dart';
import 'package:hid_listener/src/linux/hid_listener_linux.dart';

import 'hid_listener_types.dart';
export 'hid_listener_types.dart'
    show
        MouseEvent,
        MouseButtonEventType,
        MouseButtonEvent,
        MouseMoveEvent,
        MouseWheelEvent;

const String _libName = 'hid_listener';

final ffi.DynamicLibrary _dylib = () {
  if (Platform.isMacOS || Platform.isIOS) {
    return ffi.DynamicLibrary.open('$_libName.framework/$_libName');
  }
  if (Platform.isAndroid || Platform.isLinux) {
    return ffi.DynamicLibrary.open('lib$_libName.so');
  }
  if (Platform.isWindows) {
    return ffi.DynamicLibrary.open('$_libName.dll');
  }
  throw UnsupportedError('Unknown platform: ${Platform.operatingSystem}');
}();

/// 플랫폼별 공통 인터페이스
abstract class HidListenerBackend {
  /// KeyEvent 기반 listener 등록
  int? addKeyboardListener(void Function(KeyEvent) listener) {
    if (!_keyboardRegistered) {
      if (!registerKeyboard()) return null;
      _keyboardRegistered = true;
    }

    keyboardListeners[_lastKeyboardListenerId] = listener;
    return _lastKeyboardListenerId++;
  }

  void removeKeyboardListener(int listenerId) {
    keyboardListeners.remove(listenerId);
  }

  int? addMouseListener(void Function(MouseEvent) listener) {
    if (!_mouseRegistered) {
      if (!registerMouse()) return null;
      _mouseRegistered = true;
    }

    mouseListeners[_lastMouseListenerId] = listener;
    return _lastMouseListenerId++;
  }

  void removeMouseListener(int listenerId) {
    mouseListeners.remove(listenerId);
  }

  void setEnabled(bool enable) {
    print('hid_listener setEnable: $enable');
  }

  bool initialize();
  bool registerKeyboard();
  bool registerMouse();
  // void setEnabled(bool enable);

  // RawKeyEvent 제거 → KeyEvent 전용 Map
  @protected
  HashMap<int, void Function(KeyEvent)> keyboardListeners = HashMap.identity();

  @protected
  HashMap<int, void Function(MouseEvent)> mouseListeners = HashMap.identity();

  int _lastKeyboardListenerId = 0;
  int _lastMouseListenerId = 0;

  bool _keyboardRegistered = false;
  bool _mouseRegistered = false;
}

/// 플랫폼 백엔드 생성
HidListenerBackend? _createPlatformBackend() {
  if (Platform.isWindows) return WindowsHidListenerBackend(_dylib);
  if (Platform.isMacOS) return MacOsHidListenerBackend(_dylib);
  if (Platform.isLinux) return LinuxHidListenerBackend(_dylib);
  return null;
}

HidListenerBackend? _backend = _createPlatformBackend();

HidListenerBackend? getListenerBackend() => _backend;
