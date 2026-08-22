import 'dart:convert';
import 'dart:io';

import 'package:epubx/epubx.dart';
import 'package:flutter/foundation.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:syncfusion_flutter_pdf/pdf.dart';

/// A chapter (or section) heading and the paragraph where it starts.
class ChapterMark {
  final String title;
  final int paragraph;
  ChapterMark(this.title, this.paragraph);
}

/// The result of extracting a book: cleaned text, split into sentences,
/// grouped into paragraphs, with detected chapters. Sentence indices are
/// global across the book — they are what we store as the reading position.
///
/// Serializable to JSON so extraction runs only ONCE per book; reopening
/// loads the cached copy (see book_cache.dart).
class ExtractedBook {
  /// Book title: EPUB metadata title when available, else the file name.
  final String title;

  /// Every sentence in reading order. Long "sentences" are pre-split so no
  /// entry exceeds [maxSentenceChars] (Android caps a TTS utterance at ~4000
  /// characters; we stay well under).
  final List<String> sentences;

  /// For paragraph i, the global index of its first sentence.
  final List<int> paragraphStart;

  /// For sentence i, which paragraph it belongs to (for auto-scroll and
  /// jump-by-paragraph).
  final List<int> paragraphOf;

  /// Detected chapters/sections in reading order (may be empty).
  final List<ChapterMark> chapters;

  ExtractedBook(this.title, this.sentences, this.paragraphStart,
      this.paragraphOf, this.chapters);

  Map<String, dynamic> toJson() => {
        'v': 2, // bump when extraction output changes so caches re-extract
        'title': title,
        'sentences': sentences,
        'paragraphStart': paragraphStart,
        'chapters': [
          for (final c in chapters) {'t': c.title, 'p': c.paragraph}
        ],
      };

  factory ExtractedBook.fromJson(Map<String, dynamic> m) {
    final sentences = (m['sentences'] as List).cast<String>();
    final paragraphStart = (m['paragraphStart'] as List).cast<int>();
    // paragraphOf is derived rather than stored (halves the cache size).
    final paragraphOf = List<int>.filled(sentences.length, 0);
    for (var p = 0; p < paragraphStart.length; p++) {
      final end = p + 1 < paragraphStart.length
          ? paragraphStart[p + 1]
          : sentences.length;
      for (var i = paragraphStart[p]; i < end; i++) {
        paragraphOf[i] = p;
      }
    }
    return ExtractedBook(
      m['title'] as String,
      sentences,
      paragraphStart,
      paragraphOf,
      [
        for (final c in (m['chapters'] as List? ?? []))
          ChapterMark(c['t'] as String, c['p'] as int)
      ],
    );
  }
}

/// Keep utterances comfortably under Android's ~4000-char TTS limit.
const int maxSentenceChars = 3500;

/// Extract a book from [path] on a background isolate so the UI stays
/// responsive while parsing a large PDF/EPUB.
Future<ExtractedBook> extractBook(String path) async {
  final bytes = await File(path).readAsBytes();
  final dot = path.lastIndexOf('.');
  final ext = dot < 0 ? '' : path.substring(dot + 1).toLowerCase();
  final sep = path.lastIndexOf(Platform.pathSeparator);
  final name = sep < 0 ? path : path.substring(sep + 1);
  return compute(_extractSync, _Job(bytes, ext, name));
}

class _Job {
  final Uint8List bytes;
  final String ext;
  final String name;
  _Job(this.bytes, this.ext, this.name);
}

/// Paragraphs + chapter marks as produced by a format-specific extractor,
/// before sentence splitting. Chapter marks reference RAW paragraph indices.
class _RawBook {
  final String? title; // metadata title if the format provides one
  final List<String> paragraphs;
  final List<ChapterMark> chapters;
  _RawBook(this.title, this.paragraphs, this.chapters);
}

