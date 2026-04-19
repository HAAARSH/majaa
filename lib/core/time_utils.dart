/// Indian-Standard-Time helpers. Every business-facing "today" decision
/// should go through this class so a rep whose phone clock is off or whose
/// device timezone is mis-set still gets the same weekday / date as the
/// rest of the MAJAA fleet.
///
/// IST = UTC + 05:30 (no DST), so we compute by shifting UTC.
class TimeUtils {
  static const Duration istOffset = Duration(hours: 5, minutes: 30);

  /// Current wall-clock time in IST, ignoring the device's local timezone.
  /// Note: the returned DateTime's `.isUtc` is true but the numeric fields
  /// (year / month / day / weekday / hour / minute) are the IST values the
  /// rep sees on the wall. Treat it as a "naive" IST instant for display
  /// and day-comparison purposes.
  static DateTime nowIst() => DateTime.now().toUtc().add(istOffset);

  /// Convert any DateTime to IST wall-clock fields (same semantics as
  /// [nowIst]).
  static DateTime toIst(DateTime dt) => dt.toUtc().add(istOffset);

  /// Today's date in IST as `YYYY-MM-DD`. Safe for DB filters that accept
  /// plain date strings.
  static String todayIstStr() {
    final t = nowIst();
    final y = t.year.toString().padLeft(4, '0');
    final m = t.month.toString().padLeft(2, '0');
    final d = t.day.toString().padLeft(2, '0');
    return '$y-$m-$d';
  }

  /// Today's IST weekday (1=Monday … 7=Sunday), matching Dart's
  /// `DateTime.weekday` convention.
  static int todayIstWeekday() => nowIst().weekday;
}
