import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart'
    show LicenseEntryWithLineBreaks, LicenseRegistry;
import 'package:flutter/material.dart';

import 'book_cache.dart';
import 'reader_screen.dart';
import 'store.dart';
import 'text_extraction.dart';
import 'tts_controller.dart';

/// Licenses for components that aren't Dart packages (those register
/// themselves automatically). Shown under About -> View licenses.
void _registerLicenses() {
  LicenseRegistry.addLicense(() async* {
    yield const LicenseEntryWithLineBreaks(['ReadAloud'], '''
ReadAloud is free software: you can redistribute it and/or modify it under
the terms of the GNU General Public License as published by the Free
Software Foundation, version 3.

This program is distributed in the hope that it will be useful, but WITHOUT
ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for
more details: https://www.gnu.org/licenses/gpl-3.0.html

Source code: https://github.com/ooga-og/readaloud''');
    yield const LicenseEntryWithLineBreaks(['Kokoro voice model'], '''
The bundled neural voice is Kokoro (v0.19, int8) by hexgrad
(https://huggingface.co/hexgrad/Kokoro-82M), speaking as the "bm_george"
British English voice. Packaged for sherpa-onnx by the k2-fsa project.

Licensed under the Apache License, Version 2.0:
https://www.apache.org/licenses/LICENSE-2.0''');
    yield const LicenseEntryWithLineBreaks(['espeak-ng'], '''
Speech synthesis phonemization uses espeak-ng data and code, bundled inside
the sherpa-onnx runtime.

espeak-ng is licensed under the GNU General Public License version 3:
https://github.com/espeak-ng/espeak-ng
This app as a whole is distributed under GPLv3-compatible terms (see the
ReadAloud license entry).''');
    yield const LicenseEntryWithLineBreaks(['ONNX Runtime'], '''
Neural voice inference runs on ONNX Runtime (https://onnxruntime.ai),
Copyright (c) Microsoft Corporation, licensed under the MIT License.''');
  });
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  _registerLicenses();
  await Store.init();
  runApp(const ReadAloudApp());
}

class ReadAloudApp extends StatelessWidget {
  const ReadAloudApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'TTS',
      theme: ThemeData(
        colorSchemeSeed: Colors.teal,
        brightness: Brightness.light,
      ),
      darkTheme: ThemeData(
        colorSchemeSeed: Colors.teal,
        brightness: Brightness.dark,
      ),
      home: const HomeScreen(),
    );
  }
}

