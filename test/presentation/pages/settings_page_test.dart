import 'dart:convert';

import 'package:device_calendar/device_calendar.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vikunja_app/domain/entities/all_day_event_display.dart';
import 'package:vikunja_app/domain/entities/event_timing_mode.dart';
import 'package:vikunja_app/domain/entities/project.dart';
import 'package:vikunja_app/domain/entities/settings_page_state.dart';
import 'package:vikunja_app/domain/entities/user.dart';
import 'package:vikunja_app/core/theming/theme_mode.dart';
import 'package:vikunja_app/l10n/gen/app_localizations.dart';
import 'package:vikunja_app/presentation/manager/settings_controller.dart';
import 'package:vikunja_app/presentation/pages/settings_page.dart'
    hide SettingsPageState;

// See calendar_sync_test.dart: device_calendar has no swappable
// platform-interface seam, so it's mocked directly over its MethodChannel.
const _calendarChannel = MethodChannel('plugins.builttoroam.com/device_calendar');

// The settings page reads/writes calendar-sync settings through a real,
// secure-storage-backed SettingsDatasource whenever it calls syncCalendar()
// directly (rather than through the mocked SettingsController) -- mocked
// here so those calls resolve instead of throwing MissingPluginException.
// Every read returns null, so syncCalendar() bails out at its very first
// "is sync enabled" check without touching anything else.
const _secureStorageChannel = MethodChannel(
  'plugins.it_nomads.com/flutter_secure_storage',
);

class _RecordingSettingsController extends SettingsController {
  SettingsPageState model;
  final List<String> calls = [];

  _RecordingSettingsController(this.model);

  @override
  Future<SettingsPageState> build() async => model;

  void _apply(SettingsPageState next) {
    model = next;
    state = AsyncData(next);
  }

  @override
  Future<void> setCalendarSyncEnabled(bool value) async {
    calls.add('setCalendarSyncEnabled($value)');
    _apply(_copyWith(model, calendarSyncEnabled: value));
  }

  @override
  Future<void> setSyncCalendarId(String? calendarId) async {
    calls.add('setSyncCalendarId($calendarId)');
    _apply(_copyWith(model, syncCalendarId: () => calendarId));
  }

  @override
  Future<void> setSyncAllDayTasks(bool value) async {
    calls.add('setSyncAllDayTasks($value)');
    _apply(_copyWith(model, syncAllDayTasks: value));
  }

  @override
  Future<void> setAllDayEventDisplay(AllDayEventDisplay value) async {
    calls.add('setAllDayEventDisplay($value)');
    _apply(_copyWith(model, allDayEventDisplay: value));
  }

  @override
  Future<void> setEventColor(EventColor? selection) async {
    calls.add('setEventColor(${selection?.color}, ${selection?.colorKey})');
    _apply(
      _copyWith(
        model,
        eventColor: () => selection?.color,
        eventColorKey: () => selection?.colorKey,
      ),
    );
  }

  @override
  Future<void> setDoneColorKey(int? colorKey) async {
    calls.add('setDoneColorKey($colorKey)');
    _apply(_copyWith(model, doneColorKey: () => colorKey));
  }

  @override
  Future<void> setEventTimingMode(EventTimingMode value) async {
    calls.add('setEventTimingMode($value)');
    _apply(_copyWith(model, eventTimingMode: value));
  }
}

// SettingsPageState fields are plain mutable fields with no copyWith of its
// own; nullable fields take a value-producing callback so "set to null" is
// distinguishable from "leave unchanged".
SettingsPageState _copyWith(
  SettingsPageState state, {
  bool? calendarSyncEnabled,
  String? Function()? syncCalendarId,
  bool? syncAllDayTasks,
  AllDayEventDisplay? allDayEventDisplay,
  int? Function()? eventColor,
  int? Function()? eventColorKey,
  int? Function()? doneColorKey,
  EventTimingMode? eventTimingMode,
}) {
  return SettingsPageState(
    state.user,
    state.projects,
    state.ignoreCertificates,
    state.sentryEnabled,
    state.versionNotifications,
    state.refreshInterval,
    state.themeMode,
    state.dynamicColors,
    calendarSyncEnabled ?? state.calendarSyncEnabled,
    syncCalendarId != null ? syncCalendarId() : state.syncCalendarId,
    syncAllDayTasks ?? state.syncAllDayTasks,
    allDayEventDisplay ?? state.allDayEventDisplay,
    eventColor != null ? eventColor() : state.eventColor,
    eventColorKey != null ? eventColorKey() : state.eventColorKey,
    doneColorKey != null ? doneColorKey() : state.doneColorKey,
    eventTimingMode ?? state.eventTimingMode,
    state.currentVersion,
  );
}

