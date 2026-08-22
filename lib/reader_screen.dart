import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';

import 'text_extraction.dart';
import 'tts_controller.dart';

/// Shows the book text (one list item per paragraph), highlights what is
/// being spoken, auto-scrolls to keep it visible, and hosts the playback
/// controls plus a chapter drawer.
class ReaderScreen extends StatefulWidget {
  final TtsController tts;
  const ReaderScreen({super.key, required this.tts});

  @override
  State<ReaderScreen> createState() => _ReaderScreenState();
}

class _ReaderScreenState extends State<ReaderScreen> {
  final _scaffoldKey = GlobalKey<ScaffoldState>();
  final _scrollController = ItemScrollController();
  final _positionsListener = ItemPositionsListener.create();
  int _lastScrolledParagraph = -1;
  int _lastScrolledHighlight = -1;

  /// Tap recognizers, one per sentence index, created lazily and reused
  /// across rebuilds (disposing them per-build would kill taps that are
  /// mid-gesture). They capture only the stable sentence index, so reuse is
  /// safe; all are disposed together when the screen goes away.
  final _recognizers = <int, TapGestureRecognizer>{};

  TtsController get tts => widget.tts;
  ExtractedBook get book => tts.book!;

  @override
  void initState() {
    super.initState();
    tts.addListener(_onTtsChanged);
    // After the first frame, jump straight to the resumed position.
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToCurrent());
  }

  @override
  void dispose() {
    tts.removeListener(_onTtsChanged);
    tts.stop();
    for (final r in _recognizers.values) {
      r.dispose();
    }
    super.dispose();
  }

  /// Paragraph of the current sentence, clamped defensively so a stray
  /// out-of-range index can never crash the listener.
  int get _currentParagraph =>
      book.paragraphOf[tts.current.clamp(0, book.paragraphOf.length - 1)];

  void _onTtsChanged() {
    if (!mounted) return;
    setState(() {});
    if (!tts.playing) return;
    // Auto-scroll when the highlight moves — but only actually scroll when
    // it enters a new paragraph or drifts out of the comfortable window, so
    // we don't fight the user's own scrolling constantly.
    if (_currentParagraph != _lastScrolledParagraph ||
        tts.highlightStart != _lastScrolledHighlight) {
      _autoScroll();
    }
  }

  /// How far into the current paragraph (by characters) the highlight
  /// starts, 0..1 — used to keep the spoken spot visible inside paragraphs
  /// taller than the screen.
  double _highlightFraction(int para) {
    final start = book.paragraphStart[para];
    final end = para + 1 < book.paragraphStart.length
        ? book.paragraphStart[para + 1]
        : book.sentences.length;
    var before = 0, total = 0;
    for (var i = start; i < end; i++) {
      final len = book.sentences[i].length + 1;
      if (i < tts.highlightStart) before += len;
      total += len;
    }
    return total == 0 ? 0 : before / total;
  }

  void _autoScroll() {
    final para = _currentParagraph;
    final newPara = para != _lastScrolledParagraph;
    _lastScrolledParagraph = para;
    _lastScrolledHighlight = tts.highlightStart;
    if (!_scrollController.isAttached) return;

    ItemPosition? pos;
    for (final p in _positionsListener.itemPositions.value) {
      if (p.index == para) {
        pos = p;
        break;
      }
    }
    if (pos == null) {
      // Paragraph not rendered (user scrolled far away): plain jump.
      if (newPara) _scrollToCurrent();
      return;
    }
    final height = pos.itemTrailingEdge - pos.itemLeadingEdge;
    final frac = _highlightFraction(para);
    final edge = pos.itemLeadingEdge + height * frac;
    // Scroll when entering a new paragraph or when the spoken spot has
    // drifted outside the top 70% of the viewport. A (possibly negative)
    // alignment pins the highlight itself at ~25%, not the paragraph top —
    // that's what keeps very tall paragraphs readable.
    if (newPara || edge < 0.0 || edge > 0.7) {
      _scrollController.scrollTo(
        index: para,
        alignment: 0.25 - height * frac,
        duration: const Duration(milliseconds: 300),
      );
    }
  }

  void _scrollToCurrent() {
    final para = _currentParagraph;
    _lastScrolledParagraph = para;
    if (_scrollController.isAttached) {
      _scrollController.scrollTo(
        index: para,
        alignment: 0.25, // keep the current paragraph in the upper third
        duration: const Duration(milliseconds: 300),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final chapter = tts.currentChapter;
    return Scaffold(
      key: _scaffoldKey,
      appBar: AppBar(
        // A drawer normally hijacks the leading slot for its hamburger icon;
        // we want an explicit back-to-library button there instead, so the
        // chapter list gets its own button in the actions.
        leading: BackButton(
          onPressed: () => Navigator.of(context).maybePop(),
        ),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(book.title,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.titleMedium),
            if (chapter >= 0)
              Text(book.chapters[chapter].title,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
        actions: [
          if (book.chapters.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.toc),
              tooltip: 'Chapters',
              onPressed: () => _scaffoldKey.currentState?.openDrawer(),
            ),
          IconButton(
            icon: const Icon(Icons.speed),
            tooltip: 'Reading speed',
            onPressed: _showSettings,
          ),
        ],
      ),
      // Chapter list lives in a drawer; hidden when nothing was detected.
      drawer: book.chapters.isEmpty ? null : _chapterDrawer(context),
      body: ScrollablePositionedList.builder(
        itemScrollController: _scrollController,
        itemPositionsListener: _positionsListener,
        itemCount: book.paragraphStart.length,
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 120),
        itemBuilder: (context, para) => _paragraph(context, para),
      ),
      bottomNavigationBar: _controls(context),
    );
  }

  Widget _chapterDrawer(BuildContext context) {
    final current = tts.currentChapter;
    return Drawer(
      child: SafeArea(
        child: ListView.builder(
          itemCount: book.chapters.length + 1,
          itemBuilder: (context, i) {
            if (i == 0) {
              return ListTile(
                title: Text('Chapters',
                    style: Theme.of(context).textTheme.titleLarge),
              );
            }
            final idx = i - 1;
            return ListTile(
              selected: idx == current,
              title: Text(book.chapters[idx].title,
                  maxLines: 2, overflow: TextOverflow.ellipsis),
              onTap: () async {
                Navigator.of(context).pop(); // close the drawer
                // Scroll only after the seek has actually moved `current`.
                await tts.seekChapter(idx);
                if (mounted) _scrollToCurrent();
              },
            );
          },
        ),
      ),
    );
  }

  /// One paragraph as a RichText; each sentence is its own span so the
  /// spoken range can be highlighted and any sentence can be tapped to jump
  /// playback there. (On Windows the whole speaking chunk highlights; on
  /// Android word-progress narrows it to the exact sentence.)
  Widget _paragraph(BuildContext context, int para) {
    final start = book.paragraphStart[para];
    final end = para + 1 < book.paragraphStart.length
        ? book.paragraphStart[para + 1]
        : book.sentences.length;
    final highlight = Theme.of(context).colorScheme.tertiaryContainer;
    final onHighlight = Theme.of(context).colorScheme.onTertiaryContainer;
    final hs = tts.highlightStart;
    final he = tts.highlightEnd;

    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Text.rich(
        TextSpan(
          children: [
            for (var i = start; i < end; i++)
              TextSpan(
                text: '${book.sentences[i]} ',
                style: (i >= hs && i < he)
                    ? TextStyle(backgroundColor: highlight, color: onHighlight)
                    : null,
                recognizer: _tapRecognizer(i),
              ),
          ],
        ),
        style: const TextStyle(fontSize: 18, height: 1.5),
      ),
    );
  }

  /// Tapping any sentence jumps playback to it.
  TapGestureRecognizer _tapRecognizer(int sentenceIndex) =>
      _recognizers.putIfAbsent(sentenceIndex,
          () => TapGestureRecognizer()..onTap = () => tts.seek(sentenceIndex));

  Widget _controls(BuildContext context) {
    final total = book.sentences.length;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Sentence ${tts.current + 1} of $total',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                IconButton(
                  tooltip: 'Previous paragraph',
                  icon: const Icon(Icons.keyboard_double_arrow_left),
                  onPressed: tts.previousParagraph,
                ),
                IconButton(
                  tooltip: 'Previous sentence',
                  icon: const Icon(Icons.skip_previous),
                  onPressed: tts.previousSentence,
                ),
                FilledButton(
                  onPressed: tts.togglePlay,
                  child: tts.preparing
                      ? SizedBox(
                          width: 28,
                          height: 28,
                          child: CircularProgressIndicator(
                            strokeWidth: 3,
                            // Explicit contrast: the default is the primary
                            // colour, invisible on this primary-filled button.
                            color: Theme.of(context).colorScheme.onPrimary,
                          ),
                        )
                      : Icon(tts.playing ? Icons.pause : Icons.play_arrow,
                          size: 32),
                ),
                IconButton(
                  tooltip: 'Stop',
                  icon: const Icon(Icons.stop),
                  onPressed: tts.stop,
                ),
                IconButton(
                  tooltip: 'Next sentence',
                  icon: const Icon(Icons.skip_next),
                  onPressed: tts.nextSentence,
                ),
                IconButton(
                  tooltip: 'Next paragraph',
                  icon: const Icon(Icons.keyboard_double_arrow_right),
                  onPressed: tts.nextParagraph,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// Bottom sheet with the reading-speed slider. There is exactly one voice
  /// (the bundled neural one), so nothing else to configure.
  void _showSettings() {
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (context) => StatefulBuilder(
        builder: (context, setSheetState) => Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Reading speed',
                  style: Theme.of(context).textTheme.titleMedium),
              Slider(
                value: tts.rate,
                min: 0.25, // 0.5x
                max: 1.0, // 2.0x
                divisions: 15,
                label: tts.rate == 0.5
                    ? 'normal'
                    : '${(tts.rate * 2).toStringAsFixed(1)}x',
                // Update only the label while dragging; apply (which restarts
                // the current sentence) once, when the thumb is released.
                onChanged: (v) => setSheetState(() => tts.rate = v),
                onChangeEnd: (v) => tts.setRate(v),
              ),
              if (tts.usingSystemVoice)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    'The built-in voice could not be loaded on this device; '
                    'using the system voice instead.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