/// Home screen: the library. Every opened book is saved here with its
/// reading progress and chapter count; extraction results are cached on
/// disk so a book is parsed only the first time it's opened.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  /// One TTS controller for the whole app; the reader screen borrows it.
  final TtsController _tts = TtsController();
  bool _busy = false;
  String _busyLabel = '';

  @override
  void initState() {
    super.initState();
    _tts.init();
  }

  @override
  void dispose() {
    _tts.dispose();
    super.dispose();
  }

  Future<void> _pickAndOpen() async {
    if (_busy) return;
    final file = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: ['pdf', 'epub', 'txt'],
    );
    final path = file?.path;
    if (path != null) await _open(path);
  }

  Future<void> _openEntry(LibraryEntry e) async {
    if (_busy) return;
    final f = File(e.path);
    if (await f.exists()) {
      await _open(e.path, knownKey: e.key);
    } else {
      // On Android the picker's cached copy can vanish; the book's position
      // and parsed cache survive (they're keyed by name+size), so re-picking
      // the same file restores everything.
      _snack('The file has moved — pick it again with "Add a book" '
          '(your position is kept).');
    }
  }

  Future<void> _open(String path, {String? knownKey}) async {
    if (_busy) return; // double-tap / picker re-entry guard
    setState(() {
      _busy = true;
      _busyLabel = 'Opening…';
    });
    try {
      final file = File(path);
      final size = await file.length();
      final sep = path.lastIndexOf(Platform.pathSeparator);
      final fileName = sep < 0 ? path : path.substring(sep + 1);
      // Stable identity: name+size survives Android's changing cache paths.
      final key = '$fileName|$size';
      if (knownKey != null && knownKey != key) {
        // The file at this path was replaced by one with a different size —
        // its cached text and position describe the OLD content. Clean up.
        await BookCache.remove(knownKey);
        await Store.removeLibrary(knownKey);
        await Store.removePosition(knownKey);
      }

      // Cached from a previous open? Then this is instant — no re-parsing.
      var book = await BookCache.load(key);
      if (book == null) {
        setState(() => _busyLabel = 'Extracting text (first open)…');
        book = await extractBook(path); // runs on a background isolate
        if (book.sentences.isEmpty) {
          _snack('No readable text found in this file. '
              'If it is a scanned PDF, it only contains images.');
          return;
        }
        await BookCache.save(key, book);
      }

      _tts.loadBook(book, key);
      final evicted = await Store.upsertLibrary(LibraryEntry(
        key: key,
        path: path,
        name: book.title,
        totalSentences: book.sentences.length,
        chapterCount: book.chapters.length,
        lastOpenedMs: DateTime.now().millisecondsSinceEpoch,
      ));
      // Books that fell off the end of the library also lose their disk
      // cache and saved position — otherwise they leak forever.
      for (final ev in evicted) {
        await Store.removePosition(ev.key);
        await BookCache.remove(ev.key);
      }
      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => ReaderScreen(tts: _tts)),
      );
      setState(() {}); // refresh progress bars after returning
    } catch (e) {
      _snack('Could not open this file: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _removeEntry(LibraryEntry e) async {
    // Removing from the library also clears the parsed cache and position.
    await Store.removeLibrary(e.key);
    await Store.removePosition(e.key);
    await BookCache.remove(e.key);
    setState(() {});
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    final library = Store.library;
    return Scaffold(
      appBar: AppBar(
        title: const Text('TTS'),
        actions: [
          IconButton(
            icon: const Icon(Icons.info_outline),
            tooltip: 'About & licenses',
            onPressed: () => showAboutDialog(
              context: context,
              applicationName: 'TTS',
              applicationVersion: '1.0.0',
              applicationLegalese: '© 2026 · GNU GPL v3\n\n'
                  'Voice: Kokoro neural TTS by hexgrad (Apache 2.0), '
                  'British English "George".',
            ),
          ),
        ],
      ),
      floatingActionButton: _busy
          ? null
          : FloatingActionButton.extended(
              onPressed: _pickAndOpen,
              icon: const Icon(Icons.add),
              label: const Text('Add a book'),
            ),
      body: _busy
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const CircularProgressIndicator(),
                  const SizedBox(height: 16),
                  Text(_busyLabel),
                ],
              ),
            )
          : library.isEmpty
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.menu_book,
                          size: 64,
                          color: Theme.of(context).colorScheme.outline),
                      const SizedBox(height: 12),
                      const Text('Your library is empty.'),
                      const Text('Add a PDF, EPUB or TXT to get started.'),
                    ],
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(12, 12, 12, 90),
                  itemCount: library.length,
                  itemBuilder: (context, i) =>
                      _bookCard(context, library[i]),
                ),
    );
  }

  Widget _bookCard(BuildContext context, LibraryEntry e) {
    final pos = Store.positionFor(e.key);
    final progress =
        e.totalSentences > 0 ? (pos + 1) / e.totalSentences : 0.0;
    final pct = (progress * 100).clamp(0, 100).toStringAsFixed(0);
    return Card(
      child: ListTile(
        contentPadding: const EdgeInsets.fromLTRB(16, 6, 8, 6),
        leading: const Icon(Icons.menu_book, size: 32),
        title: Text(e.name, maxLines: 2, overflow: TextOverflow.ellipsis),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 6),
            LinearProgressIndicator(value: progress.clamp(0.0, 1.0)),
            const SizedBox(height: 4),
            Text(
              '$pct%'
              '${e.chapterCount > 0 ? ' · ${e.chapterCount} chapters' : ''}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
        trailing: IconButton(
          icon: const Icon(Icons.delete_outline),
          tooltip: 'Remove from library',
          onPressed: () => _removeEntry(e),
        ),
        onTap: () => _openEntry(e),
      ),
    );
  }
}
