import 'dart:ffi';
import 'package:ffi/ffi.dart';

const _asset = 'package:dart_quickjs/src/quickjs_bindings.g.dart';
@Native<Pointer<Void> Function()>(symbol: 'sl_regex_create', assetId: _asset)
external Pointer<Void> _create();
@Native<Void Function(Pointer<Void>)>(symbol: 'sl_regex_begin', assetId: _asset)
external void _begin(Pointer<Void> handle);
@Native<Int32 Function(Pointer<Void>, Pointer<Uint16>, Uint32)>(
  symbol: 'sl_regex_add',
  assetId: _asset,
)
external int _add(Pointer<Void> handle, Pointer<Uint16> text, int length);
@Native<Int32 Function(Pointer<Void>, Pointer<Uint16>, Uint32)>(
  symbol: 'sl_regex_match',
  assetId: _asset,
)
external int _match(Pointer<Void> handle, Pointer<Uint16> text, int length);
@Native<Void Function(Pointer<Void>)>(
  symbol: 'sl_regex_destroy',
  assetId: _asset,
)
external void _destroy(Pointer<Void> handle);

/// Own on one worker; no Dart callback runs inside the native engine.
class ControlledRegex {
  ControlledRegex(List<String> patterns) {
    _handle = _create();
    if (_handle == nullptr) throw StateError('Cannot create regex runtime');
    try {
      _begin(_handle);
      for (final pattern in patterns) {
        final result = _withText(pattern, _add);
        if (result != 0) throw StateError('Regex compilation failed ($result)');
      }
    } catch (_) {
      dispose();
      rethrow;
    }
  }
  late Pointer<Void> _handle;
  int _withText(
    String value,
    int Function(Pointer<Void>, Pointer<Uint16>, int) fn,
  ) {
    final text = calloc<Uint16>(value.isEmpty ? 1 : value.length);
    try {
      text.asTypedList(value.length).setAll(0, value.codeUnits);
      return fn(_handle, text, value.length);
    } finally {
      calloc.free(text);
    }
  }

  List<bool> keep(List<String> values) {
    if (_handle == nullptr) throw StateError('Regex runtime disposed');
    _begin(_handle);
    return values
        .map((text) {
          final result = _withText(text, _match);
          if (result < 0) throw StateError('Regex execution stopped ($result)');
          return result == 0;
        })
        .toList(growable: false);
  }

  void dispose() {
    if (_handle != nullptr) {
      _destroy(_handle);
      _handle = nullptr;
    }
  }
}
