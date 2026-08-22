import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:readaloud/text_extraction.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('readaloud_test');
  });
  tearDown(() async {
    await tmp.delete(recursive: true);
  });

  Future<ExtractedBook> fromTxt(String content) async {
    final f = File('${tmp.path}${Platform.pathSeparator}book.txt');
    await f.writeAsString(content);
    return extractBook(f.path);
  }

  void checkInvariants(ExtractedBook b) {
    expect(b.paragraphOf.length, b.sentences.length);
    for (var i = 1; i < b.paragraphStart.length; i++) {
      expect(b.paragraphStart[i], greaterThan(b.paragraphStart[i - 1]));
    }
    for (var p = 0; p < b.paragraphStart.length; p++) {
      expect(b.paragraphOf[b.paragraphStart[p]], p);
    }
    for (final s in b.sentences) {
      expect(s.length, lessThanOrEqualTo(maxSentenceChars));
      expect(s.trim(), isNotEmpty);
    }
  }

  test('TXT: paragraphs on blank lines, sentences split, hyphens rejoined',
      () async {
    final b = await fromTxt('This is the under-\n'
        'standing test. It has two sentences.\n'
        '\n'
        'Second paragraph here! Does it work? Yes.\n');
    checkInvariants(b);
    expect(b.paragraphStart.length, 2);
    expect(b.sentences[0], 'This is the understanding test.');
    expect(b.sentences[1], 'It has two sentences.');
    expect(b.sentences.sublist(2),
        ['Second paragraph here!', 'Does it work?', 'Yes.']);
  });

  test('TXT: monster sentence is chunked under the utterance limit', () async {
    final monster = List.generate(1500, (i) => 'word$i').join(' ');
    final b = await fromTxt('$monster and finally it ends.');
    checkInvariants(b); // includes the <= maxSentenceChars check
    expect(b.sentences.length, greaterThan(1));
    // Nothing was lost in the chunking.
    expect(b.sentences.join(' ').split(' ').length,
        '$monster and finally it ends.'.split(' ').length);
  });

  test('PDF: repeated headers and page numbers are dropped', () async {
    final doc = PdfDocument();
    final font = PdfStandardFont(PdfFontFamily.helvetica, 12);
    for (var i = 0; i < 6; i++) {
      final page = doc.pages.add();
      final g = page.graphics;
      g.drawString('MY GREAT BOOK', font,
          bounds: const Rect.fromLTWH(0, 0, 500, 20)); // repeating header
      g.drawString(
          'Body text of page ${i + 1}. It talks about interesting things.',
          font,
          bounds: const Rect.fromLTWH(0, 100, 500, 40));
      g.drawString('${i + 1}', font,
          bounds: const Rect.fromLTWH(250, 700, 50, 20)); // page number
    }
    final f = File('${tmp.path}${Platform.pathSeparator}book.pdf');
    await f.writeAsBytes(doc.saveSync());
    doc.dispose();

    final b = await extractBook(f.path);
    checkInvariants(b);
    final all = b.sentences.join(' ');
    expect(all, contains('Body text of page 3'));
    expect(all, isNot(contains('MY GREAT BOOK')));
    // Bare page numbers gone (body says "page N." with a word before it).
    expect(b.sentences.where((s) => RegExp(r'^\d+$').hasMatch(s)), isEmpty);
  });

  test('TXT: UTF-8 text survives decoding', () async {
    final b = await fromTxt('Ça a marché — très bien. Écrit en français.');
    checkInvariants(b);
    expect(b.sentences.first, 'Ça a marché — très bien.');
    expect(b.sentences.last, 'Écrit en français.');
  });

  test('PDF: words made of roman-numeral letters survive in body text',
      () async {
    final doc = PdfDocument();
    final font = PdfStandardFont(PdfFontFamily.helvetica, 12);
    for (var i = 0; i < 5; i++) {
      final page = doc.pages.add();
      final g = page.graphics;
      g.drawString('The recipe needs a good stir.', font,
          bounds: const Rect.fromLTWH(0, 100, 500, 20));
      g.drawString('mix', font, // roman-lookalike word mid-page: must survive
          bounds: const Rect.fromLTWH(0, 130, 500, 20));
      g.drawString('Then bake it well.', font,
          bounds: const Rect.fromLTWH(0, 160, 500, 20));
      g.drawString('${i + 1}', font,
          bounds: const Rect.fromLTWH(250, 700, 50, 20)); // page number: drop
    }
    final f = File('${tmp.path}${Platform.pathSeparator}roman.pdf');
    await f.writeAsBytes(doc.saveSync());
    doc.dispose();

    final b = await extractBook(f.path);
    checkInvariants(b);
    final all = b.sentences.join(' ');
    expect(all, contains('mix'));
    expect(b.sentences.where((s) => RegExp(r'^\d+$').hasMatch(s)), isEmpty);
  });

  test('EPUB: anchored nav points deduped, div paragraphs, no double text',
      () async {
    const container = '''<?xml version="1.0"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
</container>''';
    const opf = '''<?xml version="1.0" encoding="utf-8"?>
<package xmlns="http://www.idpf.org/2007/opf" unique-identifier="uid" version="2.0">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:title>Test Book</dc:title>
    <dc:identifier id="uid">test-book-1</dc:identifier>
    <dc:language>en</dc:language>
  </metadata>
  <manifest>
    <item id="ch1" href="ch1.xhtml" media-type="application/xhtml+xml"/>
    <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
  </manifest>
  <spine toc="ncx"><itemref idref="ch1"/></spine>
</package>''';
    // Two nav points anchor into the SAME file — a very common EPUB layout.
    const ncx = '''<?xml version="1.0" encoding="utf-8"?>
<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
  <head><meta name="dtb:uid" content="test-book-1"/></head>
  <docTitle><text>Test Book</text></docTitle>
  <navMap>
    <navPoint id="n1" playOrder="1"><navLabel><text>One</text></navLabel><content src="ch1.xhtml"/></navPoint>
    <navPoint id="n2" playOrder="2"><navLabel><text>Two</text></navLabel><content src="ch1.xhtml#part2"/></navPoint>
  </navMap>
</ncx>''';
    const ch1 = '''<?xml version="1.0" encoding="utf-8"?>
<html xmlns="http://www.w3.org/1999/xhtml"><head><title>c</title></head>
<body>
  <h1>Chapter One</h1>
  <div class="para">Unique alpha sentence.</div>
  <div class="para">Unique beta sentence.</div>
  <div id="part2"><p>Nested gamma paragraph.</p></div>
</body></html>''';

    final archive = Archive();
    void add(String name, String content) {
      final data = utf8.encode(content);
      archive.addFile(ArchiveFile(name, data.length, data));
    }

    add('mimetype', 'application/epub+zip');
    add('META-INF/container.xml', container);
    add('OEBPS/content.opf', opf);
    add('OEBPS/toc.ncx', ncx);
    add('OEBPS/ch1.xhtml', ch1);
    final f = File('${tmp.path}${Platform.pathSeparator}book.epub');
    await f.writeAsBytes(ZipEncoder().encode(archive)!);

    final b = await extractBook(f.path);
    checkInvariants(b);
    final all = b.sentences.join(' ');
    // Each unique string appears exactly once — no duplication from the
    // second nav point, no double extraction from the nested wrapper div.
    for (final needle in [
      'Unique alpha sentence.',
      'Unique beta sentence.',
      'Nested gamma paragraph.',
      'Chapter One',
    ]) {
      expect(RegExp(RegExp.escape(needle)).allMatches(all).length, 1,
          reason: '"$needle" should appear exactly once');
    }
    // The nav point's title becomes the chapter; the anchored second nav
    // point into the same file must not create a duplicate chapter.
    expect(b.chapters.map((c) => c.title).toList(), ['One']);
    // EPUB metadata title wins over the file name.
    expect(b.title, 'Test Book');
  });

  test('TXT: chapter headings detected heuristically', () async {
    final b = await fromTxt('''
Chapter 1: The Beginning

It was a dark and stormy night. The rain fell hard.

Chapter 2: The Middle

Things happened here. Many things indeed.

EPILOGUE

And so it ended quietly.
''');
    checkInvariants(b);
    expect(b.chapters.map((c) => c.title).toList(),
        ['Chapter 1: The Beginning', 'Chapter 2: The Middle', 'EPILOGUE']);
    // Each chapter mark points at the heading's own paragraph.
    expect(b.paragraphStart[b.chapters[1].paragraph],
        b.sentences.indexOf('Chapter 2: The Middle'));
  });

  test('TXT: prose in caps-heavy poems does not spam chapters', () async {
    // Every paragraph all-caps -> heuristic should back off entirely.
    final b = await fromTxt(List.generate(12, (i) => 'LINE NUMBER $i HERE')
        .join('\n\n'));
    checkInvariants(b);
    expect(b.chapters, isEmpty);
  });

  test('PDF: bookmarks become chapters mapped to pages', () async {
    final doc = PdfDocument();
    final font = PdfStandardFont(PdfFontFamily.helvetica, 12);
    final pages = <PdfPage>[];
    for (var i = 0; i < 4; i++) {
      final page = doc.pages.add();
      pages.add(page);
      page.graphics.drawString(
          'Content of page ${i + 1}. It has a full sentence.', font,
          bounds: const Rect.fromLTWH(0, 100, 500, 40));
    }
    doc.bookmarks.add('Part One').destination = PdfDestination(pages[0]);
    doc.bookmarks.add('Part Two').destination = PdfDestination(pages[2]);
    final f = File('${tmp.path}${Platform.pathSeparator}marks.pdf');
    await f.writeAsBytes(doc.saveSync());
    doc.dispose();

    final b = await extractBook(f.path);
    checkInvariants(b);
    expect(b.chapters.map((c) => c.title).toList(), ['Part One', 'Part Two']);
    // "Part Two" starts where page 3's content lives.
    final sentenceAtMark =
        b.sentences[b.paragraphStart[b.chapters[1].paragraph]];
    expect(sentenceAtMark, contains('page 3'));
  });

  test('cache round-trip: toJson/fromJson preserves everything', () async {
    final b = await fromTxt('''
Chapter 1

Alpha beta. Gamma delta!

Chapter 2

Epsilon zeta? Eta theta.
''');
    final b2 = ExtractedBook.fromJson(
        jsonDecode(jsonEncode(b.toJson())) as Map<String, dynamic>);
    expect(b2.title, b.title);
    expect(b2.sentences, b.sentences);
    expect(b2.paragraphStart, b.paragraphStart);
    expect(b2.paragraphOf, b.paragraphOf);
    expect(b2.chapters.length, b.chapters.length);
    for (var i = 0; i < b.chapters.length; i++) {
      expect(b2.chapters[i].title, b.chapters[i].title);
      expect(b2.chapters[i].paragraph, b.chapters[i].paragraph);
    }
  });

  test('TXT: UTF-16 (Notepad "Unicode") file decodes to words, not letters',
      () async {
    const text = 'The cat sat on the mat. It was happy.';
    final units = <int>[0xFEFF, ...text.codeUnits]; // BOM + UTF-16LE
    final bytes = <int>[];
    for (final u in units) {
      bytes.add(u & 0xFF);
      bytes.add(u >> 8);
    }
    final f = File('${tmp.path}${Platform.pathSeparator}utf16.txt');
    await f.writeAsBytes(bytes);
    final b = await extractBook(f.path);
    checkInvariants(b);
    expect(b.sentences, ['The cat sat on the mat.', 'It was happy.']);
  });

  test('spaced-out letters ("T h e  c a t") are rebuilt into words', () async {
    final b = await fromTxt('T h e  c a t  s a t  o n  t h e  m a t .\n'
        'Normal line stays exactly as it is.');
    checkInvariants(b);
    expect(b.sentences.first, 'The cat sat on the mat.');
    expect(b.sentences.last, 'Normal line stays exactly as it is.');
  });

  test('empty/garbage file yields zero sentences, not a crash', () async {
    final f = File('${tmp.path}${Platform.pathSeparator}book.txt');
    await f.writeAsString('   \n\n   ');
    final b = await extractBook(f.path);
    expect(b.sentences, isEmpty);
  });
}
