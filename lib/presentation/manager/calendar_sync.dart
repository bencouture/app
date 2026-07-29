import 'dart:developer' as developer;

import 'package:device_calendar/device_calendar.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:vikunja_app/data/data_sources/settings_data_source.dart';
import 'package:vikunja_app/domain/entities/all_day_event_display.dart';
import 'package:vikunja_app/domain/repositories/task_repository.dart';

// Tasks carry no duration of their own (Vikunja's due date is a point in
// time), so every synced event gets the same short placeholder block.
const _eventDuration = Duration(minutes: 10);

// Vikunja represents "due today, no specific time" as midnight UTC -- there
// is no separate all-day flag to check.
bool _hasNoSpecificTime(DateTime due) {
  final utc = due.toUtc();
  return utc.hour == 0 && utc.minute == 0 && utc.second == 0;
}

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

  final syncAllDayTasks = await settings.getSyncAllDayTasks();
  final allDayEventDisplay = await settings.getAllDayEventDisplay();
  final eventColor = await settings.getEventColor();

  try {
    var taskResponse = await taskService.getByFilterString(
      "done = false && due_date > 0001-01-01 00:00",
      {
        "filter_include_nulls": ["false"],
      },
    );

    if (!taskResponse.isSuccessful) {
      developer.log("Calendar sync: task fetch failed: $taskResponse");
      return;
    }

    final plugin = DeviceCalendarPlugin();
    final mapping = await settings.getCalendarEventMap();
    final stillPresent = <int>{};

    for (final task in taskResponse.toSuccess().body) {
      if (task.done || !task.hasDueDate) continue;

      final noSpecificTime = _hasNoSpecificTime(task.dueDate!);
      if (noSpecificTime && !syncAllDayTasks) continue;

      TZDateTime start;
      TZDateTime end;
      var allDay = false;

      if (noSpecificTime) {
        final day = TZDateTime.from(task.dueDate!, local);
        switch (allDayEventDisplay) {
          case AllDayEventDisplay.midnight:
            start = TZDateTime(local, day.year, day.month, day.day);
            end = start.add(_eventDuration);
            break;
          case AllDayEventDisplay.endOfDay:
            end = TZDateTime(local, day.year, day.month, day.day, 23, 59);
            start = end.subtract(_eventDuration);
            break;
          case AllDayEventDisplay.allDayEvent:
            start = TZDateTime(local, day.year, day.month, day.day);
            end = start.add(Duration(days: 1));
            allDay = true;
            break;
        }
      } else {
        start = TZDateTime.from(task.dueDate!, local);
        end = start.add(_eventDuration);
      }

      final existingEventId = mapping[task.id];

      final event = Event(
        calendarId,
        eventId: existingEventId,
        title: task.title,
        start: start,
        end: end,
        allDay: allDay,
      )..color = eventColor;
      final result = await plugin.createOrUpdateEvent(event);
      if (result != null && result.isSuccess) {
        mapping[task.id] = result.data!;
        stillPresent.add(task.id);
      } else {
        developer.log(
          "Calendar sync: createOrUpdateEvent failed for task ${task.id}: "
          "${result?.errors}",
        );
      }
    }

    // Drop events for tasks that are done/deleted/no longer due.
    for (final id in mapping.keys.toList()) {
      if (!stillPresent.contains(id)) {
        final result = await plugin.deleteEvent(calendarId, mapping[id]);
        if (result.isSuccess) {
          mapping.remove(id);
        } else {
          developer.log(
            "Calendar sync: deleteEvent failed for task $id: ${result.errors}",
          );
        }
      }
    }

    await settings.setCalendarEventMap(mapping);
  } catch (e, s) {
    developer.log("Calendar sync error:", error: e, stackTrace: s);
  }
}
