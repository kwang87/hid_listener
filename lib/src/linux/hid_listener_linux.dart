import 'dart:ffi' as ffi;
import 'dart:isolate';
import 'dart:ui';

import 'package:flutter/services.dart';
import 'package:hid_listener/src/hid_listener.dart';
import 'package:hid_listener/src/shared/hid_listener_shared.dart' as shared;

import 'hid_listener_bindings_linux.dart' as bindings;

class LinuxHidListenerBackend extends HidListenerBackend {
  LinuxHidListenerBackend(ffi.DynamicLibrary library)
      : _bindings = bindings.HidListenerBindingsLinux(library) {
    _bindings.InitializeDartAPI(ffi.NativeApi.initializeApiDLData);
  }

  @override
  bool initialize() => _bindings.InitializeListeners();

  @override
  bool registerKeyboard() {
    final req = ReceivePort()..listen(_keyboardProc);
    return _bindings.SetKeyboardListener(req.sendPort.nativePort);
  }

  @override
  bool registerMouse() {
    final req = ReceivePort()..listen(_mouseProc);
    return _bindings.SetMouseListener(req.sendPort.nativePort);
  }

  // ===========================================================
  // KEY EVENT PROCESSOR (KeyEvent 기반)
  // ===========================================================
  void _keyboardProc(dynamic e) {
    if (e is! int || e == 0) return;

    final ptr = ffi.Pointer<bindings.LinuxKeyboardEvent>.fromAddress(e);
    final ref = ptr.ref;

    final isDown = ref.eventType == bindings.LinuxKeyboardEventType.LKE_KeyDown;

    // X11 keycode → Physical key mapping fallback
    PhysicalKeyboardKey physical =
        PhysicalKeyboardKey.findKeyByCode(ref.scanCode) ??
            PhysicalKeyboardKey.findKeyByCode(ref.keyCode) ??
            PhysicalKeyboardKey(ref.keyCode);

    LogicalKeyboardKey logical =
        LogicalKeyboardKey.findKeyByKeyId(ref.keyCode) ??
            LogicalKeyboardKey(ref.keyCode);

    final timestamp =
        Duration(milliseconds: DateTime.now().millisecondsSinceEpoch);

    final String? character = ref.unicodeScalarValues == 0
        ? null
        : String.fromCharCode(ref.unicodeScalarValues);

    final KeyEvent keyEvent = isDown
        ? KeyDownEvent(
            physicalKey: physical,
            logicalKey: logical,
            character: character,
            timeStamp: timestamp,
          )
        : KeyUpEvent(
            physicalKey: physical,
            logicalKey: logical,
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

  final bindings.HidListenerBindingsLinux _bindings;
}
