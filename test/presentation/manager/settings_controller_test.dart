import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vikunja_app/core/di/network_provider.dart';
import 'package:vikunja_app/core/di/repository_provider.dart';
import 'package:vikunja_app/core/network/response.dart';
import 'package:vikunja_app/core/theming/theme_mode.dart';
import 'package:vikunja_app/domain/entities/all_day_event_display.dart';
import 'package:vikunja_app/domain/entities/project.dart';
import 'package:vikunja_app/domain/entities/user.dart';
import 'package:vikunja_app/domain/entities/version.dart';
import 'package:vikunja_app/domain/repositories/project_repository.dart';
import 'package:vikunja_app/domain/repositories/settings_repository.dart';
import 'package:vikunja_app/domain/repositories/version_repository.dart';
import 'package:vikunja_app/presentation/manager/settings_controller.dart';

class _FakeSettingsRepository implements SettingsRepository {
  bool calendarSyncEnabled;
  String? syncCalendarId;
  bool syncAllDayTasks;
  AllDayEventDisplay allDayEventDisplay;
  int? eventColor;
  int? doneColorKey;

  _FakeSettingsRepository({
    this.calendarSyncEnabled = false,
    this.syncCalendarId,
    this.syncAllDayTasks = false,
    this.allDayEventDisplay = AllDayEventDisplay.midnight,
    this.eventColor,
    this.doneColorKey,
  });

  // getAll() reads every settings field regardless of what a given test
  // cares about, so the non-calendar fields need real (if boring) values
  // rather than noSuchMethod.
  @override
  Future<bool> getIgnoreCertificates() async => false;

  @override
  Future<void> setIgnoreCertificates(bool value) async {}

  @override
  Future<bool> getSentryEnabled() async => false;

  @override
  Future<void> setSentryEnabled(bool value) async {}

  @override
  Future<bool> getVersionNotifications() async => false;

  @override
  Future<void> setVersionNotifications(bool value) async {}

  @override
  Future<int> getRefreshInterval() async => 0;

  @override
  Future<void> setRefreshInterval(int minutes) async {}

  @override
  Future<FlutterThemeMode> getThemeMode() async => FlutterThemeMode.system;

  @override
  Future<void> setThemeMode(FlutterThemeMode newMode) async {}

  @override
  Future<void> setDynamicColors(bool dynamicColors) async {}

  @override
  Future<bool> getDynamicColors() async => false;

  @override
  Future<bool> getLandingPageOnlyDueDateTasks() async => false;

  @override
  Future<void> setLandingPageOnlyDueDateTasks(bool value) async {}

  @override
  Future<bool> getDisplayDoneTasks(int projectId) async => false;

  @override
  Future<void> setDisplayDoneTasks(int projectId, bool value) async {}

  @override
  Future<List<String>> getPastServers() async => [];

  @override
  Future<void> setPastServers(List<String> server) async {}

  @override
  Future<bool> getSentryDialogShown() async => false;

  @override
  Future<void> setSentryDialogShown(bool value) async {}

  @override
  Future<void> saveUserToken(String? token) async {}

  @override
  Future<String?> getUserToken() async => null;

  @override
  Future<void> saveRefreshToken(String? token) async {}

  @override
  Future<String?> getRefreshToken() async => null;

  @override
  Future<void> saveServer(String? server) async {}

  @override
  Future<String?> getServer() async => null;

  @override
  Future<String?> getLocaleOverride() async => null;

  @override
  Future<void> setLocaleOverride(String? localeCode) async {}

  @override
  Future<bool> getCalendarSyncEnabled() async => calendarSyncEnabled;

  @override
  Future<void> setCalendarSyncEnabled(bool value) async {
    calendarSyncEnabled = value;
  }

  @override
  Future<String?> getSyncCalendarId() async => syncCalendarId;

  @override
  Future<void> setSyncCalendarId(String? calendarId) async {
    syncCalendarId = calendarId;
  }

  @override
  Future<bool> getSyncAllDayTasks() async => syncAllDayTasks;

  @override
  Future<void> setSyncAllDayTasks(bool value) async {
    syncAllDayTasks = value;
  }

  @override
  Future<AllDayEventDisplay> getAllDayEventDisplay() async =>
      allDayEventDisplay;

  @override
  Future<void> setAllDayEventDisplay(AllDayEventDisplay value) async {
    allDayEventDisplay = value;
  }

  @override
  Future<int?> getEventColor() async => eventColor;

  @override
  Future<void> setEventColor(int? color) async {
    eventColor = color;
  }

  @override
  Future<int?> getDoneColorKey() async => doneColorKey;

  @override
  Future<void> setDoneColorKey(int? colorKey) async {
    doneColorKey = colorKey;
  }
}