/// Runs on the background isolate. Returns a book with zero sentences when
/// no readable text was found (e.g. a scanned, image-only PDF).
Future<ExtractedBook> _extractSync(_Job job) async {
  _RawBook raw;
  switch (job.ext) {
    case 'pdf':
      raw = _fromPdf(job.bytes);
      break;
    case 'epub':
      raw = await _fromEpub(job.bytes);
      break;
    default: // treat anything else as plain text
      raw = _fromTxt(_decodeText(job.bytes));
  }

  // Split each paragraph into sentences and build the index tables. Some raw
  // paragraphs produce no sentences and are dropped, so raw paragraph
  // indices shift — rawToFinal maps them for the chapter marks.
  final sentences = <String>[];
  final paragraphStart = <int>[];
  final paragraphOf = <int>[];
  final rawToFinal = List<int>.filled(raw.paragraphs.length + 1, -1);
  final directHit = List<bool>.filled(raw.paragraphs.length + 1, false);
  for (var r = 0; r < raw.paragraphs.length; r++) {
    final ss = _splitSentences(raw.paragraphs[r]);
    if (ss.isEmpty) continue;
    rawToFinal[r] = paragraphStart.length;
    directHit[r] = true;
    paragraphStart.add(sentences.length);
    for (final s in ss) {
      paragraphOf.add(paragraphStart.length - 1);
      sentences.add(s);
    }
  }
  // A raw index with no final paragraph maps forward to the next one.
  var next = paragraphStart.length; // == "past the end" for trailing gaps
  for (var r = rawToFinal.length - 1; r >= 0; r--) {
    if (rawToFinal[r] == -1) {
      rawToFinal[r] = next;
    } else {
      next = rawToFinal[r];
    }
  }

  // Remap chapters onto final paragraphs; drop out-of-range and collapse
  // marks that landed on the same paragraph. When a mark that HIT its own
  // paragraph collides with an earlier mark that was merely backfilled
  // forward (e.g. an empty "Cover" section), the direct hit is the real
  // chapter — it replaces the backfilled one.
  final chapters = <ChapterMark>[];
  var lastWasDirectHit = false;
  for (final c in raw.chapters) {
    if (c.paragraph < 0 || c.paragraph >= rawToFinal.length) continue;
    final p = rawToFinal[c.paragraph];
    if (p >= paragraphStart.length) continue;
    final isDirectHit = c.paragraph < directHit.length && directHit[c.paragraph];
    if (chapters.isNotEmpty && chapters.last.paragraph >= p) {
      if (isDirectHit && !lastWasDirectHit && chapters.last.paragraph == p) {
        chapters[chapters.length - 1] = ChapterMark(c.title, p);
        lastWasDirectHit = true;
      }
      continue;
    }
    chapters.add(ChapterMark(c.title, p));
    lastWasDirectHit = isDirectHit;
  }

  return ExtractedBook(raw.title ?? job.name, sentences, paragraphStart,
      paragraphOf, chapters);
}

// ------------------------------------------------------------------- plain text

/// Decode a text file's bytes. UTF-8 is the norm, but Windows Notepad's
/// "Unicode" option writes UTF-16, which decoded as UTF-8 becomes letters
/// interleaved with NUL bytes — and a TTS engine then spells the book out
/// letter by letter. Detect it (BOM, or a flood of zero bytes) and decode
/// properly.
String _decodeText(Uint8List bytes) {
  if (bytes.length >= 2) {
    final bomLE = bytes[0] == 0xFF && bytes[1] == 0xFE;
    final bomBE = bytes[0] == 0xFE && bytes[1] == 0xFF;
    var zeros = 0;
    final sample = bytes.length < 4000 ? bytes.length : 4000;
    for (var i = 0; i < sample; i++) {
      if (bytes[i] == 0) zeros++;
    }
    final looksUtf16 = bomLE || bomBE || zeros > sample ~/ 4;
    if (looksUtf16) {
      final bigEndian = bomBE || (!bomLE && bytes[0] == 0 && bytes[1] != 0);
      final start = (bomLE || bomBE) ? 2 : 0;
      final units = <int>[];
      for (var i = start; i + 1 < bytes.length; i += 2) {
        units.add(bigEndian
            ? (bytes[i] << 8) | bytes[i + 1]
            : bytes[i] | (bytes[i + 1] << 8));
      }
      return String.fromCharCodes(units);
    }
  }
  var text = utf8.decode(bytes, allowMalformed: true);
  if (text.isNotEmpty && text.codeUnitAt(0) == 0xFEFF) text = text.substring(1);
  return text;
}

/// Some PDFs (and badly exported text) come out with a space between every
/// letter — "T h e  c a t  s a t" — which makes a voice spell each letter.
/// When a line is mostly single-character tokens, rebuild it: runs of
/// spaced letters become words, and double spaces become word breaks.
String _collapseSpacedLetters(String line) {
  final tokens = line.trim().split(RegExp(r' +'));
  if (tokens.length < 6) return line;
  final singles = tokens.where((t) => t.length == 1).length;
  if (singles < tokens.length * 0.7) return line;
  return line
      .trim()
      .split(RegExp(r' {2,}|\t+'))
      .map((w) => w.replaceAll(' ', ''))
      .where((w) => w.isNotEmpty)
      .join(' ');
}

