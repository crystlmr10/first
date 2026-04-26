import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../utils/sos_dispatch_status.dart';

/// Queue status card below emergency contacts; subscribes to [sos_dispatches] when [dispatchId] is set.
/// Optional [onTap] wraps the card in an ink well (e.g. navigate to full SOS live view).
class SosQueueCard extends StatefulWidget {
  const SosQueueCard({
    super.key,
    required this.ticketNumber,
    required this.dispatchId,
    required this.initialStatus,
    this.onTap,
  });

  final String ticketNumber;
  final String? dispatchId;
  final String initialStatus;

  /// Opens full-screen SOS live view (e.g. from Emergency SOS).
  final VoidCallback? onTap;

  @override
  State<SosQueueCard> createState() => _SosQueueCardState();
}

class _SosQueueCardState extends State<SosQueueCard> {
  static const Color _borderBlue = Color(0xFF1565C0);
  static const Color _headerBeige = Color(0xFFFFF3E0);
  static const Color _pillBlue = Color(0xFFE3F2FD);

  late String _status;
  StreamSubscription<List<Map<String, dynamic>>>? _dispatchSub;

  @override
  void initState() {
    super.initState();
    _status = widget.initialStatus;
    _attachDispatchStream();
  }

  void _attachDispatchStream() {
    _dispatchSub?.cancel();
    _dispatchSub = null;
    final id = widget.dispatchId;
    if (id != null && id.isNotEmpty) {
      _dispatchSub = Supabase.instance.client
          .from('sos_dispatches')
          .stream(primaryKey: const ['id']).eq('id', id)
          .listen(_onDispatchRows);
    }
  }

  @override
  void didUpdateWidget(covariant SosQueueCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    final idChanged = oldWidget.dispatchId != widget.dispatchId;
    final ticketChanged = oldWidget.ticketNumber != widget.ticketNumber;
    final initialChanged = oldWidget.initialStatus != widget.initialStatus;
    if (idChanged || ticketChanged) {
      _status = widget.initialStatus;
      _attachDispatchStream();
      return;
    }
    if (initialChanged) {
      _status = widget.initialStatus;
    }
  }

  void _onDispatchRows(List<Map<String, dynamic>> rows) {
    if (!mounted || rows.isEmpty) return;
    final s = rows.first['status']?.toString().trim();
    if (s == null || s.isEmpty) return;
    if (s != _status) setState(() => _status = s);
  }

  @override
  void dispose() {
    _dispatchSub?.cancel();
    super.dispose();
  }

  String _headerTitle(String raw) {
    if (sosDispatchIsClosed(raw)) return 'REQUEST CLOSED';
    if (raw.trim().toLowerCase() == SosDispatchStatuses.dispatching) {
      return 'DISPATCH CONFIRMED';
    }
    if (raw.trim().toLowerCase() == SosDispatchStatuses.submitted) {
      return 'SOS ACTIVE';
    }
    if (raw.trim().toLowerCase() == SosDispatchStatuses.received) {
      return 'ALERT RECEIVED';
    }
    if (raw.trim().toLowerCase() == SosDispatchStatuses.enRoute) {
      return 'HELP IS ON THE WAY';
    }
    return 'AWAITING DISPATCH';
  }

  Widget _headerLeadingIcon(String raw) {
    if (sosDispatchIsClosed(raw)) {
      return Icon(
        Icons.check_circle_outline,
        size: 20,
        color: Colors.blue.shade800,
      );
    }
    if (raw.trim().toLowerCase() == SosDispatchStatuses.dispatching) {
      return const _SosPinDispatchIcon();
    }
    if (raw.trim().toLowerCase() == SosDispatchStatuses.submitted) {
      return Icon(
        Icons.emergency,
        size: 20,
        color: Colors.blue.shade800,
      );
    }
    if (raw.trim().toLowerCase() == SosDispatchStatuses.received) {
      return Icon(
        Icons.mark_email_read_outlined,
        size: 20,
        color: Colors.blue.shade800,
      );
    }
    if (raw.trim().toLowerCase() == SosDispatchStatuses.enRoute) {
      return Icon(
        Icons.emergency,
        size: 20,
        color: Colors.red.shade700,
      );
    }
    return Icon(
      Icons.hourglass_top,
      size: 20,
      color: Colors.blue.shade800,
    );
  }

