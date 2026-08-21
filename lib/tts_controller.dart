import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';

import 'piper_engine.dart';
import 'store.dart';
import 'text_extraction.dart';

/// Drives continuous playback of a book through the system TTS engine.
///
/// Strategy: speak MULTI-SENTENCE CHUNKS (consecutive sentences of one
/// paragraph, capped well below Android's ~4000-char utterance limit). Fewer
/// utterance boundaries means fewer audible gaps — this is what smooths out
/// the "blocky" feel of sentence-at-a-time playback. The next chunk is queued
/// from the completion callback so playback flows through the whole book.
///
/// Highlighting granularity differs per platform:
///  - Android reports word progress (onRangeStart), so [current] advances
///    sentence by sentence *within* a speaking chunk.
///  - Windows has no progress events; the reader highlights the whole chunk
///    ([highlightStart]..[highlightEnd]) while it plays.
///
/// Pause is implemented as "stop + remember where we were": flutter_tts can't
/// pause mid-utterance on every platform, and restarting the current sentence
/// on resume is simple and predictable.
class TtsController extends ChangeNotifier {
  /// Max characters per spoken chunk (single sentences may exceed this up to
  /// [maxSentenceChars]; both stay far below Android's ~4000-char cap).
  static const int maxChunkChars = 2200;

  final FlutterTts _tts = FlutterTts();
  final PiperEngine _piper = PiperEngine();

  ExtractedBook? book;
  String _bookKey = '';

  /// True while the neural engine is loading its model or synthesizing the
  /// first sentence after Play — the UI shows a spinner instead of dead air.
  bool preparing = false;

  bool get _usePiper => voice?['engine'] == 'piper';

  /// Index of the sentence being (or about to be) spoken.
  int current = 0;
  bool playing = false;

  /// Sentence range [start, end) of the utterance being spoken.
  int _chunkStart = 0;
  int _chunkEnd = 0;

  /// Char offset of each chunk sentence within the spoken text, for mapping
  /// Android word-progress events back to a sentence index.
  List<int> _chunkOffsets = const [];

  /// Becomes true after the first word-progress event (Android). Until then
  /// the reader highlights whole chunks.
  bool progressSeen = false;

  /// Highlight range for the reader: exact sentence where progress events
  /// exist, the whole speaking chunk where they don't.
  int get highlightStart => playing && !progressSeen ? _chunkStart : current;
  int get highlightEnd => playing && !progressSeen ? _chunkEnd : current + 1;

  /// System voices as {name, locale} maps, sorted by locale then name.
  List<Map<String, String>> voices = [];
  Map<String, String>? voice; // null = system default
  double rate = 0.5; // our scale: 0.25–1.0 shown as 0.5x–2.0x, 0.5 = normal

  /// Utterance generation guard. Completion/progress events arrive
  /// asynchronously, so an utterance that finished naturally *while* we were
  /// seeking/changing rate could otherwise advance [current] a second time
  /// and skip a sentence. Every _speakCurrent() bumps [_gen]; the start
  /// handler records which generation actually began speaking; events from
  /// any other generation are stale and ignored.
  int _gen = 0;
  int _startedGen = -1;

  /// Generation of the most recently SUBMITTED utterance. The start handler
  /// stamps this (not the live [_gen]) so an old utterance that begins
  /// playing late can never masquerade as a newer request.
  int _pendingGen = 0;

  bool _initialized = false;

  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;

    rate = Store.rate;
    await _applyRate();
    // Chain chunks: when one finishes, immediately speak the next.
    _tts.setStartHandler(() => _startedGen = _pendingGen);
    _tts.setCompletionHandler(_onUtteranceDone);
    _tts.setProgressHandler(_onProgress);
    _tts.setErrorHandler((msg) {
      debugPrint('TTS error: $msg');
      playing = false;
      notifyListeners();
    });

    _piper
      ..bindCompletion()
      ..onComplete = _onUtteranceDone;