/// TXT: paragraphs are separated by blank lines; single line breaks inside a
/// paragraph are hard-wrapping and get joined with a space.
_RawBook _fromTxt(String text) {
  text = text
      .replaceAll('\r\n', '\n')
      .split('\n')
      .map(_collapseSpacedLetters)
      .join('\n');
  text = _dehyphenate(text);
  var blocks = text.split(RegExp(r'\n\s*\n'));
  // Some plain-text books have no blank lines at all; fall back to
  // one-line-per-paragraph so we don't produce a single giant paragraph.
  if (blocks.length < 3 && text.split('\n').length > 50) {
    blocks = text.split('\n');
  }
  final paragraphs = blocks
      .map((b) => b.replaceAll(RegExp(r'\s+'), ' ').trim())
      .where((b) => b.isNotEmpty)
      .toList();
  return _RawBook(null, paragraphs, _heuristicChapters(paragraphs));
}

// -------------------------------------------------------------------------- PDF

/// PDF: extract page by page so we can detect repeating headers/footers,
/// drop page numbers, rejoin hyphenated words, and rebuild paragraphs from
/// hard-wrapped lines. Chapters come from the PDF's bookmarks (outline) when
/// present, else from heading heuristics.
_RawBook _fromPdf(Uint8List bytes) {
  final doc = PdfDocument(inputBytes: bytes);
  final extractor = PdfTextExtractor(doc);
  final pages = <List<String>>[]; // page -> lines
  for (var i = 0; i < doc.pages.count; i++) {
    // extractTextLines gives one entry per *visual* line — plain extractText
    // can run whole blocks together without newlines, which would defeat the
    // header/footer detection and paragraph rebuilding below.
    final lines = extractor.extractTextLines(startPageIndex: i, endPageIndex: i);
    pages.add(
        lines.map((l) => _collapseSpacedLetters(l.text.trim())).toList());
  }

  // Headers/footers repeat on most pages (often with a changing page number).
  // Count how often each page's first and last non-empty line occurs — with
  // digits stripped, so "MOBY DICK 41" and "MOBY DICK 42" count as the same
  // line — and drop the ones that show up on 30%+ of pages.
  String normalize(String l) =>
      l.replaceAll(RegExp(r'\d+'), '').replaceAll(RegExp(r'\s+'), ' ').trim();
  final edgeCounts = <String, int>{};
  for (final lines in pages) {
    final nonEmpty = lines.where((l) => l.isNotEmpty).toList();
    if (nonEmpty.isEmpty) continue;
    for (final edge in {normalize(nonEmpty.first), normalize(nonEmpty.last)}) {
      if (edge.isNotEmpty) edgeCounts[edge] = (edgeCounts[edge] ?? 0) + 1;
    }
  }
  final threshold = (pages.length * 0.3).clamp(4, 1e9);
  final repeating = edgeCounts.entries
      .where((e) => e.value >= threshold)
      .map((e) => e.key)
      .toSet();

  // Safety net: if the "repeating header/footer" filter would swallow a
  // large share of the book (pathological case: pages with one similar
  // line each), it has clearly misfired — disable it.
  if (repeating.isNotEmpty) {
    var total = 0, dropped = 0;
    for (final lines in pages) {
      for (final line in lines) {
        if (line.isEmpty) continue;
        total++;
        if (repeating.contains(normalize(line))) dropped++;
      }
    }
    if (total > 0 && dropped / total > 0.4) repeating.clear();
  }

  // Filter each page's lines. Only the first/last non-empty line of a page
  // can be a page number — checking every line would eat real words ("mix",
  // "Lid", …) and chapter numerals from the body text.
  final keptPages = <List<String>>[];
  for (final lines in pages) {
    final firstIdx = lines.indexWhere((l) => l.isNotEmpty);
    final lastIdx = lines.lastIndexWhere((l) => l.isNotEmpty);
    final kept = <String>[];
    for (var j = 0; j < lines.length; j++) {
      final line = lines[j];
      if (line.isEmpty) {
        kept.add('');
        continue;
      }
      if ((j == firstIdx || j == lastIdx) && _isPageNumberLine(line)) continue;
      if (repeating.contains(normalize(line))) continue;
      kept.add(line);
    }
    keptPages.add(kept);
  }

  // Fold lines into paragraphs page by page, remembering which paragraph
  // each page starts at so bookmarks (which point at pages) can be mapped.
  final allLines = keptPages.expand((p) => p).toList();
  final folder = _ParagraphFolder(allLines);
  final pageFirstParagraph = <int>[];
  for (final kept in keptPages) {
    pageFirstParagraph.add(folder.paragraphs.length);
    for (final line in kept) {
      folder.feed(line);
    }
    folder.flush(); // page boundary always ends the paragraph in progress
  }
  final paragraphs = folder.paragraphs;

  // Chapters: prefer the PDF outline (bookmarks); heuristics otherwise.
  // Candidates carry whether their own page contributed text, so a real
  // chapter beats an image-only "Cover" bookmark that lands on the same
  // paragraph.
  final candidates = <(String, int, bool, int)>[]; // title, para, hasText, ord
  try {
    void walkBookmarks(PdfBookmarkBase base) {
      for (var i = 0; i < base.count; i++) {
        final bm = base[i];
        // Bookmarks may target a destination directly or via a named
        // destination — both are common in the wild.
        final page =
            bm.destination?.page ?? bm.namedDestination?.destination?.page;
        if (bm.title.trim().isNotEmpty && page != null) {
          final pageIdx = doc.pages.indexOf(page);
          if (pageIdx >= 0 && pageIdx < pageFirstParagraph.length) {
            final start = pageFirstParagraph[pageIdx];
            final end = pageIdx + 1 < pageFirstParagraph.length
                ? pageFirstParagraph[pageIdx + 1]
                : paragraphs.length;
            candidates
                .add((bm.title.trim(), start, end > start, candidates.length));
          }
        }
        walkBookmarks(bm); // nested bookmarks
      }
    }

    walkBookmarks(doc.bookmarks);
  } catch (e) {
    debugPrint('PDF bookmarks unreadable: $e');
  }
  candidates.sort((a, b) {
    final c = a.$2.compareTo(b.$2);
    return c != 0 ? c : a.$4.compareTo(b.$4); // stable within a paragraph
  });
  var chapters = <ChapterMark>[];
  var lastHadText = false;
  for (final (title, para, hasText, _) in candidates) {
    if (chapters.isNotEmpty && chapters.last.paragraph == para) {
      // Same paragraph: prefer the first candidate whose own page has text.
      if (hasText && !lastHadText) {
        chapters[chapters.length - 1] = ChapterMark(title, para);
        lastHadText = true;
      }
      continue;
    }
    chapters.add(ChapterMark(title, para));
    lastHadText = hasText;
  }
  if (chapters.isEmpty) chapters = _heuristicChapters(paragraphs);

  doc.dispose();
  return _RawBook(null, paragraphs, chapters);
}

