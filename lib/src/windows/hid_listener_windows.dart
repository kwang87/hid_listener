import 'dart:ffi' as ffi;
import 'dart:isolate';

import 'package:flutter/services.dart';
import 'package:hid_listener/src/hid_listener.dart';
import 'package:hid_listener/src/shared/hid_listener_shared.dart' as shared;

import 'hid_listener_bindings_windows.dart' as bindings;

class WindowsHidListenerBackend extends HidListenerBackend {
  WindowsHidListenerBackend(ffi.DynamicLibrary library)
      : _bindings = bindings.HidListenerBindingsWindows(library) {
    _bindings.InitializeDartAPI(ffi.NativeApi.initializeApiDLData);
  }

  @override
  bool initialize() => _bindings.InitializeListeners();

  @override
  bool registerKeyboard() {
    final requests = ReceivePort()..listen(_keyboardProc);
    return _bindings.SetKeyboardListener(requests.sendPort.nativePort);
  }

  @override
  bool registerMouse() {
    final requests = ReceivePort()..listen(_mouseProc);
    return _bindings.SetMouseListener(requests.sendPort.nativePort);
  }

  // ===========================================================
  // KeyEvent Processor
  // ===========================================================
  void _keyboardProc(dynamic event) {
    if (event is! int || event == 0) return;

    final ptr = ffi.Pointer<bindings.WindowsKeyboardEvent>.fromAddress(event);

    final vkCode = ptr.ref.vkCode;
    final isDown =
        ptr.ref.eventType == bindings.WindowsKeyboardEventType.WKE_KeyDown;

    // physical key
    final physicalKey =
        kWindowsToPhysicalKey[vkCode] ?? PhysicalKeyboardKey(vkCode);

    // logical key
    final logicalKey = LogicalKeyboardKey(vkCode);

    final timestamp = Duration(
      milliseconds: DateTime.now().millisecondsSinceEpoch,
    );

    final KeyEvent keyEvent = isDown
        ? KeyDownEvent(
            physicalKey: physicalKey,
            logicalKey: logicalKey,
            character: null, // Windows API 자체에서 character 제공 없음
            timeStamp: timestamp,
          )
        : KeyUpEvent(
            physicalKey: physicalKey,
            logicalKey: logicalKey,
            timeStamp: timestamp,
          );

    for (final listener in keyboardListeners.values) {
      listener(keyEvent);
    }
  }

  // ===========================================================
  // Mouse
  // ===========================================================
  void _mouseProc(dynamic e) {
    final event = shared.mouseProc(e);
    if (event == null) return;

    for (final listener in mouseListeners.values) {
      listener(event);
    }
  }

  final bindings.HidListenerBindingsWindows _bindings;
}
