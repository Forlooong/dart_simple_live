import 'dart:ffi';
import 'dart:typed_data';
import 'package:ffi/ffi.dart';
import 'wire.dart';

final class DmBuffer extends Struct {
  external Pointer<Uint8> data;
  @UintPtr()
  external int length;
}

@Native<Uint32 Function()>(symbol: 'dm_abi_version')
external int dmAbiVersion();
@Native<Pointer<Void> Function(Uint32)>(symbol: 'dm_create')
external Pointer<Void> dmCreate(int protocol);
@Native<Int32 Function(Pointer<Void>)>(symbol: 'dm_reset')
external int dmReset(Pointer<Void> session);
@Native<Void Function(Pointer<Void>)>(symbol: 'dm_dispose')
external void dmDispose(Pointer<Void> session);
@Native<
  Int32 Function(Pointer<Void>, Pointer<Uint8>, UintPtr, Pointer<DmBuffer>)
>(symbol: 'dm_decode_batch')
external int dmDecode(
  Pointer<Void> session,
  Pointer<Uint8> bytes,
  int length,
  Pointer<DmBuffer> out,
);
@Native<
  Int32 Function(Pointer<Void>, Pointer<Uint8>, UintPtr, Pointer<DmBuffer>)
>(symbol: 'dm_replace_rules')
external int dmReplaceRules(
  Pointer<Void> session,
  Pointer<Uint8> bytes,
  int length,
  Pointer<DmBuffer> out,
);
@Native<
  Int32 Function(Pointer<Void>, Pointer<Uint8>, UintPtr, Pointer<DmBuffer>)
>(symbol: 'dm_filter_batch')
external int dmFilter(
  Pointer<Void> session,
  Pointer<Uint8> bytes,
  int length,
  Pointer<DmBuffer> out,
);
@Native<
  Int32 Function(Pointer<Void>, Pointer<Uint8>, UintPtr, Pointer<DmBuffer>)
>(symbol: 'dm_encode')
external int dmEncode(
  Pointer<Void> session,
  Pointer<Uint8> bytes,
  int length,
  Pointer<DmBuffer> out,
);
@Native<Void Function(Pointer<Uint8>, UintPtr)>(symbol: 'dm_free_buffer')
external void dmFree(Pointer<Uint8> bytes, int length);

class NativeSession {
  NativeSession(int protocol) {
    if (dmAbiVersion() != 1)
      throw StateError('Incompatible danmaku native ABI');
    _handle = dmCreate(protocol);
    if (_handle == nullptr) throw StateError('Cannot create native session');
  }
  late Pointer<Void> _handle;
  Map<String, dynamic> call(String operation, Uint8List data) {
    if (_handle == nullptr) throw StateError('Session disposed');
    if (operation == 'reset') {
      if (dmReset(_handle) != 0) throw StateError('Session reset failed');
      return {'v': 1};
    }
    final input = calloc<Uint8>(data.length == 0 ? 1 : data.length);
    final output = calloc<DmBuffer>();
    try {
      input.asTypedList(data.length).setAll(0, data);
      final status = switch (operation) {
        'decode' => dmDecode(_handle, input, data.length, output),
        'rules' => dmReplaceRules(_handle, input, data.length, output),
        'filter' => dmFilter(_handle, input, data.length, output),
        'encode' => dmEncode(_handle, input, data.length, output),
        _ => throw ArgumentError.value(operation),
      };
      if (output.ref.data == nullptr || output.ref.length > 16 * 1024 * 1024) {
        throw StateError('Native operation failed ($status)');
      }
      final result = decodeWire(
        Uint8List.fromList(output.ref.data.asTypedList(output.ref.length)),
      );
      result['status'] = status;
      return result;
    } finally {
      if (output.ref.data != nullptr)
        dmFree(output.ref.data, output.ref.length);
      calloc.free(output);
      calloc.free(input);
    }
  }

  void dispose() {
    if (_handle != nullptr) {
      dmDispose(_handle);
      _handle = nullptr;
    }
  }
}
