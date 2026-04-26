/// DB values for [public.sos_dispatches.status] (see Supabase SQL CHECK).
abstract final class SosDispatchStatuses {
  SosDispatchStatuses._();
  static const submitted = 'submitted';
  static const received = 'received';
  static const dispatching = 'dispatching';
  static const enRoute = 'en_route';
  static const closed = 'closed';
}

/// Result of inserting a row (client reads [id], [ticket], [status] from `.select()`).
class SosDispatchInsertResult {
  const SosDispatchInsertResult({
    required this.id,
    required this.ticket,
    required this.status,
    this.submittedAt,
  });

  final String id;
  final String ticket;
  final String status;

  /// From DB [submitted_at] when returned by `.select()` after insert.
  final DateTime? submittedAt;
}

/// Passed from [_SosBroadcastPage] to [EmergencyPage] when the user closes SOS ACTIVE.
class SosDispatchHandoff {
  const SosDispatchHandoff({
    required this.ticket,
    required this.dispatchId,
    required this.status,
  });

  /// Display label (e.g. SOS-012 or "Pending sync").
  final String ticket;

  /// Row id for Realtime `.eq('id', …)`. Null if insert failed (no DB row).
  final String? dispatchId;

  /// One of [SosDispatchStatuses] (normalized lowercase).
  final String status;
}

/// Maps DB status → active step index 0–3, or 4 when [SosDispatchStatuses.closed].
int sosDispatchActiveStepIndex(String rawStatus) {
  final s = rawStatus.trim().toLowerCase();
  switch (s) {
    case SosDispatchStatuses.submitted:
      return 0;
    case SosDispatchStatuses.received:
      return 1;
    case SosDispatchStatuses.dispatching:
      return 2;
    case SosDispatchStatuses.enRoute:
      return 3;
    case SosDispatchStatuses.closed:
      return 4;
    default:
      return 0;
  }
}

bool sosDispatchIsClosed(String rawStatus) {
  return rawStatus.trim().toLowerCase() == SosDispatchStatuses.closed;
}

/// `true` while the dispatch is not [SosDispatchStatuses.closed] (user must not start another Cebu SOS).
bool sosDispatchIsOpen(String rawStatus) {
  return !sosDispatchIsClosed(rawStatus);
}

/// Short line under the header for the queue card (UI copy).
String sosDispatchQueueSubtitle(String rawStatus) {
  final s = rawStatus.trim().toLowerCase();
  switch (s) {
    case SosDispatchStatuses.submitted:
      return 'Your alert has been sent';
    case SosDispatchStatuses.received:
      return 'Nearby responders have been notified';
    case SosDispatchStatuses.dispatching:
      return 'Your dispatch has been confirmed';
    case SosDispatchStatuses.enRoute:
      return 'Unit TLY-01 Dispatched';
    case SosDispatchStatuses.closed:
      return 'This SOS request is closed';
    default:
      return 'Dispatcher is reviewing your location';
  }
}
