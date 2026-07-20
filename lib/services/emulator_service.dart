import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../models/emulator_profile.dart';
import '../models/max_account.dart';

class EmulatorSdkInfo {
  EmulatorSdkInfo({
    required this.available,
    this.sdkRoot,
    this.emulatorPath,
    this.adbPath,
    this.avdManagerPath,
    this.systemImage,
    this.error,
  });

  final bool available;
  final String? sdkRoot;
  final String? emulatorPath;
  final String? adbPath;
  final String? avdManagerPath;
  final String? systemImage;
  final String? error;
}

class EmulatorOperationResult {
  EmulatorOperationResult({
    required this.ok,
    required this.message,
    this.avdName,
  });

  final bool ok;
  final String message;
  final String? avdName;
}

typedef EmulatorProgressCallback = void Function(String message);

class EmulatorService {
  EmulatorService._();

  static final EmulatorService instance = EmulatorService._();

  static const maxPackage = 'ru.oneme.app';
  static const maxActivity = 'ru.oneme.app/one.me.android.MainActivity';
  static const _defaultTimeout = Duration(seconds: 90);
  static const _sdkListTimeout = Duration(seconds: 45);

  EmulatorSdkInfo? _cachedSdk;
  final Map<String, Process> _running = {};

  Future<ProcessResult> _runProcess(
    String executable,
    List<String> arguments, {
    Map<String, String>? environment,
    bool runInShell = false,
    Duration timeout = _defaultTimeout,
  }) async {
    try {
      return await Process.run(
        executable,
        arguments,
        environment: environment,
        runInShell: runInShell,
      ).timeout(timeout);
    } on TimeoutException {
      return ProcessResult(-1, -1, '', 'Таймаут ${timeout.inSeconds} с — процесс завис');
    }
  }

  Future<EmulatorSdkInfo> detectSdk({bool forceRefresh = false}) async {
    if (_cachedSdk != null && !forceRefresh) return _cachedSdk!;

    final roots = <String>[
      Platform.environment['ANDROID_HOME'] ?? '',
      Platform.environment['ANDROID_SDK_ROOT'] ?? '',
      '${Platform.environment['LOCALAPPDATA']}${Platform.pathSeparator}Android${Platform.pathSeparator}Sdk',
      '${Platform.environment['USERPROFILE']}${Platform.pathSeparator}AppData${Platform.pathSeparator}Local${Platform.pathSeparator}Android${Platform.pathSeparator}Sdk',
    ].where((p) => p.isNotEmpty).toSet();

    for (final root in roots) {
      final emulator = _bin(root, 'emulator', 'emulator.exe');
      final adb = _bin(root, 'platform-tools', 'adb.exe');
      final avdManager = _bin(root, 'cmdline-tools', 'latest', 'bin', 'avdmanager.bat');
      final avdManagerAlt = _bin(root, 'tools', 'bin', 'avdmanager.bat');

      if (!File(emulator).existsSync() || !File(adb).existsSync()) continue;

      final avd = File(avdManager).existsSync() ? avdManager : avdManagerAlt;
      if (!File(avd).existsSync()) continue;

      final image = await _findSystemImage(root);
      if (image == null) {
        _cachedSdk = EmulatorSdkInfo(
          available: false,
          sdkRoot: root,
          emulatorPath: emulator,
          adbPath: adb,
          avdManagerPath: avd,
          error: 'Нет system-image x86_64. Установите через Android Studio SDK Manager.',
        );
        return _cachedSdk!;
      }

      _cachedSdk = EmulatorSdkInfo(
        available: true,
        sdkRoot: root,
        emulatorPath: emulator,
        adbPath: adb,
        avdManagerPath: avd,
        systemImage: image,
      );
      return _cachedSdk!;
    }

    _cachedSdk = EmulatorSdkInfo(
      available: false,
      error: 'Android SDK не найден. Установите Android Studio и SDK.',
    );
    return _cachedSdk!;
  }

  String defaultAvdName(MaxAccount account) {
    final short = account.id.length > 8 ? account.id.substring(account.id.length - 8) : account.id;
    return 'max_desktop_$short';
  }

