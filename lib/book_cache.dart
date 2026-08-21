import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'text_extraction.dart';

/// Disk cache for extracted books, so a book is parsed exactly once and every
/// later open is instant. One gzipped JSON file per book under the app's
/// support directory, keyed by the same "name|size" key used for positions.
class BookCache {
  /// Stable non-cryptographic hash (FNV-1a). String.hashCode is not
  /// guaranteed stable across Dart versions, and the cache must survive
  /// app upgrades.
  static String _fnv(String s) {
    var h = 0x811c9dc5;
    for (final c in s.codeUnits) {
      h = ((h ^ c) * 0x01000193) & 0xFFFFFFFF;
    }
    return h.toRadixString(16).padLeft(8, '0');
  }

  static Future<File> _fileFor(String bookKey) async {
    final dir = await getApplicationSupportDirectory();
    final d = Directory('${dir.path}${Platform.pathSeparator}book_cache');
    await d.create(recursive: true);
    var safe = bookKey.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    if (safe.length > 60) safe = safe.substring(0, 60);
    return File(
        '${d.path}${Platform.pathSeparator}${_fnv(bookKey)}_$safe.json.gz');
  }

  /// Returns the cached book, or null if absent/corrupt (corrupt files are
  /// deleted so the next open re-extracts cleanly).
  static Future<ExtractedBook?> load(String bookKey) async {
    File? f;
    try {
      f = await _fileFor(bookKey);
      if (!await f.exists()) return null;
      final map = jsonDecode(utf8.decode(gzip.decode(await f.readAsBytes())))
          as Map<String, dynamic>;
      if (map['v'] != 2) return null; // format changed -> re-extract
      return ExtractedBook.fromJson(map);
    } catch (_) {
      try {
        await f?.delete();
      } catch (_) {}
      return null;
    }
  }

  static Future<void> save(String bookKey, ExtractedBook book) async {
    try {
      final f = await _fileFor(bookKey);
      await f.writeAsBytes(gzip.encode(utf8.encode(jsonEncode(book.toJson()))));
    } catch (_) {
      // Cache is an optimization only — never let it break opening a book.
    }
  }

  static Future<void> remove(String bookKey) async {
    try {
      final f = await _fileFor(bookKey);
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }
}