/// Rebuilds paragraphs from hard-wrapped lines. A paragraph ends at a blank
/// line, at an explicit [flush] (page boundary), or at a line that is
/// clearly short (ragged right edge) AND ends with terminal punctuation —
/// the classic heuristic for justified book text.
class _ParagraphFolder {
  final paragraphs = <String>[];
  final _current = StringBuffer();
  int _bufferedLines = 0;
  late final int _median;

  _ParagraphFolder(List<String> allLines) {
    final lengths =
        allLines.where((l) => l.length > 10).map((l) => l.length).toList()
          ..sort();
    _median = lengths.isEmpty ? 60 : lengths[lengths.length ~/ 2];
  }

  static final _headingWord = RegExp(
      r'^(chapter|part|book|section|canto|act|volume|stave|prologue|epilogue|introduction|preface|foreword|afterword|appendix|interlude|conclusion)\b',
      caseSensitive: false);

  void feed(String line) {
    if (line.isEmpty) {
      flush();
      return;
    }
    // A lone short heading-like line ("CHAPTER IV", "Introduction") becomes
    // its own paragraph instead of being glued onto the following body text —
    // otherwise heuristic chapter detection can never see PDF headings.
    if (_bufferedLines == 1) {
      final first = _current.toString().trim();
      final letters = first.replaceAll(RegExp(r'[^A-Za-zÀ-ÿ]'), '');
      final headingLike = first.length < _median * 0.6 &&
          !RegExp(r'''[.!?…,;:]["'”’)\]]*$''').hasMatch(first) &&
          ((letters.length >= 2 && letters == letters.toUpperCase()) ||
              _headingWord.hasMatch(first));
      if (headingLike) flush();
    }
    _current
      ..write(line)
      ..write('\n'); // keep the newline so _dehyphenate can see line breaks
    _bufferedLines++;
    final endsSentence = RegExp(r'''[.!?…]["'”’)\]]*$''').hasMatch(line);
    if (endsSentence && line.length < _median * 0.7) flush();
  }

