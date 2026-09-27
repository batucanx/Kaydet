import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../core/date_format.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/tokens.dart';

class _ScheduleCustomAction {
  const _ScheduleCustomAction();
}

/// İleri tarihli gönderim (Schedule Send) seçeneklerini sunan alt sayfa.
class ScheduleSendSheet extends StatelessWidget {
  const ScheduleSendSheet({
    super.key,
    required this.onScheduleSelected,
    this.onCustomSelected,
  });

  final ValueChanged<DateTime> onScheduleSelected;
  final VoidCallback? onCustomSelected;

  static Future<DateTime?> show(BuildContext context) async {
    final result = await showModalBottomSheet<Object?>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => ScheduleSendSheet(
        onScheduleSelected: (dt) => Navigator.of(ctx).pop(dt),
        onCustomSelected: () =>
            Navigator.of(ctx).pop(const _ScheduleCustomAction()),
      ),
    );

    if (result is DateTime) {
      return result;
    }
    if (result is _ScheduleCustomAction && context.mounted) {
      return ScheduleCustomTimeDialog.show(context);
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final now = DateTime.now();

    // 1. Bu Akşam (veya gece ise yarın sabah)
    final thisEvening = DateTime(now.year, now.month, now.day, 18, 0);
    final thisEveningOption = thisEvening.isAfter(now.add(const Duration(minutes: 15)))
        ? thisEvening
        : DateTime(now.year, now.month, now.day, 21, 0).isAfter(now.add(const Duration(minutes: 15)))
            ? DateTime(now.year, now.month, now.day, 21, 0)
            : null;

    // 2. Yarın Sabah (08:30)
    final tomorrow = now.add(const Duration(days: 1));
    final tomorrowMorning = DateTime(tomorrow.year, tomorrow.month, tomorrow.day, 8, 30);

    // 3. Yarın Öğleden Sonra (13:30)
    final tomorrowAfternoon = DateTime(tomorrow.year, tomorrow.month, tomorrow.day, 13, 30);

    // 4. Pazartesi Sabahı (08:30)
    var daysUntilMonday = (DateTime.monday - now.weekday) % 7;
    if (daysUntilMonday <= 0) daysUntilMonday += 7;
    final nextMondayDate = now.add(Duration(days: daysUntilMonday));
    final nextMonday = DateTime(
      nextMondayDate.year,
      nextMondayDate.month,
      nextMondayDate.day,
      8,
      30,
    );

    return Container(
      decoration: BoxDecoration(
        color: t.surfaceElevated,
        borderRadius: const BorderRadius.vertical(
          top: Radius.circular(Radii.lg),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.18),
            blurRadius: 16,
            offset: const Offset(0, -2),
          ),
        ],
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.only(bottom: Space.md),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Sürükleme tutamacı
              Center(
                child: Container(
                  width: 38,
                  height: 4,
                  margin: const EdgeInsets.symmetric(vertical: Space.sm),
                  decoration: BoxDecoration(
                    color: t.textTertiary.withValues(alpha: 0.35),
                    borderRadius: BorderRadius.circular(Radii.full),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: Space.lg,
                  vertical: Space.xs,
                ),
                child: Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(Space.xs),
                      decoration: BoxDecoration(
                        color: t.accent.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(Radii.sm),
                      ),
                      child: Icon(
                        LucideIcons.calendarClock,
                        size: 20,
                        color: t.accent,
                      ),
                    ),
                    const SizedBox(width: Space.md),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'İleri Tarihli Gönderim',
                            style: AppText.titleMedium.copyWith(
                              color: t.textPrimary,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            'İletiniz zamanı geldiğinde otomatik olarak iletilir',
                            style: AppText.bodyMedium.copyWith(
                              fontSize: 12,
                              color: t.textTertiary,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: Space.xs),
              const Divider(height: 1),
              const SizedBox(height: Space.xs),
              if (thisEveningOption != null)
                _ScheduleOptionTile(
                  icon: LucideIcons.sunset,
                  title: 'Bu Akşam',
                  timeText: formatScheduleDate(thisEveningOption),
                  onTap: () => onScheduleSelected(thisEveningOption),
                ),
              _ScheduleOptionTile(
                icon: LucideIcons.sunrise,
                title: 'Yarın Sabah',
                timeText: formatScheduleDate(tomorrowMorning),
                onTap: () => onScheduleSelected(tomorrowMorning),
              ),
              _ScheduleOptionTile(
                icon: LucideIcons.sunMedium,
                title: 'Yarın Öğleden Sonra',
                timeText: formatScheduleDate(tomorrowAfternoon),
                onTap: () => onScheduleSelected(tomorrowAfternoon),
              ),
              if (daysUntilMonday > 1)
                _ScheduleOptionTile(
                  icon: LucideIcons.briefcase,
                  title: 'Pazartesi Sabahı',
                  timeText: formatScheduleDate(nextMonday),
                  onTap: () => onScheduleSelected(nextMonday),
                ),
              _ScheduleOptionTile(
                icon: LucideIcons.calendarCheck,
                title: 'Tarih ve Saat Seç…',
                subtitle: 'Özel bir zaman dilimi belirleyin',
                onTap: onCustomSelected ?? () => _pickCustomDateTime(context),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _pickCustomDateTime(BuildContext context) async {
    final picked = await ScheduleCustomTimeDialog.show(context);
    if (picked != null && context.mounted) {
      onScheduleSelected(picked);
    }
  }
}

/// Outlook tarzı "Bir zaman seçin" diyaloğu (bkz. referans görsel).
class ScheduleCustomTimeDialog extends StatefulWidget {
  const ScheduleCustomTimeDialog({
    super.key,
    this.initialDateTime,
  });

  final DateTime? initialDateTime;

  static Future<DateTime?> show(
    BuildContext context, {
    DateTime? initialDateTime,
  }) {
    return showDialog<DateTime>(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => ScheduleCustomTimeDialog(
        initialDateTime: initialDateTime,
      ),
    );
  }

  @override
  State<ScheduleCustomTimeDialog> createState() =>
      _ScheduleCustomTimeDialogState();
}

class _ScheduleCustomTimeDialogState extends State<ScheduleCustomTimeDialog> {
  late DateTime _selectedDate;
  late TimeOfDay _selectedTime;

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    if (widget.initialDateTime != null) {
      _selectedDate = widget.initialDateTime!;
      _selectedTime = TimeOfDay.fromDateTime(widget.initialDateTime!);
    } else if (now.hour < 21) {
      _selectedDate = now;
      _selectedTime = TimeOfDay(hour: (now.hour + 1).clamp(0, 23), minute: 0);
    } else {
      _selectedDate = now.add(const Duration(days: 1));
      _selectedTime = const TimeOfDay(hour: 8, minute: 30);
    }
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _selectedDate.isBefore(now) ? now : _selectedDate,
      firstDate: now,
      lastDate: now.add(const Duration(days: 365)),
      confirmText: 'Seç',
      cancelText: 'Vazgeç',
    );
    if (picked != null && mounted) {
      setState(() => _selectedDate = picked);
    }
  }

  Future<void> _pickTime() async {
    final picked = await showTimePicker(
      context: context,
      initialTime: _selectedTime,
      confirmText: 'Seç',
      cancelText: 'Vazgeç',
    );
    if (picked != null && mounted) {
      setState(() => _selectedTime = picked);
    }
  }

  void _submit() {
    final now = DateTime.now();
    final candidate = DateTime(
      _selectedDate.year,
      _selectedDate.month,
      _selectedDate.day,
      _selectedTime.hour,
      _selectedTime.minute,
    );

    if (candidate.isBefore(now.add(const Duration(minutes: 1)))) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Lütfen gelecekteki bir tarih ve saat seçin.'),
        ),
      );
      return;
    }

