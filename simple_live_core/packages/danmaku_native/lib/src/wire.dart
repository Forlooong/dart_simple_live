import 'dart:convert';
import 'dart:typed_data';

Uint8List utf16Bytes(String text) {
  final bytes = ByteData(text.length * 2);
  for (var i = 0; i < text.length; i++) {
    bytes.setUint16(i * 2, text.codeUnitAt(i), Endian.little);
  }
  return bytes.buffer.asUint8List();
}

String utf16String(Object? value) {
  final bytes = value as Uint8List;
  if (bytes.length.isOdd) throw const FormatException('Odd UTF-16 payload');
  final data = ByteData.sublistView(bytes);
  return String.fromCharCodes(
    List.generate(
      bytes.length ~/ 2,
      (i) => data.getUint16(i * 2, Endian.little),
    ),
  );
}

/// The small, definite-length CBOR subset used by ABI v1. No external objects,
/// indefinite lengths, tags or floats cross the native boundary.
Uint8List encodeWire(Object? value) {
  final out = BytesBuilder(copy: false);
  void header(int major, int size) {
    if (size < 24) {
      out.addByte((major << 5) | size);
    } else {
      final count = size <= 0xff
          ? 1
          : size <= 0xffff
          ? 2
          : size <= 0xffffffff
          ? 4
          : 8;
      out.addByte((major << 5) | {1: 24, 2: 25, 4: 26, 8: 27}[count]!);
      for (var i = count - 1; i >= 0; i--) out.addByte((size >> (i * 8)) & 255);
    }
  }

  void write(Object? item) {
    if (item == null) {
      out.addByte(246);
    } else if (item is bool) {
      out.addByte(item ? 245 : 244);
    } else if (item is int) {
      header(item < 0 ? 1 : 0, item < 0 ? -1 - item : item);
    } else if (item is Uint8List) {
      header(2, item.length);
      out.add(item);
    } else if (item is String) {
      final data = utf8.encode(item);
      header(3, data.length);
      out.add(data);
    } else if (item is List) {
      header(4, item.length);
      for (final e in item) write(e);
    } else if (item is Map) {
      header(5, item.length);
      item.forEach((k, v) {
        write(k);
        write(v);
      });
    } else {
      throw ArgumentError('Unsupported wire value');
    }
  }

  write(value);
  return out.takeBytes();
}

Map<String, dynamic> decodeWire(Uint8List bytes) {
  if (bytes.length > 16 * 1024 * 1024)
    throw const FormatException('Wire limit');
  var offset = 0;
  int byte() {
    if (offset == bytes.length) throw const FormatException('Truncated CBOR');
    return bytes[offset++];
  }

  Object? read(int depth) {
    if (depth > 32) throw const FormatException('CBOR depth');
    final first = byte(), major = first >> 5, info = first & 31;
    if (major == 7) {
      return switch (info) {
        20 => false,
        21 => true,
        22 => null,
        _ => throw const FormatException('CBOR simple'),
      };
    }
    var length = info;
    if (info >= 24) {
      final count = switch (info) {
        24 => 1,
        25 => 2,
        26 => 4,
        27 => 8,
        _ => throw const FormatException('CBOR length'),
      };
      length = 0;
      for (var i = 0; i < count; i++) length = (length << 8) | byte();
    }
    if ((major == 0 || major == 1) && length < 0)
      throw const FormatException('CBOR integer exceeds signed ABI range');
    if (major == 0) return length;
    if (major == 1) return -1 - length;
    if (length < 0 || length > bytes.length - offset)
      throw const FormatException('CBOR size');
    if (major == 2 || major == 3) {
      final data = Uint8List.sublistView(bytes, offset, offset + length);
      offset += length;
      return major == 2 ? data : utf8.decode(data);
    }
    if (major == 4) return List.generate(length, (_) => read(depth + 1));
    if (major == 5) {
      final map = <String, dynamic>{};
      for (var i = 0; i < length; i++) {
        final key = read(depth + 1);
        if (key is! String || map.containsKey(key))
          throw const FormatException('CBOR key');
        map[key] = read(depth + 1);
      }
      return map;
    }
    throw const FormatException('CBOR type');
  }

  final result = read(0);
  if (offset != bytes.length ||
      result is! Map<String, dynamic> ||
      result['v'] != 1) {
    throw const FormatException('Invalid ABI payload');
  }
  return result;
}