  void flush() {
    final p = _dehyphenate(_current.toString())
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (p.isNotEmpty) paragraphs.add(p);
    _current.clear();
    _bufferedLines = 0;
  }
}

/// True for lines that are just a page number: "17", "Page 3", or a valid
/// roman numeral ("xiv"). The roman branch uses the strict grammar so real
/// words made of numeral letters ("did", "climb") never match.
bool _isPageNumberLine(String line) {
  final m = RegExp(r'^\s*(?:page\s+)?([0-9]{1,5}|[ivxlcdm]{1,7})\s*$',
          caseSensitive: false)
      .firstMatch(line);
  if (m == null) return false;
  final token = m.group(1)!.toLowerCase();
  if (RegExp(r'^[0-9]+$').hasMatch(token)) return true;
  return RegExp(r'^m{0,4}(cm|cd|d?c{0,3})(xc|xl|l?x{0,3})(ix|iv|v?i{0,3})$')
      .hasMatch(token);
}

// ------------------------------------------------------------------------- EPUB

/// EPUB: parse with epubx, pull text out of HTML block elements so paragraph
/// structure survives, and take chapter titles from the navigation tree.
Future<_RawBook> _fromEpub(Uint8List bytes) async {
  final book = await EpubReader.readBook(bytes);

  // Reading order comes from the SPINE (the canonical order of content
  // files) — books often have spine files that the navigation never
  // mentions (splits, front/back matter), and walking only the nav tree
  // silently loses their text. The nav tree contributes TITLES only.
  // Multiple nav points can anchor into the same file (subchapters), so the
  // title map keeps the first title per file.
  final titleOf = <String, String>{}; // content file -> nav title
  void walk(EpubChapter c) {
    final file = c.ContentFileName;
    final t = c.Title?.trim();
    if (file != null && t != null && t.isNotEmpty) {
      titleOf.putIfAbsent(file, () => t);
    }
    for (final sub in c.SubChapters ?? <EpubChapter>[]) {
      walk(sub);
    }
  }

  for (final c in book.Chapters ?? <EpubChapter>[]) {
    walk(c);
  }

  final chunks = <(String?, String)>[]; // (nav title, html)
  final html = book.Content?.Html ?? {};
  final hrefById = {
    for (final m
        in book.Schema?.Package?.Manifest?.Items ?? <EpubManifestItem>[])
      if (m.Id != null && m.Href != null) m.Id!: m.Href!
  };
  final seenFiles = <String>{};
  for (final s in book.Schema?.Package?.Spine?.Items ?? <EpubSpineItemRef>[]) {
    final href = hrefById[s.IdRef];
    final content = href == null ? null : html[href]?.Content;
    if (href != null && content != null && seenFiles.add(href)) {
      chunks.add((titleOf[href], content));
    }
  }
  if (chunks.isEmpty) {
    // No usable spine: fall back to every HTML content file in book order.
    for (final e in html.entries) {
      if (e.value.Content != null && seenFiles.add(e.key)) {
        chunks.add((titleOf[e.key], e.value.Content!));
      }
    }
  }

  final paragraphs = <String>[];
  final chapters = <ChapterMark>[];
  // "div" is included because some EPUBs use <div class="para"> instead of
  // <p>; keeping only LEAF blocks (no block descendants) means a wrapper div
  // around real paragraphs doesn't duplicate their text.
  const blockSelector = 'p, h1, h2, h3, h4, h5, h6, li, blockquote, div';
  int textLen(String s) => s.replaceAll(RegExp(r'\s+'), ' ').trim().length;
  for (final (navTitle, chunk) in chunks) {
    final chunkStart = paragraphs.length;
    final doc = html_parser.parse(chunk);
    final blocks = doc
        .querySelectorAll(blockSelector)
        .where((e) => e.querySelector(blockSelector) == null)
        .toList();
    final bodyText = doc.body?.text ?? '';
    var texts = blocks.isNotEmpty
        ? blocks.map((e) => e.text).toList()
        : <String>[bodyText]; // rare: bare text straight in <body>
    // Safety net for non-standard markup: if the blocks we matched cover
    // less than half of the body text, fall back to the whole body rather
    // than silently dropping most of a chapter.
    final covered = texts.fold<int>(0, (n, t) => n + textLen(t));
    if (textLen(bodyText) > 0 && covered < textLen(bodyText) * 0.5) {
      texts = [bodyText];
    }
    for (final t in texts) {
      final cleaned = t.replaceAll(RegExp(r'\s+'), ' ').trim();
      if (cleaned.isNotEmpty) paragraphs.add(cleaned);
    }
    if (paragraphs.length > chunkStart && navTitle != null &&
        navTitle.trim().isNotEmpty) {
      chapters.add(ChapterMark(navTitle.trim(), chunkStart));
    }
  }

  final title = (book.Title ?? '').trim();
  return _RawBook(
      title.isEmpty ? null : title,
      paragraphs,
      chapters.isNotEmpty ? chapters : _heuristicChapters(paragraphs));
}

