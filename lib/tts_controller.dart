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

  bool get _usePiper => !usingSystemVoice;

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

  /// True only if the bundled neural voice failed on this device and we had
  /// to fall back to the platform's own TTS engine for the session.
  bool usingSystemVoice = false;
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

    // Warm the neural voice up in the background right away (unpack on first
    // ever launch, then load the model) so the first press of play is quick
    // instead of a long pause. Failure here is not fatal: play() will retry,
    // and fall back to the system voice if it fails again.
    _piper.init().catchError((e) => debugPrint('Voice warm-up failed: $e'));
  }

  /// Why the neural voice was abandoned this session (shown in the speed
  /// sheet and About dialog so a user can report it), or null if healthy.
  String? fallbackReason;

  /// The bundled voice could not load or synthesize on this device: switch
  /// to the platform's TTS for the rest of the session and keep reading.
  void _fallBackToSystemVoice(Object reason) {
    fallbackReason = _piper.lastError ?? '$reason';
    debugPrint('Neural voice unavailable, using system TTS: $fallbackReason');
    usingSystemVoice = true;
    notifyListeners();
    if (playing) _speakCurrent();
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

  /// The current sentence split into clause-sized pieces for the neural
  /// voice, and which piece is playing. Synthesis time is proportional to
  /// text length, so a 60-word sentence synthesized whole would mean a long
  /// wait before the first word; pieces start playing almost immediately
  /// while the rest are prefetched. The highlight stays on the sentence.
  List<String> _pieces = const [];
  int _pieceIdx = 0;

  double get _neuralSpeed => (rate * 2).clamp(0.5, 2.0);

  /// Neural path: one sentence = one highlight unit, spoken as a chain of
  /// clause pieces with the next piece always synthesizing in the
  /// background — gapless playback plus exact-sentence highlighting.
  Future<void> _speakCurrentPiper() async {
    final b = book!;
    _chunkStart = current;
    _chunkEnd = current + 1;
    _chunkOffsets = const [0];
    _gen++;
    _pendingGen = _gen;
    _pieces = _splitForSynthesis(b.sentences[current]);
    _pieceIdx = 0;
    notifyListeners();
    await _playPiece(_gen);
  }

  /// Synthesize and play piece [_pieceIdx] of the current sentence, then
  /// prefetch whatever comes next (the following piece, or the first piece
  /// of the next sentence).
  Future<void> _playPiece(int gen) async {
    final b = book!;
    final speed = _neuralSpeed;
    preparing = true;
    notifyListeners();
    try {
      if (!_piper.ready) await _piper.init(); // first use: unpack + load model
      final audio = await _piper.synthesize(_pieces[_pieceIdx], speed);
      if (gen != _gen || !playing) return; // superseded while synthesizing
      if (audio == null) {
        _fallBackToSystemVoice('synthesis returned no audio');
        return;
      }
      _startedGen = gen; // the player has no start event; mark it here
      await _piper.play(audio);
      // Queue the next couple of pieces: the rest of this sentence first,
      // then the start of the next sentence.
      final upcoming = <String>[
        ..._pieces.skip(_pieceIdx + 1),
        if (current + 1 < b.sentences.length)
          ..._splitForSynthesis(b.sentences[current + 1]),
      ];
      if (upcoming.isNotEmpty) _piper.prefetch(upcoming, speed);
    } catch (e) {
      if (gen == _gen) _fallBackToSystemVoice(e);
    } finally {
      preparing = false;
      notifyListeners();
    }
  }

  /// Split a sentence at clause punctuation into pieces of a comfortable
  /// size for synthesis (short sentences stay whole). Pieces shorter than
  /// [minPiece] are merged with their neighbour so the voice doesn't chop
  /// "Yes," into its own utterance.
  static List<String> _splitForSynthesis(String sentence) {
    const maxWhole = 140; // sentences up to this many chars stay whole
    const minPiece = 50;
    if (sentence.length <= maxWhole) return [sentence];
    final parts = sentence
        .split(RegExp(r'(?<=[,;:—–])\s+'))
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
    final out = <String>[];
    var buf = '';
    for (final p in parts) {
      buf = buf.isEmpty ? p : '$buf $p';
      if (buf.length >= minPiece) {
        out.add(buf);
        buf = '';
      }
    }
    if (buf.isNotEmpty) {
      if (out.isEmpty) {
        out.add(buf);
      } else {
        out[out.length - 1] = '${out.last} $buf';
      }
    }
    return out.isEmpty ? [sentence] : out;
  }

  void _onUtteranceDone() {
    if (!playing) return;
    if (_startedGen != _gen) return; // stale: from a flushed/stopped utterance
    final b = book;
    if (b == null) return;
    // Neural voice: more pieces of this sentence left? Play the next one
    // (same generation — the sentence hasn't changed).
    if (_usePiper && _pieceIdx + 1 < _pieces.length) {
      _pieceIdx++;
      _playPiece(_gen);
      return;
    }
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

  @override
  void dispose() {
    _tts.stop();
    _piper.dispose();
    super.dispose();
  }
}
