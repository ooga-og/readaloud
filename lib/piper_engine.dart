import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

/// Offline neural TTS using a Piper voice model through sherpa-onnx.
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
  /// Shown in the voice picker. Voice: Piper "northern_english_male"
  /// (medium), trained on OpenSLR-83 — CC BY-SA 4.0, redistribution-safe.
  static const voiceName = 'Nathan (neural, British English)';
  static const voiceLocale = 'en-GB';

  static const _assetZip = 'assets/en_gb_male.zip';
  static const _modelFile = 'en_GB-northern_english_male-medium.onnx';

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

  /// One-slot prefetch cache: the next sentence is synthesized while the
  /// current one plays, which is what makes playback gapless.
  String? _prefetchKey;
  Future<PiperAudio?>? _prefetchFuture;

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
      final list = msg as List;
      final id = list[0] as int;
      final c = _pending.remove(id);
      if (c == null) return;
      if (list[1] == null) {
        debugPrint('Piper synthesis failed: ${list.length > 3 ? list[3] : ''}');
        c.complete(null);
      } else {
        c.complete(
            PiperAudio(list[1] as Float32List, list[2] as int));
      }
    });

    _isolate = await Isolate.spawn(
        _piperWorker, _WorkerArgs(fromWorker.sendPort, _dir));
    _toWorker = await readyCompleter.future.timeout(
      const Duration(seconds: 60),
      onTimeout: () {
        dispose();
        throw TimeoutException('Piper model failed to load');
      },
    );
  }

  /// Unpack the asset zip into the support dir once; a marker file makes
  /// later launches skip straight past this.
  Future<String> _installModel() async {
    final support = await getApplicationSupportDirectory();
    final dir =
        Directory('${support.path}${Platform.pathSeparator}piper_en_gb_male');
    final marker = File('${dir.path}${Platform.pathSeparator}.installed');
    if (await marker.exists()) return dir.path;

    final data = await rootBundle.load(_assetZip);
    final archive = ZipDecoder().decodeBytes(data.buffer
        .asUint8List(data.offsetInBytes, data.lengthInBytes));
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

  /// Synthesize [text]; consumes the prefetch slot when it matches.
  Future<PiperAudio?> synthesize(String text, double speed) {
    final key = '$speed|$text';
    if (_prefetchKey == key && _prefetchFuture != null) {
      final f = _prefetchFuture!;
      _prefetchKey = null;
      _prefetchFuture = null;
      return f;
    }
    return _request(text, speed);
  }

  /// Start synthesizing the NEXT sentence in the background.
  void prefetch(String text, double speed) {
    final key = '$speed|$text';
    if (_prefetchKey == key) return;
    _prefetchKey = key;
    _prefetchFuture = _request(text, speed);
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
      data.setInt16(
          44 + i * 2, (samples[i].clamp(-1.0, 1.0) * 32767).round(),
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
Future<void> _piperWorker(_WorkerArgs args) async {
  sherpa.initBindings();
  final sep = Platform.pathSeparator;
  final tts = sherpa.OfflineTts(sherpa.OfflineTtsConfig(
    model: sherpa.OfflineTtsModelConfig(
      vits: sherpa.OfflineTtsVitsModelConfig(
        model: '${args.dir}$sep${PiperEngine._modelFile}',
        tokens: '${args.dir}${sep}tokens.txt',
        dataDir: '${args.dir}${sep}espeak-ng-data',
      ),
      numThreads: 2,
      debug: false,
    ),
  ));
  final port = ReceivePort();
  args.main.send(port.sendPort);
  await for (final msg in port) {
    if (msg == 'quit') break;
    final list = msg as List;
    final id = list[0] as int;
    try {
      final text = list[1] as String;
      // Piper chokes on empty/whitespace input; return a hair of silence so
      // the playback chain keeps moving.
      final audio = text.trim().isEmpty
          ? null
          : tts.generate(text: text, sid: 0, speed: list[2] as double);
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
