import 'dart:developer' as developer;

import 'package:device_calendar_plus/device_calendar_plus.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:vikunja_app/data/data_sources/settings_data_source.dart';
import 'package:vikunja_app/domain/repositories/task_repository.dart';

/// One-way sync: open tasks with due dates -> one event per task on the
/// user's chosen device calendar. Mirrors scheduleDueNotifications/
/// updateWidget: fetch tasks, reconcile against the last-known state, done.
///
/// [settingsDatasource] defaults to the real secure-storage-backed one; the
/// override exists so tests can supply a fake instead of touching secure
/// storage/platform channels (same seam client_test.dart uses for Client).
Future<void> syncCalendar(
  TaskRepository taskService, [
  SettingsDatasource? settingsDatasource,
]) async {
  final settings = settingsDatasource ?? SettingsDatasource(FlutterSecureStorage());

  // Bail before ever touching the calendar plugin: that's what keeps a
  // disabled feature from reaching the permission-gated API.
  if (!await settings.getCalendarSyncEnabled()) return;

  final calendarId = await settings.getSyncCalendarId();
  if (calendarId == null) return;

  try {
    var taskResponse = await taskService.getByFilterString(
      "done = false && due_date != null",
    );

    if (!taskResponse.isSuccessful) return;

    final mapping = await settings.getCalendarEventMap();
    final stillPresent = <int>{};

    for (final task in taskResponse.toSuccess().body) {
      if (task.done || !task.hasDueDate) continue;

      final start = task.dueDate!;
      final end = start.add(Duration(hours: 1));
      final existingEventId = mapping[task.id];

      if (existingEventId != null) {
        await DeviceCalendar.instance.updateEvent(
          eventId: existingEventId,
          title: task.title,
          startDate: start,
          endDate: end,
        );
      } else {
        mapping[task.id] = await DeviceCalendar.instance.createEvent(
          calendarId: calendarId,
          title: task.title,
          startDate: start,
          endDate: end,
        );
      }
      stillPresent.add(task.id);
    }

    // Drop events for tasks that are done/deleted/no longer due.
    for (final id in mapping.keys.toList()) {
      if (!stillPresent.contains(id)) {
        await DeviceCalendar.instance.deleteEvent(eventId: mapping[id]!);
        mapping.remove(id);
      }
    }

    await settings.setCalendarEventMap(mapping);
  } catch (e, s) {
    developer.log("Calendar sync error:", error: e, stackTrace: s);
  }
}
