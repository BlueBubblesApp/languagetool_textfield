import 'dart:math';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:languagetool_textfield/core/enums/mistake_type.dart';
import 'package:languagetool_textfield/domain/highlight_style.dart';
import 'package:languagetool_textfield/domain/language_check_service.dart';
import 'package:languagetool_textfield/domain/mistake.dart';
import 'package:languagetool_textfield/utils/extensions/iterable_extension.dart';
import 'package:languagetool_textfield/utils/mistake_popup.dart';

/// A TextEditingController with overrides buildTextSpan for building
/// marked TextSpans with tap recognizer
class ColoredTextEditingController extends TextEditingController {
  /// Color scheme to highlight mistakes
  final HighlightStyle highlightStyle;

  /// Language tool API index
  final LanguageCheckService languageCheckService;

  /// List which contains Mistake objects spans are built from
  List<Mistake> _mistakes = [];

  /// List of that is used to dispose recognizers after mistakes rebuilt
  final List<TapGestureRecognizer> _recognizers = [];

  /// Reference to the popup widget
  MistakePopup? popupWidget;

  /// Reference to the focus of the LanguageTool TextField
  FocusNode? focusNode;

  Object? _fetchError;

  /// An error that may have occurred during the API fetch.
  Object? get fetchError => _fetchError;

  @override
  set value(TextEditingValue newValue) {
    _handleTextChange(newValue.text);
    super.value = newValue;
  }

  /// Controller constructor
  ColoredTextEditingController({
    required this.languageCheckService,
    this.highlightStyle = const HighlightStyle(),
  });

  /// Close the popup widget
  void _closePopup() => popupWidget?.popupRenderer.dismiss();

  /// Generates TextSpan from Mistake list
  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    final formattedTextSpans = _generateSpans(
      context,
      style: style,
    );

    return TextSpan(
      children: formattedTextSpans.toList(),
    );
  }

  @override
  void dispose() {
    languageCheckService.dispose();
    super.dispose();
  }

  /// Replaces mistake with given replacement
  void replaceMistake(Mistake mistake, String replacement) {
    text = text.replaceRange(mistake.offset, mistake.endOffset, replacement);
    _mistakes.remove(mistake);
    focusNode?.requestFocus();
    Future.microtask.call(() {
      final newOffset = mistake.offset + replacement.length;
      selection = TextSelection.fromPosition(TextPosition(offset: newOffset));
    });
  }

  /// Clear mistakes list when text mas modified and get a new list of mistakes
  /// via API
  Future<void> _handleTextChange(String newText) async {
    ///set value triggers each time, even when cursor changes its location
    ///so this check avoid cleaning Mistake list when text wasn't really changed
    if (newText == text) return;

    // If we have a text change and we have a popup on hold
    // it will close the popup
    _closePopup();

    _mistakes.clear();
    for (final recognizer in _recognizers) {
      recognizer.dispose();
    }
    _recognizers.clear();

    final mistakesWrapper = await languageCheckService.findMistakes(newText);

    _mistakes =
        mistakesWrapper.hasResult ? mistakesWrapper.result().toList() : [];
    _fetchError = mistakesWrapper.error;

    notifyListeners();
  }

  /// Generator function to create TextSpan instances
  Iterable<TextSpan> _generateSpans(
    BuildContext context, {
    TextStyle? style,
  }) sync* {
    int currentOffset = 0; // enter index

    for (final Mistake mistake in _mistakes) {
      /// TextSpan before mistake
      yield TextSpan(
        text: text.substring(
          currentOffset,
          min(mistake.offset, text.length),
        ),
        style: style,
      );

      /// Get a highlight color
      final Color mistakeColor = _getMistakeColor(mistake.type);

      /// Create a gesture recognizer for mistake
      final _onTap = TapGestureRecognizer()
        ..onTapDown = (details) {
          popupWidget?.show(
            context,
            mistake: mistake,
            popupPosition: details.globalPosition,
            controller: this,
            onClose: (details) {
              _setCursorOnMistake(context, details: details, style: style);
            },
          );
          _setCursorOnMistake(context, details: details, style: style);
        };

      /// Adding recognizer to the list for future disposing
      _recognizers.add(_onTap);

      /// Mistake highlighted TextSpan
      yield TextSpan(
        children: [
          TextSpan(
            text: text.substring(
              mistake.offset,
              min(mistake.endOffset, text.length),
            ),
            mouseCursor: MaterialStateMouseCursor.textable,
            style: style?.copyWith(
              backgroundColor: mistakeColor.withOpacity(
                highlightStyle.backgroundOpacity,
              ),
              decoration: highlightStyle.decoration,
              decorationColor: mistakeColor,
              decorationThickness: highlightStyle.mistakeLineThickness,
            ),
            recognizer: _onTap,
          ),
        ],
      );

      currentOffset = min(mistake.endOffset, text.length);
    }

    final textAfterMistake = text.substring(currentOffset);

    /// TextSpan after mistake
    yield TextSpan(
      // If the last item is empty TextSpan (or no TextSpan), the tappable
      // area is messed up.
      text: textAfterMistake.isEmpty ? ' ' : textAfterMistake,
      style: style,
    );
  }

  /// Returns color for mistake TextSpan style
  Color _getMistakeColor(MistakeType type) {
    switch (type) {
      case MistakeType.misspelling:
        return highlightStyle.misspellingMistakeColor;
      case MistakeType.typographical:
        return highlightStyle.typographicalMistakeColor;
      case MistakeType.grammar:
        return highlightStyle.grammarMistakeColor;
      case MistakeType.uncategorized:
        return highlightStyle.uncategorizedMistakeColor;
      case MistakeType.nonConformance:
        return highlightStyle.nonConformanceMistakeColor;
      case MistakeType.style:
        return highlightStyle.styleMistakeColor;
      case MistakeType.other:
        return highlightStyle.otherMistakeColor;
    }
  }

  void _setCursorOnMistake(
    BuildContext context, {
    required TapDownDetails details,
    TextStyle? style,
  }) {
    final offset = _getValidTextOffset(context, details: details, style: style);
    if (offset == null) return;
    focusNode?.requestFocus();
    Future.microtask.call(() {
      selection = TextSelection.collapsed(offset: offset);

      final mistake = _mistakes.firstWhereOrNull(
        (e) => e.offset <= offset && offset < e.endOffset,
      );

      if (mistake == null) return;
      _closePopup();
      popupWidget?.show(
        context,
        mistake: mistake,
        popupPosition: details.globalPosition,
        controller: this,
        onClose: (details) {
          _setCursorOnMistake(context, details: details, style: style);
        },
      );
    });
  }

  int? _getValidTextOffset(
    BuildContext context, {
    required TapDownDetails details,
    TextStyle? style,
  }) {
    final renderBox = context.findRenderObject() as RenderBox?;
    final localOffset = renderBox?.globalToLocal(details.globalPosition);
    if (localOffset == null) return null;
    final elementHeight = renderBox?.size.height ?? 0;
    if (localOffset.dy < 0 || localOffset.dy > elementHeight) return null;

    final textPainter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
    );

    textPainter.layout();

    return textPainter.getPositionForOffset(localOffset).offset;
  }
}