    await _loadVoices();
    final saved = Store.voice;
    if (saved != null && voices.any((v) => v['name'] == saved['name'])) {
      await setVoice(saved);
    }
  }

  Future<void> _loadVoices() async {
    try {
      final raw = await _tts.getVoices;
      voices = [
        for (final v in (raw as List))
          {
            'name': '${(v as Map)['name']}',
            'locale': '${v['locale']}',
          }
      ]..sort((a, b) {
          final l = a['locale']!.compareTo(b['locale']!);
          return l != 0 ? l : a['name']!.compareTo(b['name']!);
        });
    } catch (e) {
      debugPrint('Could not list voices: $e');
      voices = [];
    }
    // The bundled neural voice always tops the list.
    voices.insert(0, {
      'name': PiperEngine.voiceName,
      'locale': PiperEngine.voiceLocale,
      'engine': 'piper',
    });
  }

  /// Attach a freshly loaded book and restore its saved position.
  void loadBook(ExtractedBook b, String bookKey) {
    stop();
    book = b;
    _bookKey = bookKey;
    current = b.sentences.isEmpty
        ? 0
        : Store.positionFor(bookKey).clamp(0, b.sentences.length - 1);
    _chunkStart = current;
    _chunkEnd = current;
    // Progress support is a property of the active voice/engine, so it must
    // be re-detected — a book or voice switch may land on an engine that
    // never reports progress, where the whole-chunk highlight is needed.
    progressSeen = false;
    notifyListeners();
  }

  // ---------------------------------------------------------------- playback

  Future<void> play() async {
    if (book == null || book!.sentences.isEmpty) return;
    playing = true;
    notifyListeners();
    await _speakCurrent();
  }

  Future<void> pause() async {
    playing = false;
    notifyListeners();
    await _tts.stop(); // resume will restart the current sentence
    await _piper.stop();
  }

  Future<void> stop() async {
    playing = false;
    notifyListeners();
    await _tts.stop();
    await _piper.stop();
  }

  Future<void> togglePlay() => playing ? pause() : play();

  /// Builds the chunk starting at [current]: consecutive sentences of the
  /// same paragraph, until [maxChunkChars]. Always includes at least the
  /// current sentence.
  String _buildChunk() {
    final b = book!;
    _chunkStart = current;
    final para = b.paragraphOf[current];
    final buf = StringBuffer();
    final offsets = <int>[];
    var i = current;
    while (i < b.sentences.length && b.paragraphOf[i] == para) {
      final s = b.sentences[i];
      if (buf.isNotEmpty && buf.length + 1 + s.length > maxChunkChars) break;
      if (buf.isNotEmpty) buf.write(' ');
      offsets.add(buf.length);
      buf.write(s);
      i++;
    }
    _chunkOffsets = offsets;
    _chunkEnd = i;
    return buf.toString();
  }

  Future<void> _speakCurrent() async {
    final b = book;
    if (!playing || b == null || b.sentences.isEmpty) return;
    if (_usePiper) {
      await _speakCurrentPiper();
      return;
    }
    final text = _buildChunk();
    _gen++; // invalidate any event still in flight from an older utterance
    _pendingGen = _gen;
    final gen = _gen;
    notifyListeners(); // chunk bounds changed — reader updates highlight
    final result = await _tts.speak(text);
    if (result != 1 && gen == _gen && playing) {
      // Windows silently DROPS speak() while a previous utterance is still
      // playing (it answers 0). This happens when a completion raced a
      // seek/rate change. Kill the stale utterance and retry ours — unless a
      // newer request superseded us while we awaited.
      await _tts.stop();
      if (gen == _gen && playing) await _speakCurrent();
    }
  }

  /// Neural path: ONE sentence per utterance (synthesis latency is the
  /// bottleneck), with the next sentence prefetched while this one plays —
  /// gapless playback plus exact-sentence highlighting on every platform.
  Future<void> _speakCurrentPiper() async {
    final b = book!;
    _chunkStart = current;
    _chunkEnd = current + 1;
    _chunkOffsets = const [0];
    _gen++;
    _pendingGen = _gen;
    final gen = _gen;
    final speed = (rate * 2).clamp(0.5, 2.0);
    preparing = true;
    notifyListeners();
    try {
      if (!_piper.ready) await _piper.init(); // first use: unpack + load model
      final audio = await _piper.synthesize(b.sentences[current], speed);
      if (gen != _gen || !playing) return; // superseded while synthesizing
      if (audio == null) {
        playing = false;
        return;
      }
      _startedGen = gen; // the player has no start event; mark it here
      await _piper.play(audio);
      if (current + 1 < b.sentences.length) {
        _piper.prefetch(b.sentences[current + 1], speed);
      }
    } catch (e) {
      debugPrint('Neural voice failed: $e');
      playing = false;
    } finally {
      preparing = false;
      notifyListeners();
    }
  }

  void _onUtteranceDone() {
    if (!playing) return;
    if (_startedGen != _gen) return; // stale: from a flushed/stopped utterance
    final b = book;
    if (b == null) return;
    if (_chunkEnd >= b.sentences.length) {
      // End of the book. Keep [current] on the last sentence so every index
      // stays valid; pressing play again re-reads from there.
      current = b.sentences.length - 1;
      playing = false;
      Store.savePosition(_bookKey, current);
      notifyListeners();
      return;
    }
    current = _chunkEnd;
    Store.savePosition(_bookKey, current);
    notifyListeners();
    _speakCurrent();
  }

  /// Android word-progress: map the character offset into a sentence index
  /// so the highlight tracks the voice through the chunk.
  void _onProgress(String text, int start, int end, String word) {
    if (!playing || _startedGen != _gen) return;
    progressSeen = true;
    var idx = _chunkStart;
    for (var k = _chunkOffsets.length - 1; k >= 0; k--) {
      if (_chunkOffsets[k] <= start) {
        idx = _chunkStart + k;
        break;
      }
    }
    if (idx != current) {
      current = idx;
      Store.savePosition(_bookKey, current);
      notifyListeners();
    }
  }

  // -------------------------------------------------------------- navigation

  /// Jump to an absolute sentence index (also used for tap-to-play).
  Future<void> seek(int index) async {
    final b = book;
    if (b == null || b.sentences.isEmpty) return;
    await _tts.stop();
    await _piper.stop();
    current = index.clamp(0, b.sentences.length - 1);
    _chunkStart = current;
    _chunkEnd = current;
    Store.savePosition(_bookKey, current);
    notifyListeners();
    if (playing) await _speakCurrent();
  }

  Future<void> nextSentence() => seek(current + 1);
  Future<void> previousSentence() => seek(current - 1);

  /// Jump to the first sentence of the next/previous paragraph.
  Future<void> nextParagraph() => _jumpParagraph(1);
  Future<void> previousParagraph() => _jumpParagraph(-1);

  Future<void> _jumpParagraph(int delta) async {
    final b = book;
    if (b == null || b.sentences.isEmpty) return;
    final para =
        (b.paragraphOf[current] + delta).clamp(0, b.paragraphStart.length - 1);
    await seek(b.paragraphStart[para]);
  }

  // ---------------------------------------------------------------- chapters

  /// Index into book.chapters of the chapter containing [current], or -1.
  int get currentChapter {
    final b = book;
    if (b == null || b.chapters.isEmpty || b.sentences.isEmpty) return -1;
    final para = b.paragraphOf[current.clamp(0, b.paragraphOf.length - 1)];
    var lo = 0, hi = b.chapters.length - 1, ans = -1;
    while (lo <= hi) {
      final mid = (lo + hi) ~/ 2;
      if (b.chapters[mid].paragraph <= para) {
        ans = mid;
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }
    return ans;
  }

  Future<void> seekChapter(int chapterIndex) async {
    final b = book;
    if (b == null || chapterIndex < 0 || chapterIndex >= b.chapters.length) {
      return;
    }
    await seek(b.paragraphStart[b.chapters[chapterIndex].paragraph]);
  }

  // ---------------------------------------------------------------- settings

  /// flutter_tts rate scales differ per platform: on Android 0.5 means
  /// normal speed, but on Windows the value is passed to WinRT as
  /// SpeakingRate = value + 0.5 where 1.0 is normal. Translate our
  /// 0.25–1.0 (= 0.5x–2.0x) scale so the slider is honest on both.
  Future<void> _applyRate() async {
    if (!kIsWeb && Platform.isWindows) {
      final multiplier = (rate * 2).clamp(0.5, 2.0);
      await _tts.setSpeechRate(multiplier - 0.5);
    } else {
      await _tts.setSpeechRate(rate);
    }
  }

  Future<void> setRate(double v) async {
    rate = v;
    await Store.saveRate(v);
    await _applyRate();
    notifyListeners();
    // A rate change only affects the NEXT utterance; restart the current
    // sentence so the slider feels immediate.
    if (playing) {
      await _tts.stop();
      await _piper.stop();
      await _speakCurrent();
    }
  }

  Future<void> setVoice(Map<String, String>? v) async {
    voice = v;
    progressSeen = false; // the new voice may not report word progress
    await Store.saveVoice(v);
    if (v != null && v['engine'] != 'piper') {
      await _tts.setVoice({'name': v['name']!, 'locale': v['locale']!});
    }
    notifyListeners();
    if (playing) {
      await _tts.stop();
      await _piper.stop();
      await _speakCurrent();
    }
  }

  @override
  void dispose() {
    _tts.stop();
    _piper.dispose();
    super.dispose();
  }
}
