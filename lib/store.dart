import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// One saved book in the library list on the home screen.
class LibraryEntry {
  final String key; // "filename|filesize" — stable identity of the book
  final String path; // last known file path (may go stale on Android)
  final String name; // display title
  final int totalSentences;
  final int chapterCount;
  final int lastOpenedMs;

  LibraryEntry({
    required this.key,
    required this.path,
    required this.name,
    required this.totalSentences,
    required this.chapterCount,
    required this.lastOpenedMs,
  });

  Map<String, dynamic> toJson() => {
        'key': key,
        'path': path,
        'name': name,
        'total': totalSentences,
        'chapters': chapterCount,
        'opened': lastOpenedMs,
      };

  factory LibraryEntry.fromJson(Map<String, dynamic> m) => LibraryEntry(
        key: m['key'] as String,
        path: m['path'] as String,
        name: m['name'] as String,
        totalSentences: (m['total'] as num?)?.toInt() ?? 0,
        chapterCount: (m['chapters'] as num?)?.toInt() ?? 0,
        lastOpenedMs: (m['opened'] as num?)?.toInt() ?? 0,
      );
}

/// All local persistence in one place, backed by shared_preferences.
/// Stores: reading position per book, speech settings, and the library of
/// saved books. Nothing ever leaves the device.
class Store {
  static late SharedPreferences _prefs;

  /// Call once at app start, before runApp.
  static Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
  }

  // ---------------------------------------------------------------- position

  /// Last spoken sentence index for a book (0 if never opened).
  ///
  /// [bookKey] is "filename|filesize" rather than the full path, because on
  /// Android the file picker copies the file into a cache directory whose
  /// path changes between picks.
  static int positionFor(String bookKey) => _prefs.getInt('pos.$bookKey') ?? 0;

  static Future<void> savePosition(String bookKey, int sentenceIndex) =>
      _prefs.setInt('pos.$bookKey', sentenceIndex);

  static Future<void> removePosition(String bookKey) =>
      _prefs.remove('pos.$bookKey');

  // ---------------------------------------------------------------- settings

  /// Speech rate on our scale: 0.25–1.0 shown as 0.5x–2.0x, 0.5 = normal.
  static double get rate => _prefs.getDouble('rate') ?? 0.5;
  static Future<void> saveRate(double v) => _prefs.setDouble('rate', v);

  /// Selected voice as {name, locale}, or null to use the system default.
  static Map<String, String>? get voice {
    final raw = _prefs.getString('voice');
    if (raw == null) return null;
    final m = jsonDecode(raw) as Map<String, dynamic>;
    return m.map((k, v) => MapEntry(k, v.toString()));
  }

  static Future<void> saveVoice(Map<String, String>? v) => v == null
      ? _prefs.remove('voice')
      : _prefs.setString('voice', jsonEncode(v));

  // ----------------------------------------------------------------- library

  /// Saved books, most recently opened first.
  static List<LibraryEntry> get library {
    final raw = _prefs.getStringList('library') ?? const [];
    final out = <LibraryEntry>[];
    for (final s in raw) {
      try {
        out.add(LibraryEntry.fromJson(jsonDecode(s) as Map<String, dynamic>));
      } catch (_) {
        // skip corrupt entries
      }
    }
    return out;
  }

  /// Insert or update (by key) and move to the front of the list. Returns
  /// the entries evicted past the size cap so the caller can clean up their
  /// disk cache and positions.
  static Future<List<LibraryEntry>> upsertLibrary(LibraryEntry e) async {
    final list = library..removeWhere((x) => x.key == e.key);
    list.insert(0, e);
    final evicted = list.skip(50).toList();
    await _prefs.setStringList(
        'library', list.take(50).map((x) => jsonEncode(x.toJson())).toList());
    return evicted;
  }

  static Future<void> removeLibrary(String key) async {
    final list = library..removeWhere((x) => x.key == key);
    await _prefs.setStringList(
        'library', list.map((x) => jsonEncode(x.toJson())).toList());
  }
}