    Navigator.of(context).pop(candidate);
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final dateStr = formatPickerDate(_selectedDate);
    final timeStr = formatPickerTime(
      DateTime(2026, 1, 1, _selectedTime.hour, _selectedTime.minute),
    );

    return Dialog(
      backgroundColor: t.surfaceElevated,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Radii.md),
      ),
      insetPadding: const EdgeInsets.symmetric(
        horizontal: Space.xl,
        vertical: Space.xxl,
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          Space.xl,
          Space.xl,
          Space.xl,
          Space.md,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Bir zaman seçin',
              style: TextStyle(
                color: t.accent,
                fontWeight: FontWeight.bold,
                fontSize: 18,
              ),
            ),
            const SizedBox(height: Space.lg),
            InkWell(
              onTap: _pickDate,
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: Space.sm),
                decoration: BoxDecoration(
                  border: Border(bottom: BorderSide(color: t.divider)),
                ),
                child: Text(
                  dateStr,
                  style: TextStyle(
                    color: t.textPrimary,
                    fontSize: 16,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ),
            const SizedBox(height: Space.md),
            InkWell(
              onTap: _pickTime,
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: Space.sm),
                decoration: BoxDecoration(
                  border: Border(bottom: BorderSide(color: t.divider)),
                ),
                child: Text(
                  timeStr,
                  style: TextStyle(
                    color: t.textPrimary,
                    fontSize: 16,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ),
            const SizedBox(height: Space.lg),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: _submit,
                  style: TextButton.styleFrom(
                    foregroundColor: t.accent,
                    padding: const EdgeInsets.symmetric(
                      horizontal: Space.md,
                      vertical: Space.sm,
                    ),
                  ),
                  child: const Text(
                    'Zamanla',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 15,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _ScheduleOptionTile extends StatelessWidget {
  const _ScheduleOptionTile({
    required this.icon,
    required this.title,
    this.timeText,
    this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String? timeText;
  final String? subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;

    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: Space.lg,
          vertical: Space.sm,
        ),
        child: Row(
          children: [
            Icon(icon, size: 20, color: t.textSecondary),
            const SizedBox(width: Space.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppText.bodyMedium.copyWith(
                      fontWeight: FontWeight.w600,
                      color: t.textPrimary,
                    ),
                  ),
                  if (subtitle != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      subtitle!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppText.bodyMedium.copyWith(
                        fontSize: 11.5,
                        color: t.textTertiary,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            if (timeText != null && timeText!.isNotEmpty) ...[
              const SizedBox(width: Space.sm),
              Text(
                timeText!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppText.bodyMedium.copyWith(
                  fontSize: 12,
                  color: t.accent,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
            if (subtitle != null && (timeText == null || timeText!.isEmpty))
              Icon(LucideIcons.chevronRight, size: 16, color: t.textTertiary),
          ],
        ),
      ),
    );
  }
}
