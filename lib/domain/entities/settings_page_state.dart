import 'package:vikunja_app/core/theming/theme_mode.dart';
import 'package:vikunja_app/domain/entities/all_day_event_display.dart';
import 'package:vikunja_app/domain/entities/event_timing_mode.dart';
import 'package:vikunja_app/domain/entities/project.dart';
import 'package:vikunja_app/domain/entities/user.dart';
import 'package:vikunja_app/domain/entities/version.dart';

class SettingsPageState {
  User user;
  List<Project> projects;

  bool ignoreCertificates;
  bool sentryEnabled;
  bool versionNotifications;

  int refreshInterval;

  FlutterThemeMode themeMode;
  bool dynamicColors;

  bool calendarSyncEnabled;
  String? syncCalendarId;
  bool syncAllDayTasks;
  AllDayEventDisplay allDayEventDisplay;
  int? eventColor;
  int? eventColorKey;
  int? doneColorKey;
  EventTimingMode eventTimingMode;

  Version? currentVersion;

  SettingsPageState(
    this.user,
    this.projects,
    this.ignoreCertificates,
    this.sentryEnabled,
    this.versionNotifications,
    this.refreshInterval,
    this.themeMode,
    this.dynamicColors,
    this.calendarSyncEnabled,
    this.syncCalendarId,
    this.syncAllDayTasks,
    this.allDayEventDisplay,
    this.eventColor,
    this.eventColorKey,
    this.doneColorKey,
    this.eventTimingMode,
    this.currentVersion,
  );
}