  Future<bool> avdExists(String avdName) async {
    final sdk = await detectSdk();
    if (!sdk.available || sdk.emulatorPath == null) return false;
    final result = await _runProcess(
      sdk.emulatorPath!,
      ['-list-avds'],
      timeout: const Duration(seconds: 30),
    );
    if (result.exitCode != 0) return false;
    final lines = (result.stdout as String).split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty);
    return lines.contains(avdName);
  }

  Future<EmulatorOperationResult> createAvd(MaxAccount account) async {
    final sdk = await detectSdk();
    if (!sdk.available) {
      return EmulatorOperationResult(ok: false, message: sdk.error ?? 'SDK недоступен');
    }

    final avdName = account.emulator.avdName ?? defaultAvdName(account);
    if (await avdExists(avdName)) {
      return EmulatorOperationResult(
        ok: true,
        avdName: avdName,
        message: 'Эмулятор «$avdName» уже существует',
      );
    }

    final image = sdk.systemImage!;
    final avdManager = sdk.avdManagerPath!;

    final result = await _runProcess(
      avdManager,
      [
        'create',
        'avd',
        '-n',
        avdName,
        '-k',
        image,
        '-d',
        'pixel_6',
        '--force',
      ],
      environment: _sdkEnv(sdk.sdkRoot!),
      runInShell: true,
      timeout: const Duration(minutes: 3),
    );

    final out = '${result.stdout}\n${result.stderr}';
    if (result.exitCode == -1) {
      return EmulatorOperationResult(ok: false, message: out.trim());
    }
    if (result.exitCode != 0 && !out.toLowerCase().contains('created')) {
      return EmulatorOperationResult(
        ok: false,
        message: 'Не удалось создать AVD: ${out.trim().isEmpty ? result.exitCode : out.trim()}',
      );
    }

    await _writeAvdConfig(avdName, account.emulator);
    return EmulatorOperationResult(
      ok: true,
      avdName: avdName,
      message: 'Создан изолированный эмулятор «$avdName»',
    );
  }

  Future<EmulatorOperationResult> launch(MaxAccount account) async {
    final sdk = await detectSdk();
    if (!sdk.available) {
      return EmulatorOperationResult(ok: false, message: sdk.error ?? 'SDK недоступен');
    }

    final avdName = account.emulator.avdName ?? defaultAvdName(account);
    if (!await avdExists(avdName)) {
      final created = await createAvd(account.copyWith(emulator: account.emulator.copyWith(avdName: avdName)));
      if (!created.ok) return created;
    }

    await _runProcess(sdk.adbPath!, ['start-server'], timeout: const Duration(seconds: 30));
    final already = await _findBootedEmulator(sdk.adbPath!, avdName);
    if (already != null) {
      return EmulatorOperationResult(
        ok: true,
        avdName: avdName,
        message: 'Эмулятор «$avdName» уже запущен ($already)',
      );
    }

    if (_running.containsKey(account.id)) {
      return EmulatorOperationResult(
        ok: true,
        avdName: avdName,
        message: 'Эмулятор запускается… Подождите загрузки Android (1–3 мин)',
      );
    }

    final args = [
      '-avd',
      avdName,
      '-no-boot-anim',
      '-no-snapshot-load',
      '-gpu',
      Platform.isWindows ? 'host' : 'auto',
      '-memory',
      '2048',
    ];

    final locale = account.emulator.deviceLocale.replaceAll('-', '_');
    args.addAll(['-prop', 'persist.sys.language=${locale.split('_').first}']);
    args.addAll(['-prop', 'persist.sys.country=${locale.contains('_') ? locale.split('_').last : 'RU'}']);

    final process = await Process.start(
      sdk.emulatorPath!,
      args,
      environment: _sdkEnv(sdk.sdkRoot!),
      mode: ProcessStartMode.detached,
    );

    _running[account.id] = process;
    unawaited(process.exitCode.then((_) => _running.remove(account.id)));

    return EmulatorOperationResult(
      ok: true,
      avdName: avdName,
      message: 'Эмулятор запускается… Дождитесь окна Android (1–3 мин), затем «Открыть MAX»',
    );
  }

  Future<EmulatorOperationResult> openMaxApp(
    MaxAccount account, {
    bool autoLaunch = true,
    String? knownSerial,
    EmulatorProgressCallback? onProgress,
  }) async {
    void progress(String msg) => onProgress?.call(msg);

    final sdk = await detectSdk();
    if (!sdk.available || sdk.adbPath == null) {
      return EmulatorOperationResult(ok: false, message: sdk.error ?? 'ADB недоступен');
    }

    final adb = sdk.adbPath!;
    final avdName = account.emulator.avdName ?? defaultAvdName(account);

    progress('Проверка ADB…');
    await _runProcess(adb, ['start-server'], timeout: const Duration(seconds: 30));

    var serial = knownSerial;
    if (serial == null) {
      serial = await _waitForEmulator(
        adb,
        avdName,
        timeout: const Duration(seconds: 15),
        onProgress: onProgress,
      );
    }
    if (serial == null) {
      try {
        serial = await resolveSerial(
          account,
          onProgress: onProgress,
          timeout: const Duration(seconds: 10),
        );
      } catch (_) {
        serial = null;
      }
    }
    if (serial == null && autoLaunch) {
      progress('Запуск эмулятора $avdName…');
      final launched = await this.launch(account);
      if (!launched.ok) return launched;
      progress('Чёрный экран 2–5 мин — норма. Ждём загрузку Android…');
      serial = await _waitForEmulator(
        adb,
        avdName,
        timeout: const Duration(minutes: 8),
        onProgress: onProgress,
      );
    }

    if (serial == null) {
      final diag = await _adbDiagnostics(adb, avdName);
      return EmulatorOperationResult(
        ok: false,
        message: autoLaunch
            ? 'Android не загрузился за 8 мин.\n$diag\n\n'
                'Если экран чёрный: включите Virtualization в BIOS и '
                'Windows Hypervisor Platform (Параметры → Компоненты Windows).'
            : 'Эмулятор не найден.\n$diag\n\nНажмите «Запустить эмулятор» и повторите.',
      );
    }

    progress('Android готов ($serial). Проверка MAX…');
    await _adb(adb, serial, ['shell', 'settings', 'put', 'global', 'auto_time_zone', '0']);
    await _adb(adb, serial, ['shell', 'setprop', 'persist.sys.timezone', 'Europe/Moscow']);

    final installed = await _adb(adb, serial, ['shell', 'pm', 'path', maxPackage]);
    if ((installed.stdout as String).trim().isEmpty) {
      return EmulatorOperationResult(
        ok: false,
        message: 'MAX ($maxPackage) не установлен. Установите APK или откройте Play Store в эмуляторе.',
      );
    }

    final launchResult = await _adb(adb, serial, [
      'shell',
      'am',
      'start',
      '-n',
      maxActivity,
    ]);

    if (launchResult.exitCode != 0) {
      final monkey = await _adb(adb, serial, [
        'shell',
        'monkey',
        '-p',
        maxPackage,
        '-c',
        'android.intent.category.LAUNCHER',
        '1',
      ]);
      if (monkey.exitCode != 0) {
        return EmulatorOperationResult(ok: false, message: 'Не удалось открыть MAX: ${launchResult.stderr}');
      }
    }

    return EmulatorOperationResult(
      ok: true,
      avdName: avdName,
      message: 'MAX открыт в эмуляторе. Зарегистрируйте номер → затем QR в web.max.ru',
    );
  }

  Future<EmulatorOperationResult> installApk(
    MaxAccount account,
    String apkPath, {
    String? knownSerial,
    EmulatorProgressCallback? onProgress,
  }) async {
    final sdk = await detectSdk();
    if (!sdk.available || sdk.adbPath == null) {
      return EmulatorOperationResult(ok: false, message: sdk.error ?? 'ADB недоступен');
    }
    if (!File(apkPath).existsSync()) {
      return EmulatorOperationResult(ok: false, message: 'APK не найден: $apkPath');
    }

    final adb = sdk.adbPath!;
    final serial = knownSerial ??
        await resolveSerial(
          account,
          onProgress: onProgress,
          timeout: const Duration(seconds: 20),
        );

    if (await isPackageInstalled(adb, serial, maxPackage)) {
      return EmulatorOperationResult(ok: true, message: 'MAX уже установлен');
    }

    onProgress?.call('Установка MAX в эмулятор (~2–5 мин)…');
    final result = await _runProcess(
      adb,
      ['-s', serial, 'install', '-r', apkPath],
      timeout: const Duration(minutes: 12),
    );
    final out = '${result.stdout}\n${result.stderr}'.trim();
    if (result.exitCode != 0) {
      return EmulatorOperationResult(
        ok: false,
        message: out.isEmpty ? 'Ошибка установки (код ${result.exitCode})' : 'Ошибка установки: $out',
      );
    }
    return EmulatorOperationResult(ok: true, message: 'MAX APK установлен');
  }

  Future<bool> isPackageInstalled(String adb, String serial, String package) async {
    final result = await _adb(adb, serial, ['shell', 'pm', 'path', package]);
    return (result.stdout as String).trim().isNotEmpty;
  }

  Future<void> _writeAvdConfig(String avdName, EmulatorProfile profile) async {
    final home = Platform.environment['USERPROFILE'] ?? Platform.environment['HOME'] ?? '';
    final ini = File(
      '$home${Platform.pathSeparator}.android${Platform.pathSeparator}avd${Platform.pathSeparator}$avdName.ini',
    );
    if (!ini.existsSync()) return;

    final content = await ini.readAsString();
    final configMatch = RegExp(r'path=(.+)').firstMatch(content);
    if (configMatch == null) return;
    final configDir = configMatch.group(1)!.trim();
    final configFile = File('$configDir${Platform.pathSeparator}config.ini');
    if (!configFile.existsSync()) return;

    var config = await configFile.readAsString();
    if (!config.contains('hw.keyboard=yes')) {
      config += '\nhw.keyboard=yes\n';
    }
    if (profile.gpsLat != null && profile.gpsLon != null) {
      config += 'hw.gps=yes\n';
    }
    await configFile.writeAsString(config);
  }

  Future<String?> _waitForEmulator(
    String adb,
    String avdName, {
    required Duration timeout,
    EmulatorProgressCallback? onProgress,
  }) async {
    final deadline = DateTime.now().add(timeout);
    final started = DateTime.now();
    String? anyBooted;

    while (DateTime.now().isBefore(deadline)) {
      final elapsed = DateTime.now().difference(started).inSeconds;
      onProgress?.call(
        elapsed < 30
            ? 'Ожидание эмулятора… ${elapsed}с'
            : 'Загрузка Android… ${elapsed}с (чёрный экран — норма)',
      );

      final found = await _findBootedEmulator(adb, avdName);
      if (found != null) return found;

      final all = await _listEmulatorDevices(adb);
      if (all.isNotEmpty && elapsed < 60) {
        onProgress?.call('Эмулятор найден (${all.first}), ждём Android… ${elapsed}с');
      }

      final booted = <String>[];
      for (final serial in all) {
        if (await _isBootCompleted(adb, serial)) booted.add(serial);
      }
      if (booted.length == 1) {
        anyBooted = booted.first;
        if (avdName.isEmpty) return anyBooted;
        final name = await _getEmulatorAvdName(adb, anyBooted);
        if (name == null || _avdNamesMatch(name, avdName)) return anyBooted;
      }

      await Future<void>.delayed(const Duration(seconds: 3));
    }

    return anyBooted;
  }

  Future<String?> _findBootedEmulator(String adb, String avdName) async {
    for (final serial in await _listEmulatorDevices(adb)) {
      if (!await _isBootCompleted(adb, serial)) continue;
      final name = await _getEmulatorAvdName(adb, serial);
      if (name != null && _avdNamesMatch(name, avdName)) return serial;
    }
    return null;
  }

  Future<List<String>> _listEmulatorDevices(String adb) async {
    final devices = await _runProcess(adb, ['devices'], timeout: const Duration(seconds: 20));
    final serials = <String>[];
    for (final line in (devices.stdout as String).split('\n')) {
      if (!line.contains('emulator-')) continue;
      final parts = line.trim().split(RegExp(r'\s+'));
      if (parts.length < 2 || parts[1] != 'device') continue;
      serials.add(parts[0]);
    }
    return serials;
  }

  Future<bool> _isBootCompleted(String adb, String serial) async {
    final boot = await _adb(adb, serial, ['shell', 'getprop', 'sys.boot_completed']);
    if ((boot.stdout as String).trim() == '1') return true;

    final dev = await _adb(adb, serial, ['shell', 'getprop', 'dev.bootcomplete']);
    if ((dev.stdout as String).trim() == '1') return true;

    final anim = await _adb(adb, serial, ['shell', 'getprop', 'init.svc.bootanim']);
    if ((anim.stdout as String).trim() == 'stopped') return true;

    final pm = await _adb(adb, serial, ['shell', 'pm', 'path', 'android']);
    return (pm.stdout as String).contains('package:');
  }

  Future<String?> _getEmulatorAvdName(String adb, String serial) async {
    final emu = await _adb(adb, serial, ['emu', 'avd', 'name']);
    var name = (emu.stdout as String).trim();
    if (name.isNotEmpty && !name.toLowerCase().contains('error')) return name;

    final prop = await _adb(adb, serial, ['shell', 'getprop', 'ro.boot.qemu.avd_name']);
    name = (prop.stdout as String).trim();
    return name.isEmpty ? null : name;
  }

  bool _avdNamesMatch(String actual, String expected) {
    final a = actual.trim().toLowerCase();
    final e = expected.trim().toLowerCase();
    return a == e || a.contains(e) || e.contains(a);
  }

  Future<String> _adbDiagnostics(String adb, String avdName) async {
    final devices = await _runProcess(adb, ['devices', '-l'], timeout: const Duration(seconds: 20));
    final out = (devices.stdout as String).trim();
    if (out.isEmpty || out == 'List of devices attached') {
      return 'ADB: эмуляторы не найдены. Сначала нажмите «Запустить».';
    }
    final lines = out.split('\n').where((l) => l.contains('emulator')).toList();
    if (lines.isEmpty) {
      return 'ADB видит: $out\nОжидался AVD: $avdName';
    }
    return 'ADB: ${lines.join('; ')}';
  }

  Future<ProcessResult> _adb(String adb, String serial, List<String> args) {
    return _runProcess(adb, ['-s', serial, ...args], timeout: const Duration(seconds: 60));
  }

  Future<String?> _findSystemImage(String sdkRoot) async {
    final sdkmanager = _bin(sdkRoot, 'cmdline-tools', 'latest', 'bin', 'sdkmanager.bat');
    if (!File(sdkmanager).existsSync()) return null;

    final result = await _runProcess(
      sdkmanager,
      ['--list_installed'],
      environment: _sdkEnv(sdkRoot),
      runInShell: true,
      timeout: _sdkListTimeout,
    );
    if (result.exitCode == -1) return null;
    final text = '${result.stdout}\n${result.stderr}';
    final candidates = RegExp(r'system-images;android-(\d+);([^;\s]+);x86_64')
        .allMatches(text)
        .map((m) => 'system-images;android-${m.group(1)};${m.group(2)};x86_64')
        .toList();

    if (candidates.isEmpty) return null;

    int score(String image) {
      var s = 0;
      if (image.contains('google_apis_playstore')) s += 100;
      if (image.contains('google_apis')) s += 50;
      final ver = RegExp(r'android-(\d+)').firstMatch(image);
      if (ver != null) s += int.tryParse(ver.group(1)!) ?? 0;
      return s;
    }

    candidates.sort((a, b) => score(b).compareTo(score(a)));
    return candidates.first;
  }

  Map<String, String> _sdkEnv(String sdkRoot) => {
        ...Platform.environment,
        'ANDROID_HOME': sdkRoot,
        'ANDROID_SDK_ROOT': sdkRoot,
      };

  String _bin(String root, String part1, [String? part2, String? part3, String? part4, String? part5]) {
    return [
      root,
      part1,
      ?part2,
      ?part3,
      ?part4,
      ?part5,
    ].join(Platform.pathSeparator);
  }

  /// Returns ADB serial for account's AVD (must be booted).
  Future<String> resolveSerial(
    MaxAccount account, {
    EmulatorProgressCallback? onProgress,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final sdk = await detectSdk();
    if (!sdk.available || sdk.adbPath == null) {
      throw StateError('Android SDK не найден: ${sdk.error ?? "проверьте ANDROID_HOME"}');
    }

    final adb = sdk.adbPath!;
    final avdName = account.emulator.avdName?.trim().isNotEmpty == true
        ? account.emulator.avdName!.trim()
        : defaultAvdName(account);

    if (account.emulator.avdName?.trim().isEmpty != false) {
      onProgress?.call('AVD в профиле не задан, ищем «$avdName»…');
    }

    var serial = await _findBootedEmulator(adb, avdName);
    serial ??= await _waitForEmulator(
      adb,
      avdName,
      timeout: timeout,
      onProgress: onProgress,
    );

    if (serial == null) {
      final booted = <String>[];
      for (final candidate in await _listEmulatorDevices(adb)) {
        if (await _isBootCompleted(adb, candidate)) booted.add(candidate);
      }
      if (booted.length == 1) {
        serial = booted.first;
        onProgress?.call('Найден запущенный эмулятор $serial');
      }
    }

    if (serial == null) {
      throw StateError(
        'Эмулятор «$avdName» не запущен. Откройте панель эмулятора и нажмите «Запустить».',
      );
    }
    return serial;
  }

  Future<(int width, int height)> getDisplaySize(String adb, String serial) async {
    final result = await _adb(adb, serial, ['shell', 'wm', 'size']);
    final text = '${result.stdout}\n${result.stderr}';
    final match = RegExp(r'(\d+)x(\d+)').firstMatch(text);
    if (match != null) {
      return (int.parse(match.group(1)!), int.parse(match.group(2)!));
    }
    return (1080, 1920);
  }

  Future<Uint8List?> captureScreenshot(String adb, String serial) async {
    try {
      return await () async {
        final process = await Process.start(adb, ['-s', serial, 'exec-out', 'screencap', '-p']);
        final builder = BytesBuilder(copy: false);
        await for (final chunk in process.stdout.timeout(const Duration(seconds: 30))) {
          builder.add(chunk);
        }
        final code = await process.exitCode.timeout(const Duration(seconds: 10));
        if (code != 0) return null;
        final bytes = builder.takeBytes();
        return bytes.isEmpty ? null : bytes;
      }().timeout(const Duration(seconds: 35));
    } catch (_) {
      return null;
    }
  }

  Future<void> inputTap(String adb, String serial, int x, int y) async {
    await _adb(adb, serial, ['shell', 'input', 'tap', '$x', '$y']);
  }

  Future<void> inputSwipe(
    String adb,
    String serial,
    int x1,
    int y1,
    int x2,
    int y2, {
    int durationMs = 300,
  }) async {
    await _adb(adb, serial, [
      'shell',
      'input',
      'swipe',
      '$x1',
      '$y1',
      '$x2',
      '$y2',
      '$durationMs',
    ]);
  }

  Future<void> inputLongPress(String adb, String serial, int x, int y, {int durationMs = 800}) async {
    await inputSwipe(adb, serial, x, y, x, y, durationMs: durationMs);
  }

  Future<void> inputKeyEvent(String adb, String serial, int keyCode) async {
    await _adb(adb, serial, ['shell', 'input', 'keyevent', '$keyCode']);
  }

  Future<void> inputText(String adb, String serial, String text) async {
    if (text.isEmpty) return;

    final asciiOnly = text.runes.every((r) => r < 128);
    if (asciiOnly) {
      final escaped = text.replaceAll(' ', '%s');
      await _adb(adb, serial, ['shell', 'input', 'text', escaped]);
      return;
    }

    await _adb(adb, serial, ['shell', 'cmd', 'clipboard', 'set', 'text', text]);
    await Future<void>.delayed(const Duration(milliseconds: 250));
    await _adb(adb, serial, ['shell', 'input', 'keyevent', '279']);
  }
}