  @override
  Widget build(BuildContext context) {
    final active = sosDispatchActiveStepIndex(_status);
    final closed = sosDispatchIsClosed(_status);
    final subtitle = sosDispatchQueueSubtitle(_status);

    // Stack (not IntrinsicHeight + Row.stretch): scroll views give unbounded height;
    // intrinsic height + stretch caused the card to paint with zero height or fail layout.
    final card = Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _borderBlue.withValues(alpha: 0.85)),
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 14, 14),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                    vertical: 10,
                    horizontal: 12,
                  ),
                  decoration: BoxDecoration(
                    color: _headerBeige,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    children: [
                      _headerLeadingIcon(_status),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _headerTitle(_status),
                          style: TextStyle(
                            color: Colors.blue.shade900,
                            fontWeight: FontWeight.w800,
                            fontSize: 13,
                            letterSpacing: 0.4,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 10),
                Container(
                  padding: const EdgeInsets.symmetric(
                    vertical: 10,
                    horizontal: 14,
                  ),
                  decoration: BoxDecoration(
                    color: _pillBlue,
                    borderRadius: BorderRadius.circular(22),
                    border: Border.all(color: Colors.blue.shade200),
                  ),
                  child: Text(
                    subtitle,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Colors.blue.shade800,
                      fontWeight: FontWeight.w600,
                      fontSize: 13,
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                _SosQueueStepper(activeStep: active, isClosed: closed),
                const SizedBox(height: 12),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'SOS ticket',
                      style: TextStyle(
                        color: Colors.grey.shade800,
                        fontWeight: FontWeight.w500,
                        fontSize: 13,
                      ),
                    ),
                    Text(
                      widget.ticketNumber,
                      style: const TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 15,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          Positioned(
            left: 0,
            top: 0,
            bottom: 0,
            width: 4,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: Colors.red.shade700,
                borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(11),
                  bottomLeft: Radius.circular(11),
                ),
              ),
            ),
          ),
        ],
      ),
    );

    final onTap = widget.onTap;
    if (onTap == null) return card;
    return Semantics(
      button: true,
      label: 'Open SOS live view',
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: card,
        ),
      ),
    );
  }
}

/// Map pin with “SOS” for [SosDispatchStatuses.dispatching] header.
class _SosPinDispatchIcon extends StatelessWidget {
  const _SosPinDispatchIcon();

  @override
  Widget build(BuildContext context) {
    const double pinSize = 22;
    return SizedBox(
      width: pinSize,
      height: pinSize + 2,
      child: Stack(
        alignment: Alignment.center,
        clipBehavior: Clip.none,
        children: [
          const Icon(
            Icons.location_on,
            size: 24,
            color: Colors.black87,
          ),
          Positioned(
            top: 1,
            child: Container(
              width: 13,
              height: 13,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white, width: 1.2),
              ),
              alignment: Alignment.center,
              child: const Text(
                'SOS',
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w900,
                  fontSize: 5.5,
                  height: 1,
                  letterSpacing: -0.3,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SosQueueStepper extends StatelessWidget {
  const _SosQueueStepper({
    required this.activeStep,
    required this.isClosed,
  });

  /// 0–3 = current step; 4 = [SosDispatchStatuses.closed] (all complete).
  final int activeStep;
  final bool isClosed;

  static const Color _green = Color(0xFF2E7D32);
  static const Color _red = Color(0xFFC62828);
  static const Color _grey = Color(0xFF9E9E9E);
  static const Color _blueAccent = Color(0xFF1565C0);

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Row(
          children: [
            _dot(0),
            Expanded(child: _connector(0)),
            _dot(1),
            Expanded(child: _connector(1)),
            _dot(2),
            Expanded(child: _connector(2)),
            _dot(3),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            _label(0, 'Sent'),
            _label(1, 'Received'),
            _label(2, 'Dispatch'),
            _label(3, 'En Route'),
          ],
        ),
      ],
    );
  }

  Widget _dot(int i) {
    if (isClosed) {
      return _stepDot(filled: true, color: _green);
    }
    if (i < activeStep) {
      return _stepDot(filled: true, color: _green);
    }
    if (i == activeStep) {
      final c = i == 2 ? _blueAccent : _red;
      return _stepDot(filled: true, color: c);
    }
    return _stepDot(filled: false, color: _grey);
  }

  Widget _connector(int k) {
    if (isClosed) {
      return Container(height: 3, color: _green);
    }
    final solid = k < activeStep;
    if (solid) {
      return Container(height: 3, color: _green);
    }
    return const _DashedConnector();
  }

  Widget _label(int i, String text) {
    if (isClosed) {
      return Text(
        text,
        style: const TextStyle(
          color: _green,
          fontWeight: FontWeight.w600,
          fontSize: 11,
        ),
      );
    }
    if (i < activeStep) {
      return Text(
        text,
        style: const TextStyle(
          color: _green,
          fontWeight: FontWeight.w600,
          fontSize: 11,
        ),
      );
    }
    if (i == activeStep) {
      final isDispatch = i == 2;
      return Text(
        text,
        style: TextStyle(
          color: isDispatch ? _blueAccent : _red,
          fontWeight: FontWeight.w800,
          fontSize: 11,
        ),
      );
    }
    return Text(
      text,
      style: TextStyle(color: Colors.grey.shade700, fontSize: 11),
    );
  }

  Widget _stepDot({required bool filled, required Color color}) {
    return Container(
      width: 14,
      height: 14,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: filled ? color : Colors.transparent,
        border: Border.all(color: color, width: 2),
      ),
    );
  }
}

class _DashedConnector extends StatelessWidget {
  const _DashedConnector();

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) {
        return CustomPaint(
          size: Size(c.maxWidth, 3),
          painter: _HorizontalDashPainter(color: Colors.grey.shade500),
        );
      },
    );
  }
}

class _HorizontalDashPainter extends CustomPainter {
  _HorizontalDashPainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    const dashWidth = 5.0;
    const gap = 4.0;
    var x = 0.0;
    final y = size.height / 2;
    final p = Paint()
      ..color = color
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round;
    while (x < size.width) {
      final end = (x + dashWidth).clamp(0.0, size.width);
      canvas.drawLine(Offset(x, y), Offset(end, y), p);
      x += dashWidth + gap;
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
