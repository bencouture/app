import 'dart:developer' as developer;

import 'package:device_calendar/device_calendar.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:vikunja_app/data/data_sources/settings_data_source.dart';
import 'package:vikunja_app/domain/entities/all_day_event_display.dart';
import 'package:vikunja_app/domain/entities/event_timing_mode.dart';
import 'package:vikunja_app/domain/entities/task.dart';
import 'package:vikunja_app/domain/repositories/task_repository.dart';

// Tasks carry no duration of their own (Vikunja's due date is a point in
// time), so every synced event gets the same short placeholder block.
const _eventDuration = Duration(minutes: 10);

// Spacing between same-day no-specific-time events in EventTimingMode.sequential.
const _sequentialSlotSpacing = Duration(minutes: 15);

// Vikunja represents "due today, no specific time" as midnight UTC -- there
// is no separate all-day flag to check.
bool _hasNoSpecificTime(DateTime due) {
  final utc = due.toUtc();
  return utc.hour == 0 && utc.minute == 0 && utc.second == 0;
}

// The done-marker is a Google Calendar event color (colorKey, from
// retrieveEventColors/updateEventColor) the user sets on the synced event.
// Android/Google-calendar only -- device_calendar has no per-event color API
// on iOS.
bool _matchesDoneColor(Event event, int doneColorKey) {
  return event.colorKey == doneColorKey;
}

// Same-day tasks, grouped and sorted by id -- stable across syncs, so
// deleting one task shifts the rest down a slot instead of shuffling
// everyone's time around. Shared by both sequential-timing directions below.
Iterable<List<Task>> _sameDayGroups(Iterable<Task> tasks) {
  final byDay = <DateTime, List<Task>>{};
  for (final task in tasks) {
    final due = TZDateTime.from(task.dueDate!, local);
    final day = DateTime(due.year, due.month, due.day);
    byDay.putIfAbsent(day, () => []).add(task);
  }
  for (final dayTasks in byDay.values) {
    dayTasks.sort((a, b) => a.id.compareTo(b.id));
  }
  return byDay.values;
}

// EventTimingMode.sequential + AllDayEventDisplay.midnight: same-day tasks
// get spaced-out starts (midnight, midnight+15m, ...) instead of all landing
// on top of each other.
Map<int, TZDateTime> _sequentialStarts(Iterable<Task> tasks) {
  final starts = <int, TZDateTime>{};
  for (final dayTasks in _sameDayGroups(tasks)) {
    for (var i = 0; i < dayTasks.length; i++) {
      final due = TZDateTime.from(dayTasks[i].dueDate!, local);
      starts[dayTasks[i].id] = TZDateTime(
        local,
        due.year,
        due.month,
        due.day,
      ).add(_sequentialSlotSpacing * i);
    }
  }
  return starts;
}

// EventTimingMode.sequential + AllDayEventDisplay.endOfDay: the mirror image
// of _sequentialStarts. The last task (by the same id ordering) ends right
// at midnight, and earlier tasks end progressively earlier working
// backwards, instead of all landing on the same end-of-day slot.
Map<int, TZDateTime> _sequentialEnds(Iterable<Task> tasks) {
  final ends = <int, TZDateTime>{};
  for (final dayTasks in _sameDayGroups(tasks)) {
    final lastIndex = dayTasks.length - 1;
    for (var i = 0; i < dayTasks.length; i++) {
      final due = TZDateTime.from(dayTasks[i].dueDate!, local);
      final midnight = TZDateTime(
        local,
        due.year,
        due.month,
        due.day,
      ).add(const Duration(days: 1));
      ends[dayTasks[i].id] = midnight.subtract(
        _sequentialSlotSpacing * (lastIndex - i),
      );
    }
  }
  return ends;
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
  final eventColorKey = await settings.getEventColorKey();
  final doneColorKey = await settings.getDoneColorKey();
  final eventTimingMode = await settings.getEventTimingMode();

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

    // Reverse direction: an already-synced event whose color got set to the
    // done color externally means the user marked it done from the calendar
    // app. Batch-fetch once up front rather than per task.
    final eventsById = <String, Event>{};
    if (doneColorKey != null && mapping.isNotEmpty) {
      final retrieveResult = await plugin.retrieveEvents(
        calendarId,
        RetrieveEventsParams(eventIds: mapping.values.toList()),
      );
      if (retrieveResult.isSuccess) {
        for (final event in retrieveResult.data!) {
          if (event.eventId != null) eventsById[event.eventId!] = event;
        }
      } else {
        developer.log(
          "Calendar sync: retrieveEvents failed: ${retrieveResult.errors}",
        );
      }
    }

    // Phase 1: apply calendar-side done reversals and drop tasks that won't
    // get an event at all, so the sequential ordering below only ever sees
    // tasks that are actually going to be scheduled.
    final activeTasks = <Task>[];
    for (final task in taskResponse.toSuccess().body) {
      if (task.done || !task.hasDueDate) continue;

      final existingEventId = mapping[task.id];
      final existingEvent = existingEventId == null
          ? null
          : eventsById[existingEventId];
      if (existingEvent != null &&
          _matchesDoneColor(existingEvent, doneColorKey!)) {
        final updateResult = await taskService.update(
          task.copyWith(done: true),
        );
        if (updateResult.isSuccessful) {
          // Don't mark stillPresent -- the cleanup pass below deletes the
          // event and drops the mapping entry, same as any other done task.
          continue;
        }
        developer.log(
          "Calendar sync: marking task ${task.id} done failed: $updateResult",
        );
      }

      if (_hasNoSpecificTime(task.dueDate!) && !syncAllDayTasks) continue;

      activeTasks.add(task);
    }

    // Sequential timing only applies to midnight/endOfDay -- allDayEvent
    // placements span the whole day each, so there's nothing to space out.
    final noSpecificTimeTasks = activeTasks.where(
      (t) => _hasNoSpecificTime(t.dueDate!),
    );
    final sequentialStarts =
        eventTimingMode == EventTimingMode.sequential &&
            allDayEventDisplay == AllDayEventDisplay.midnight
        ? _sequentialStarts(noSpecificTimeTasks)
        : const <int, TZDateTime>{};
    final sequentialEnds =
        eventTimingMode == EventTimingMode.sequential &&
            allDayEventDisplay == AllDayEventDisplay.endOfDay
        ? _sequentialEnds(noSpecificTimeTasks)
        : const <int, TZDateTime>{};

    for (final task in activeTasks) {
      final existingEventId = mapping[task.id];
      final noSpecificTime = _hasNoSpecificTime(task.dueDate!);

      TZDateTime start;
      TZDateTime end;
      var allDay = false;

      if (noSpecificTime) {
        final day = TZDateTime.from(task.dueDate!, local);
        switch (allDayEventDisplay) {
          case AllDayEventDisplay.midnight:
            start =
                sequentialStarts[task.id] ??
                TZDateTime(local, day.year, day.month, day.day);
            end = start.add(_eventDuration);
            break;
          case AllDayEventDisplay.endOfDay:
            end =
                sequentialEnds[task.id] ??
                TZDateTime(local, day.year, day.month, day.day, 23, 59);
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

      final event = Event(
        calendarId,
        eventId: existingEventId,
        title: task.title,
        start: start,
        end: end,
        allDay: allDay,
      )..updateEventColor(
          eventColor != null && eventColorKey != null
              ? EventColor(eventColor, eventColorKey)
              : null,
        );
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
