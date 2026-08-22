import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

/// Offline neural TTS: the Kokoro model (English, int8) run through
/// sherpa-onnx, speaking with its British male voice.
///
/// The model ships inside the app as a zip asset and is extracted to the app
/// support directory on first use. Synthesis runs on a dedicated worker
/// isolate that loads the model ONCE and stays alive (generation is
/// synchronous FFI — running it on the UI isolate would freeze the app).
/// Playback: samples are written as a WAV file and played with audioplayers;
/// [onComplete] fires when a sentence finishes playing.
///
/// Fully offline: the model is a local file, synthesis and playback never
/// touch the network.
class PiperEngine {
  /// Shown in About / licenses.
  static const voiceName = 'George (Kokoro neural voice, British English)';

  static const _assetZip = 'assets/kokoro_en.zip';

  /// Kokoro v0.19 speaker ids (from the model's README):
  /// 0 af, 1 af_bella, 2 af_nicole, 3 af_sarah, 4 af_sky, 5 am_adam,
  /// 6 am_michael, 7 bf_emma, 8 bf_isabella, 9 bm_george, 10 bm_lewis.
  static const speakerId = 9; // bm_george

  final AudioPlayer _player = AudioPlayer();

  /// Fires when a spoken sentence finishes playing (not on stop()).
  void Function()? onComplete;

  Isolate? _isolate;
  SendPort? _toWorker;
  final _pending = <int, Completer<PiperAudio?>>{};
  int _nextId = 0;
  StreamSubscription? _fromWorkerSub;

  String _dir = '';
  bool _wavFlip = false; // alternate two wav files so play/write never clash

  /// Prefetch cache (a couple of entries deep): the next pieces of speech
  /// are synthesized while the current one plays, which is what makes
  /// playback gapless. Keyed by "speed|text".
  final _prefetch = <String, Future<PiperAudio?>>{};
  static const _prefetchDepth = 2;

  bool get ready => _toWorker != null;

  /// Extract the model (first ever use) and start the worker isolate.
  /// Safe to call repeatedly; only the first call does work.
  Future<void> init() async {
    if (ready) return;
    _dir = await _installModel();

    final fromWorker = ReceivePort();
    final readyCompleter = Completer<SendPort>();
    _fromWorkerSub = fromWorker.listen((msg) {
      if (msg is SendPort) {
        readyCompleter.complete(msg);
        return;
      }
      if (msg is String) {
        // Worker failed to load the model.
        if (!readyCompleter.isCompleted) {
          readyCompleter.completeError(StateError(msg));
        }
        return;
      }
      final list = msg as List;
      final id = list[0] as int;
      final c = _pending.remove(id);
      if (c == null) return;
      if (list[1] == null) {
        debugPrint('Synthesis failed: ${list.length > 3 ? list[3] : ''}');
        c.complete(null);
      } else {
        c.complete(PiperAudio(list[1] as Float32List, list[2] as int));
      }
    });

    _isolate = await Isolate.spawn(
        _ttsWorker, _WorkerArgs(fromWorker.sendPort, _dir));
    try {
      _toWorker = await readyCompleter.future.timeout(
        const Duration(seconds: 90),
        onTimeout: () => throw TimeoutException('voice model failed to load'),
      );
    } catch (_) {
      dispose();
      rethrow;
    }
  }