void main() {
  late _FakeSettingsRepository fakeSettingsRepository;
  late ProjectRepository fakeProjectRepository;
  late VersionRepository fakeVersionRepository;

  setUp(() {
    fakeSettingsRepository = _FakeSettingsRepository();
    fakeProjectRepository = _StubProjectRepository();
    fakeVersionRepository = _StubVersionRepository();
  });

  ProviderContainer createContainer() {
    final container = ProviderContainer(
      overrides: [
        settingsRepositoryProvider.overrideWithValue(fakeSettingsRepository),
        projectRepositoryProvider.overrideWithValue(fakeProjectRepository),
        versionRepositoryProvider.overrideWithValue(fakeVersionRepository),
      ],
    );
    addTearDown(container.dispose);
    container.read(currentUserProvider.notifier).set(User(username: 'tester'));
    return container;
  }

  test('setCalendarSyncEnabled persists and refreshes state', () async {
    final container = createContainer();
    final controller = container.read(settingsControllerProvider.notifier);
    await container.read(settingsControllerProvider.future);

    await controller.setCalendarSyncEnabled(true);

    expect(fakeSettingsRepository.calendarSyncEnabled, isTrue);
    expect(
      container.read(settingsControllerProvider).value?.calendarSyncEnabled,
      isTrue,
    );
  });

  test('setSyncCalendarId persists and refreshes state', () async {
    final container = createContainer();
    final controller = container.read(settingsControllerProvider.notifier);
    await container.read(settingsControllerProvider.future);

    await controller.setSyncCalendarId('cal-42');

    expect(fakeSettingsRepository.syncCalendarId, 'cal-42');
    expect(
      container.read(settingsControllerProvider).value?.syncCalendarId,
      'cal-42',
    );
  });

  test('setSyncAllDayTasks persists and refreshes state', () async {
    final container = createContainer();
    final controller = container.read(settingsControllerProvider.notifier);
    await container.read(settingsControllerProvider.future);

    await controller.setSyncAllDayTasks(true);

    expect(fakeSettingsRepository.syncAllDayTasks, isTrue);
    expect(
      container.read(settingsControllerProvider).value?.syncAllDayTasks,
      isTrue,
    );
  });

  test('setAllDayEventDisplay persists and refreshes state', () async {
    final container = createContainer();
    final controller = container.read(settingsControllerProvider.notifier);
    await container.read(settingsControllerProvider.future);

    await controller.setAllDayEventDisplay(AllDayEventDisplay.allDayEvent);

    expect(
      fakeSettingsRepository.allDayEventDisplay,
      AllDayEventDisplay.allDayEvent,
    );
    expect(
      container.read(settingsControllerProvider).value?.allDayEventDisplay,
      AllDayEventDisplay.allDayEvent,
    );
  });

  test('setEventColor persists and refreshes state', () async {
    final container = createContainer();
    final controller = container.read(settingsControllerProvider.notifier);
    await container.read(settingsControllerProvider.future);

    await controller.setEventColor(0xFF00FF00);

    expect(fakeSettingsRepository.eventColor, 0xFF00FF00);
    expect(
      container.read(settingsControllerProvider).value?.eventColor,
      0xFF00FF00,
    );
  });

  test('setDoneColorKey persists and refreshes state', () async {
    final container = createContainer();
    final controller = container.read(settingsControllerProvider.notifier);
    await container.read(settingsControllerProvider.future);

    await controller.setDoneColorKey(5);

    expect(fakeSettingsRepository.doneColorKey, 5);
    expect(
      container.read(settingsControllerProvider).value?.doneColorKey,
      5,
    );
  });

  test('getAll surfaces the persisted calendar sync settings', () async {
    fakeSettingsRepository = _FakeSettingsRepository(
      calendarSyncEnabled: true,
      syncCalendarId: 'cal-1',
      syncAllDayTasks: true,
      allDayEventDisplay: AllDayEventDisplay.endOfDay,
      eventColor: 0xFFFF0000,
      doneColorKey: 3,
    );
    final container = createContainer();

    final state = await container.read(settingsControllerProvider.future);

    expect(state.calendarSyncEnabled, isTrue);
    expect(state.syncCalendarId, 'cal-1');
    expect(state.syncAllDayTasks, isTrue);
    expect(state.allDayEventDisplay, AllDayEventDisplay.endOfDay);
    expect(state.eventColor, 0xFFFF0000);
    expect(state.doneColorKey, 3);
  });
}

class _StubProjectRepository implements ProjectRepository {
  @override
  Future<Response<List<Project>>> getAll({int page = 1}) async =>
      SuccessResponse(<Project>[], 200, {});

  @override
  Future<Response<Project>> create(Project p) => throw UnimplementedError();

  @override
  Future<Response<Project>> update(Project p) => throw UnimplementedError();
}

class _StubVersionRepository implements VersionRepository {
  @override
  Future<Version?> getCurrentVersionTag() async => null;

  @override
  Future<Version?> getLatestVersionTag() async => null;
}
