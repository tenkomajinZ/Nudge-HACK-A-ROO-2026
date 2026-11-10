import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// A cancellable two-second hold. The timer, not animation speed, gates consent.
class HoldToSubmitButton extends StatefulWidget {
  const HoldToSubmitButton({
    super.key,
    required this.enabled,
    required this.onHeld,
  });
  final bool enabled;
  final VoidCallback onHeld;

  @override
  State<HoldToSubmitButton> createState() => _HoldToSubmitButtonState();
}

class _HoldToSubmitButtonState extends State<HoldToSubmitButton>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final _fill = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 2),
    animationBehavior: AnimationBehavior.preserve,
  );
  final _focus = FocusNode();
  Timer? _timer;
  int? _pointer;
  LogicalKeyboardKey? _key;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  void _start() {
    if (!widget.enabled || _timer != null) return;
    _fill.forward(from: 0);
    _timer = Timer(const Duration(seconds: 2), () {
      _cancel();
      if (mounted && widget.enabled) widget.onHeld();
    });
  }

  void _cancel() {
    _timer?.cancel();
    _timer = null;
    _pointer = null;
    _key = null;
    _fill.reset();
  }

  @override
  void didUpdateWidget(HoldToSubmitButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.enabled) _cancel();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) _cancel();
  }

  @override
  void deactivate() {
    // Descendants are being removed; do not notify their animation listeners.
    _timer?.cancel();
    _timer = null;
    _pointer = null;
    _key = null;
    _fill.stop();
    super.deactivate();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    _fill.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Focus(
      focusNode: _focus,
      onFocusChange: (focused) {
        if (!focused) _cancel();
        setState(() {});
      },
      onKeyEvent: (_, event) {
        if (event.logicalKey != LogicalKeyboardKey.space &&
            event.logicalKey != LogicalKeyboardKey.enter) {
          return KeyEventResult.ignored;
        }
        if (event is KeyDownEvent &&
            widget.enabled &&
            _key == null &&
            _pointer == null) {
          _key = event.logicalKey;
          _start();
        } else if (event is KeyUpEvent && event.logicalKey == _key) {
          _cancel();
        }
        return KeyEventResult.handled;
      },
      child: Semantics(
        button: true,
        enabled: widget.enabled,
        label: 'Hold to submit early',
        onDidLoseAccessibilityFocus: _cancel,
        hint:
            'Hold for two seconds, or hold Space or Enter. Assistive activation starts a two-second confirmation countdown; activate again to cancel.',
        onTap: widget.enabled
            ? () {
                _focus.requestFocus();
                if (_timer == null) {
                  _start();
                } else {
                  _cancel();
                }
              }
            : null,
        child: Listener(
          onPointerDown: (event) {
            if (!widget.enabled || _pointer != null || _key != null) return;
            _focus.requestFocus();
            _pointer = event.pointer;
            _start();
          },
          onPointerMove: (event) {
            final size = context.size;
            if (event.pointer == _pointer &&
                size != null &&
                !(Offset.zero & size).contains(event.localPosition)) {
              _cancel();
            }
          },
          onPointerUp: (event) {
            if (event.pointer == _pointer) _cancel();
          },
          onPointerCancel: (_) => _cancel(),
          child: GestureDetector(
            onTap: widget.enabled ? () {} : null,
            onTapCancel: _cancel,
            excludeFromSemantics: true,
            child: AnimatedBuilder(
              animation: _fill,
              builder: (context, _) => Container(
                clipBehavior: Clip.antiAlias,
                decoration: BoxDecoration(
                  color: colors.surface,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: _focus.hasFocus ? colors.primary : colors.outline,
                    width: _focus.hasFocus ? 2 : 1,
                  ),
                ),
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: FractionallySizedBox(
                          widthFactor: MediaQuery.disableAnimationsOf(context)
                              ? (_fill.value * 4).floor() / 4
                              : _fill.value,
                          heightFactor: 1,
                          child: ColoredBox(color: colors.primaryContainer),
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 14,
                      ),
                      child: Center(
                        child: ExcludeSemantics(
                          child: Text(
                            'Hold to submit early',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: widget.enabled
                                  ? colors.onSurface
                                  : colors.onSurfaceVariant,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