  /// Unpack the asset zip into the support dir once; a marker file makes
  /// later launches skip straight past this.
  Future<String> _installModel() async {
    final support = await getApplicationSupportDirectory();
    final dir = Directory('${support.path}${Platform.pathSeparator}kokoro_en');
    final marker = File('${dir.path}${Platform.pathSeparator}.installed');
    if (await marker.exists()) return dir.path;

    final data = await rootBundle.load(_assetZip);
    final archive = ZipDecoder().decodeBytes(
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes));
    for (final entry in archive) {
      final outPath =
          '${dir.path}${Platform.pathSeparator}${entry.name.replaceAll('/', Platform.pathSeparator)}';
      if (entry.isFile) {
        final out = File(outPath);
        await out.create(recursive: true);
        await out.writeAsBytes(entry.content as List<int>);
      } else {
        await Directory(outPath).create(recursive: true);
      }
    }
    await marker.writeAsString('ok');
    return dir.path;
  }

  /// Synthesize [text]; consumes a prefetched result when one matches.
  Future<PiperAudio?> synthesize(String text, double speed) {
    final key = '$speed|$text';
    final cached = _prefetch.remove(key);
    return cached ?? _request(text, speed);
  }

  /// Start synthesizing upcoming [texts] in the background (at most
  /// [_prefetchDepth] outstanding; older entries are dropped).
  void prefetch(List<String> texts, double speed) {
    for (final text in texts.take(_prefetchDepth)) {
      final key = '$speed|$text';
      if (_prefetch.containsKey(key)) continue;
      _prefetch[key] = _request(text, speed);
    }
    while (_prefetch.length > _prefetchDepth) {
      _prefetch.remove(_prefetch.keys.first);
    }
  }

  Future<PiperAudio?> _request(String text, double speed) {
    final to = _toWorker;
    if (to == null) return Future.value(null);
    final id = _nextId++;
    final c = Completer<PiperAudio?>();
    _pending[id] = c;
    to.send([id, text, speed]);
    return c.future;
  }

  /// Play synthesized audio; [onComplete] fires when it ends naturally.
  Future<void> play(PiperAudio audio) async {
    final path =
        '$_dir${Platform.pathSeparator}utt_${_wavFlip ? 'a' : 'b'}.wav';
    _wavFlip = !_wavFlip;
    await File(path).writeAsBytes(_wav16(audio.samples, audio.sampleRate));
    await _player.stop();
    await _player.play(DeviceFileSource(path));
  }

  Future<void> stop() => _player.stop();

  void dispose() {
    _player.dispose();
    _fromWorkerSub?.cancel();
    _toWorker?.send('quit');
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    _toWorker = null;
    for (final c in _pending.values) {
      c.complete(null);
    }
    _pending.clear();
  }

  /// Hook up the player's completion stream once.
  void bindCompletion() {
    _player.onPlayerComplete.listen((_) => onComplete?.call());
  }

  /// Float32 [-1,1] samples -> 16-bit PCM WAV bytes.
  static Uint8List _wav16(Float32List samples, int sampleRate) {
    final data = ByteData(44 + samples.length * 2);
    void str(int o, String s) {
      for (var i = 0; i < s.length; i++) {
        data.setUint8(o + i, s.codeUnitAt(i));
      }
    }

    str(0, 'RIFF');
    data.setUint32(4, 36 + samples.length * 2, Endian.little);
    str(8, 'WAVE');
    str(12, 'fmt ');
    data.setUint32(16, 16, Endian.little); // PCM header size
    data.setUint16(20, 1, Endian.little); // PCM
    data.setUint16(22, 1, Endian.little); // mono
    data.setUint32(24, sampleRate, Endian.little);
    data.setUint32(28, sampleRate * 2, Endian.little); // byte rate
    data.setUint16(32, 2, Endian.little); // block align
    data.setUint16(34, 16, Endian.little); // bits per sample
    str(36, 'data');
    data.setUint32(40, samples.length * 2, Endian.little);
    for (var i = 0; i < samples.length; i++) {
      data.setInt16(44 + i * 2, (samples[i].clamp(-1.0, 1.0) * 32767).round(),
          Endian.little);
    }
    return data.buffer.asUint8List();
  }
}

class PiperAudio {
  final Float32List samples;
  final int sampleRate;
  PiperAudio(this.samples, this.sampleRate);
}

class _WorkerArgs {
  final SendPort main;
  final String dir;
  _WorkerArgs(this.main, this.dir);
}

/// Worker isolate: load the model once, then serve generate requests forever.
Future<void> _ttsWorker(_WorkerArgs args) async {
  final sep = Platform.pathSeparator;
  sherpa.OfflineTts tts;
  try {
    sherpa.initBindings();
    tts = sherpa.OfflineTts(sherpa.OfflineTtsConfig(
      model: sherpa.OfflineTtsModelConfig(
        kokoro: sherpa.OfflineTtsKokoroModelConfig(
          model: '${args.dir}${sep}model.int8.onnx',
          voices: '${args.dir}${sep}voices.bin',
          tokens: '${args.dir}${sep}tokens.txt',
          dataDir: '${args.dir}${sep}espeak-ng-data',
        ),
        // Synthesis is the bottleneck: use most of the cores, leave one
        // for the UI and audio.
        numThreads: (Platform.numberOfProcessors - 1).clamp(2, 6),
        debug: false,
      ),
    ));
  } catch (e) {
    args.main.send('model load failed: $e');
    return;
  }
  final port = ReceivePort();
  args.main.send(port.sendPort);
  await for (final msg in port) {
    if (msg == 'quit') break;
    final list = msg as List;
    final id = list[0] as int;
    try {
      final text = list[1] as String;
      // Empty/whitespace input: return a hair of silence so the playback
      // chain keeps moving.
      final sw = Stopwatch()..start();
      final audio = text.trim().isEmpty
          ? null
          : tts.generate(
              text: text,
              sid: PiperEngine.speakerId,
              speed: list[2] as double);
      if (audio != null && audio.sampleRate > 0) {
        final secs = audio.samples.length / audio.sampleRate;
        debugPrint('kokoro: ${text.length} chars -> ${secs.toStringAsFixed(1)}s '
            'audio in ${sw.elapsedMilliseconds}ms '
            '(RTF ${(sw.elapsedMilliseconds / 1000 / secs).toStringAsFixed(2)})');
      }
      if (audio == null || audio.samples.isEmpty) {
        args.main.send([id, Float32List(800), 16000]);
      } else {
        args.main.send([id, audio.samples, audio.sampleRate]);
      }
    } catch (e) {
      args.main.send([id, null, 0, '$e']);
    }
  }
  tts.free();
}