// --------------------------------------------------------------------- chapters

/// Fallback chapter detection for books with no structural metadata: looks
/// for short heading-like paragraphs ("Chapter 7", "PART TWO: THE ROAD",
/// "Prologue", short ALL-CAPS lines).
List<ChapterMark> _heuristicChapters(List<String> paragraphs) {
  final numbered = RegExp(
      r'^(chapter|part|book|section|canto|act|volume|stave)\s+([0-9]{1,4}|[ivxlcdm]{1,7}|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|thirteen|fourteen|fifteen|sixteen|seventeen|eighteen|nineteen|twenty|thirty|forty|fifty)\b',
      caseSensitive: false);
  final standalone = RegExp(
      r'^(prologue|epilogue|introduction|preface|foreword|afterword|appendix|interlude|conclusion)\.?$',
      caseSensitive: false);
  final marks = <ChapterMark>[];
  for (var i = 0; i < paragraphs.length; i++) {
    final p = paragraphs[i].trim();
    if (p.length > 90) continue;
    final letters = p.replaceAll(RegExp(r'[^A-Za-zÀ-ÿ]'), '');
    final endsLikeProse = RegExp(r'[.!?…]["’”)\]]*$').hasMatch(p) &&
        !RegExp(r'^\S+\.$').hasMatch(p); // allow "Prologue." style
    final isAllCaps = letters.length >= 3 &&
        letters == letters.toUpperCase() &&
        p.length <= 60 &&
        !endsLikeProse;
    if (numbered.hasMatch(p) || standalone.hasMatch(p) || isAllCaps) {
      marks.add(ChapterMark(p, i));
    }
  }
  // Too many marks means the heuristic misfired (shouty poetry, tables, …).
  // The ratio rule only applies once there are enough marks to judge — a
  // 6-paragraph pamphlet with 3 headings is fine.
  if (marks.length > 400 ||
      (marks.length > 8 && marks.length > paragraphs.length ~/ 3)) {
    return [];
  }
  return marks;
}

// --------------------------------------------------------------------- helpers

/// Rejoin words that were hyphen-broken across a line break:
/// "under-\nstand" -> "understand". Only lowercase after the break, so real
/// hyphenated compounds at line starts ("well-\nKnown Books") are left alone.
String _dehyphenate(String text) =>
    text.replaceAllMapped(RegExp(r'([A-Za-zÀ-ÿ])-\s*\n\s*([a-zà-ÿ])'),
        (m) => '${m[1]}${m[2]}');

/// Split a paragraph into sentences. Deliberately simple: a sentence runs up
/// to `. ! ? …` plus any closing quotes/brackets. Abbreviations like "Mr."
/// will over-split occasionally — harmless for read-aloud purposes.
/// Also enforces [maxSentenceChars] by hard-splitting monster sentences at
/// word boundaries so no TTS utterance can exceed Android's limit.
List<String> _splitSentences(String paragraph) {
  final matches =
      RegExp(r'''[^.!?…]+[.!?…]+["'”’)\]]*|[^.!?…]+$''').allMatches(paragraph);
  final out = <String>[];
  for (final m in matches) {
    final s = m.group(0)!.trim();
    if (s.isEmpty) continue;
    if (s.length <= maxSentenceChars) {
      out.add(s);
    } else {
      // Extremely long run without punctuation (tables, weird extraction):
      // chop at the last space before the limit.
      var rest = s;
      while (rest.length > maxSentenceChars) {
        var cut = rest.lastIndexOf(' ', maxSentenceChars);
        if (cut < maxSentenceChars ~/ 2) cut = maxSentenceChars;
        out.add(rest.substring(0, cut).trim());
        rest = rest.substring(cut).trim();
      }
      if (rest.isNotEmpty) out.add(rest);
    }
  }
  return out;
}