SettingsPageState _initialState({
  bool calendarSyncEnabled = false,
  String? syncCalendarId,
  bool syncAllDayTasks = false,
  AllDayEventDisplay allDayEventDisplay = AllDayEventDisplay.midnight,
  int? eventColor,
  int? eventColorKey,
  int? doneColorKey,
  EventTimingMode eventTimingMode = EventTimingMode.simultaneous,
}) {
  return SettingsPageState(
    // Empty username keeps the user-header's CircleAvatar from attempting a
    // real NetworkImage fetch (`user.username != ""` gates that branch) --
    // network access is blocked in the widget-test environment anyway.
    User(username: ''),
    <Project>[],
    false,
    false,
    false,
    0,
    FlutterThemeMode.system,
    false,
    calendarSyncEnabled,
    syncCalendarId,
    syncAllDayTasks,
    allDayEventDisplay,
    eventColor,
    eventColorKey,
    doneColorKey,
    eventTimingMode,
    null,
  );
}

// The settings ListView is taller than the test viewport, so rows below
// the fold aren't built at all until scrolled into view.
Future<void> _scrollTo(WidgetTester tester, Finder finder) {
  return tester.scrollUntilVisible(
    finder,
    200,
    scrollable: find.byType(Scrollable).first,
  );
}

Future<_RecordingSettingsController> _pumpSettingsPage(
  WidgetTester tester,
  SettingsPageState initial,
) async {
  // Default 800x600 test surface is too short: dropdown menu overlays
  // (e.g. "Mark done via color") can render partly below it, so taps on
  // items near the bottom miss hit-testing. A taller surface avoids that.
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  tester.view.physicalSize = const Size(800, 2000);
  tester.view.devicePixelRatio = 1.0;

  final controller = _RecordingSettingsController(initial);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        settingsControllerProvider.overrideWith(() => controller),
      ],
      child: const MaterialApp(
        home: SettingsPage(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: Locale('en'),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return controller;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late bool permissionGranted;
  late List<Map<String, dynamic>> calendars;
  late List<String> createCalendarCalls;
  late String createdCalendarId;

  setUp(() {
    permissionGranted = true;
    calendars = [];
    createCalendarCalls = [];
    createdCalendarId = 'created-cal';

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_calendarChannel, (call) async {
      switch (call.method) {
        case 'requestPermissions':
          return permissionGranted;
        case 'retrieveCalendars':
          return jsonEncode(calendars);
        case 'createCalendar':
          createCalendarCalls.add(
            (call.arguments as Map)['calendarName'] as String,
          );
          return createdCalendarId;
        default:
          return null;
      }
    });

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_secureStorageChannel, (call) async {
      switch (call.method) {
        case 'read':
          return null;
        case 'containsKey':
          return false;
        default:
          return null;
      }
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_calendarChannel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_secureStorageChannel, null);
  });

  testWidgets('calendar sync sub-settings are hidden while sync is disabled', (
    tester,
  ) async {
    await _pumpSettingsPage(tester, _initialState(calendarSyncEnabled: false));

    expect(find.text('Sync tasks to calendar'), findsOneWidget);
    expect(find.text('Sync calendar'), findsNothing);
    expect(find.text('Sync all-day tasks'), findsNothing);
    expect(find.text('Show all-day tasks as'), findsNothing);
    expect(find.text('Event creation'), findsNothing);
    expect(find.text('Event color'), findsNothing);
    expect(find.text('Mark done via color'), findsNothing);
  });

  testWidgets('enabling sync requests permission first and bails if denied', (
    tester,
  ) async {
    permissionGranted = false;
    final controller = await _pumpSettingsPage(
      tester,
      _initialState(calendarSyncEnabled: false),
    );

    await tester.tap(find.widgetWithText(SwitchListTile, 'Sync tasks to calendar'));
    await tester.pumpAndSettle();

    expect(controller.calls, isEmpty);
    expect(find.text('Sync calendar'), findsNothing);
  });

  testWidgets('enabling sync persists the setting once permission is granted', (
    tester,
  ) async {
    permissionGranted = true;
    final controller = await _pumpSettingsPage(
      tester,
      _initialState(calendarSyncEnabled: false),
    );

    await tester.tap(find.widgetWithText(SwitchListTile, 'Sync tasks to calendar'));
    await tester.pumpAndSettle();

    expect(controller.calls, ['setCalendarSyncEnabled(true)']);
    expect(find.text('Sync calendar'), findsOneWidget);
    // Event color / Mark done via color hide themselves entirely rather
    // than show a picker that can only ever offer "Default"/"None" --
    // retrieveEventColors always returns null on this non-Android test
    // host, same structural limitation device_calendar's own test suite
    // documents, so these can never render here.
    expect(find.text('Event color'), findsNothing);
    expect(find.text('Mark done via color'), findsNothing);
    // syncAllDayTasks is still false, so this row stays hidden.
    expect(find.text('Show all-day tasks as'), findsNothing);
  });

  testWidgets('calendar dropdown lists writable calendars and excludes read-only ones', (
    tester,
  ) async {
    calendars = [
      {'id': 'writable-1', 'name': 'Home', 'isReadOnly': false},
      {'id': 'readonly-1', 'name': 'Holidays', 'isReadOnly': true},
    ];
    await _pumpSettingsPage(
      tester,
      _initialState(calendarSyncEnabled: true, syncCalendarId: 'writable-1'),
    );

    await _scrollTo(tester, find.byType(DropdownButton<String>));
    await tester.tap(find.byType(DropdownButton<String>));
    await tester.pumpAndSettle();

    expect(find.text('Home').hitTestable(), findsOneWidget);
    expect(find.text('Holidays'), findsNothing);
    expect(find.text('Vikunja (new calendar)').hitTestable(), findsOneWidget);
  });

  testWidgets('picking "new calendar" creates one and syncs the picker to it', (
    tester,
  ) async {
    final controller = await _pumpSettingsPage(
      tester,
      _initialState(calendarSyncEnabled: true),
    );

    await _scrollTo(tester, find.byType(DropdownButton<String>));
    await tester.tap(find.byType(DropdownButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Vikunja (new calendar)').hitTestable());
    await tester.pumpAndSettle();

    expect(createCalendarCalls, ['Vikunja']);
    expect(controller.calls, ['setSyncCalendarId(created-cal)']);
  });

  testWidgets('picking an existing calendar sets it directly, no creation', (
    tester,
  ) async {
    calendars = [
      {'id': 'writable-1', 'name': 'Home', 'isReadOnly': false},
    ];
    final controller = await _pumpSettingsPage(
      tester,
      _initialState(calendarSyncEnabled: true),
    );

    await _scrollTo(tester, find.byType(DropdownButton<String>));
    await tester.tap(find.byType(DropdownButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Home').hitTestable());
    await tester.pumpAndSettle();

    expect(createCalendarCalls, isEmpty);
    expect(controller.calls, ['setSyncCalendarId(writable-1)']);
  });

  testWidgets('enabling all-day sync reveals the display-mode row', (
    tester,
  ) async {
    final controller = await _pumpSettingsPage(
      tester,
      _initialState(calendarSyncEnabled: true, syncAllDayTasks: false),
    );

    expect(find.text('Show all-day tasks as'), findsNothing);

    await _scrollTo(
      tester,
      find.widgetWithText(SwitchListTile, 'Sync all-day tasks'),
    );
    await tester.tap(find.widgetWithText(SwitchListTile, 'Sync all-day tasks'));
    await tester.pumpAndSettle();

    expect(controller.calls, ['setSyncAllDayTasks(true)']);
    await _scrollTo(tester, find.text('Show all-day tasks as'));
    expect(find.text('Show all-day tasks as'), findsOneWidget);
  });

  testWidgets('changing the all-day display mode persists the new value', (
    tester,
  ) async {
    final controller = await _pumpSettingsPage(
      tester,
      _initialState(calendarSyncEnabled: true, syncAllDayTasks: true),
    );

    await _scrollTo(tester, find.byType(DropdownButton<AllDayEventDisplay>));
    await tester.tap(find.byType(DropdownButton<AllDayEventDisplay>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('As an all-day event').hitTestable());
    await tester.pumpAndSettle();

    expect(controller.calls, [
      'setAllDayEventDisplay(AllDayEventDisplay.allDayEvent)',
    ]);
  });

  testWidgets(
    'event creation row is hidden for the all-day-event display mode',
    (tester) async {
      await _pumpSettingsPage(
        tester,
        _initialState(
          calendarSyncEnabled: true,
          syncAllDayTasks: true,
          allDayEventDisplay: AllDayEventDisplay.allDayEvent,
        ),
      );
      expect(find.text('Event creation'), findsNothing);
    },
  );

  testWidgets(
    'event creation row shows for the midnight display mode',
    (tester) async {
      await _pumpSettingsPage(
        tester,
        _initialState(
          calendarSyncEnabled: true,
          syncAllDayTasks: true,
          allDayEventDisplay: AllDayEventDisplay.midnight,
        ),
      );
      await _scrollTo(tester, find.text('Event creation'));
      expect(find.text('Event creation'), findsOneWidget);
    },
  );

  testWidgets(
    'event creation row shows for the end-of-day display mode',
    (tester) async {
      await _pumpSettingsPage(
        tester,
        _initialState(
          calendarSyncEnabled: true,
          syncAllDayTasks: true,
          allDayEventDisplay: AllDayEventDisplay.endOfDay,
        ),
      );
      await _scrollTo(tester, find.text('Event creation'));
      expect(find.text('Event creation'), findsOneWidget);
    },
  );

  testWidgets('changing event creation to sequential persists the new value', (
    tester,
  ) async {
    final controller = await _pumpSettingsPage(
      tester,
      _initialState(
        calendarSyncEnabled: true,
        syncAllDayTasks: true,
        allDayEventDisplay: AllDayEventDisplay.midnight,
      ),
    );

    final timingDropdown = find.descendant(
      of: find.widgetWithText(ListTile, 'Event creation'),
      matching: find.byType(DropdownButton<EventTimingMode>),
    );
    await _scrollTo(tester, timingDropdown);
    await tester.tap(timingDropdown);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sequential (15 minutes apart)').hitTestable());
    await tester.pumpAndSettle();

    expect(controller.calls, [
      'setEventTimingMode(EventTimingMode.sequential)',
    ]);
  });

  // Event color / Mark done via color hide themselves entirely when
  // retrieveEventColors has no palette to offer -- true on iOS, on a local
  // (non-Google) calendar, and (the only case reachable from this test
  // suite) always true on this non-Android host, since retrieveEventColors
  // returns null before ever touching its platform channel. That means the
  // interactive selection path (tap dropdown, pick a color) can't be
  // exercised here -- same structural gap device_calendar's own test suite
  // documents for the same method. What *is* testable, and matters just as
  // much: a previously-configured selection must not make the row crash or
  // force itself visible once the palette it came from is gone.
  testWidgets(
    'event color row stays hidden even with a previously configured selection',
    (tester) async {
      await _pumpSettingsPage(
        tester,
        _initialState(
          calendarSyncEnabled: true,
          eventColor: 0xFFFF0000,
          eventColorKey: 7,
        ),
      );

      expect(find.text('Event color'), findsNothing);
    },
  );

  testWidgets(
    'done color row stays hidden even with a previously configured selection',
    (tester) async {
      await _pumpSettingsPage(
        tester,
        _initialState(calendarSyncEnabled: true, doneColorKey: 7),
      );

      expect(find.text('Mark done via color'), findsNothing);
    },
  );
}
