import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'favorites.dart';

const control = MethodChannel('quickconnect/control');
const events = EventChannel('quickconnect/state');
const appName = 'Bedrock QuickConnect';
const releaseRepository = String.fromEnvironment(
  'QUICKCONNECT_RELEASE_REPOSITORY',
);

void main() => runApp(const QuickConnect());

class QuickConnect extends StatefulWidget {
  const QuickConnect({super.key});
  @override
  State<QuickConnect> createState() => _QuickConnectState();
}

class _QuickConnectState extends State<QuickConnect> {
  final messenger = GlobalKey<ScaffoldMessengerState>();
  final navigator = GlobalKey<NavigatorState>();
  late final StreamSubscription<Object?> subscription;
  late final AppLifecycleListener lifecycle;
  Favorites? favorites;
  String? selected;
  String? loadError;
  Map<Object?, Object?> status = {};
  Future<void> pendingSave = Future.value();
  bool sending = false;
  bool checkingUpdate = false;
  DateTime? lastUpdateCheck;
  int tab = 0;

  bool get active => status['active'] == true;
  Server? get target =>
      favorites?.servers.where((s) => s.id == selected).firstOrNull;

  @override
  void initState() {
    super.initState();
    subscription = events.receiveBroadcastStream().listen((event) {
      if (mounted && event is Map) {
        setState(() => status = Map<Object?, Object?>.of(event));
      }
    }, onError: (Object error) => message(error));
    lifecycle = AppLifecycleListener(onResume: () => unawaited(checkUpdate()));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(checkUpdate());
    });
    unawaited(load());
  }

  Future<void> checkUpdate() async {
    final now = DateTime.now();
    final lastCheck = lastUpdateCheck;
    if (releaseRepository.isEmpty ||
        checkingUpdate ||
        (lastCheck != null &&
            now.difference(lastCheck) < const Duration(minutes: 1))) {
      return;
    }
    checkingUpdate = true;
    lastUpdateCheck = now;
    try {
      final version = await control.invokeMethod<String>('checkUpdate', {
        'repository': releaseRepository,
      });
      final dialogContext = navigator.currentContext;
      if (!mounted || dialogContext == null || version == null) return;
      if (WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed) {
        lastUpdateCheck = null;
        return;
      }
      final install = await showDialog<bool>(
        context: dialogContext,
        builder: (context) => AlertDialog(
          title: const Text('Neues Update verfügbar'),
          content: Text(
            'Version $version ist verfügbar. Android fragt vor der Installation nach.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Später'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Jetzt aktualisieren'),
            ),
          ],
        ),
      );
      if (mounted && install == true) await installUpdate();
    } on PlatformException {
      // An unavailable release or a network failure should not block the app.
    } finally {
      checkingUpdate = false;
    }
  }

  Future<void> installUpdate() async {
    final progress = showDialog<void>(
      context: navigator.currentContext!,
      barrierDismissible: false,
      builder: (context) => const PopScope(
        canPop: false,
        child: AlertDialog(
          content: Row(
            children: [
              SizedBox.square(
                dimension: 24,
                child: CircularProgressIndicator(),
              ),
              SizedBox(width: 16),
              Expanded(child: Text('Update wird vorbereitet …')),
            ],
          ),
        ),
      ),
    );
    Object? failure;
    try {
      await control.invokeMethod<void>('installUpdate');
    } on PlatformException catch (error) {
      failure = error;
    } finally {
      if (mounted) {
        navigator.currentState?.pop();
        if (failure != null) message(failure);
      }
    }
    await progress;
  }

  Future<void> load() async {
    try {
      final stored = await control.invokeMethod<String>('load');
      final snapshot = Favorites.decode(stored);
      final encoded = snapshot.encode();
      if (stored != null && stored != encoded) {
        await control.invokeMethod<void>('save', {'json': encoded});
      }
      if (!mounted) return;
      setState(() {
        favorites = snapshot;
        selected = snapshot.initialSelection;
        loadError = null;
      });
      unawaited(
        control
            .invokeMethod<void>('notifications')
            .catchError((Object e) => message(e)),
      );
    } catch (e) {
      if (mounted)
        setState(
          () => loadError = 'Favoriten konnten nicht geladen werden. $e',
        );
    }
  }

  void message(Object error) {
    if (!mounted) return;
    final text = error is PlatformException
        ? error.message ?? error.code
        : error.toString();
    messenger.currentState?.showSnackBar(SnackBar(content: Text(text)));
  }

  void update(VoidCallback change) {
    setState(change);
    final payload = favorites!.encode();
    pendingSave = pendingSave.then((_) async {
      try {
        await control.invokeMethod<void>('save', {'json': payload});
      } catch (e) {
        message('Favoriten konnten nicht gespeichert werden. $e');
      }
    });
  }

  @override
  void dispose() {
    lifecycle.dispose();
    unawaited(subscription.cancel());
    super.dispose();
  }

  Future<void> toggle() async {
    final server = target;
    final data = favorites!;
    final wasActive = active;
    setState(() => sending = true);
    try {
      if (wasActive) {
        await control.invokeMethod<void>('stop');
      } else if (server != null) {
        await control.invokeMethod<void>('start', {
          'host': server.host,
          'port': server.port,
          'auto': data.autoStop,
        });
      }
    } catch (e) {
      message(e);
    } finally {
      if (mounted) setState(() => sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final dark = favorites?.dark ?? true;
    final scheme = ColorScheme.fromSeed(
      seedColor: const Color(0xff81cc55),
      brightness: dark ? Brightness.dark : Brightness.light,
    );
    return MaterialApp(
      title: appName,
      debugShowCheckedModeBanner: false,
      scaffoldMessengerKey: messenger,
      navigatorKey: navigator,
      theme: ThemeData(
        colorScheme: scheme,
        scaffoldBackgroundColor: dark ? const Color(0xff111611) : null,
        useMaterial3: true,
      ),
      home: Builder(builder: home),
    );
  }

  Widget home(BuildContext context) {
    final data = favorites;
    final theme = Theme.of(context);
    final phase = status['phase'];
    final busy = sending || phase == 'STARTING' || phase == 'STOPPING';
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'QuickConnect',
          style: TextStyle(fontWeight: FontWeight.w800),
        ),
        actions: [
          IconButton(
            tooltip: 'LAN-Diagnose',
            icon: const Icon(Icons.monitor_heart_outlined),
            onPressed: () => diagnostics(context),
          ),
          IconButton(
            tooltip: 'Einstellungen',
            icon: const Icon(Icons.settings_outlined),
            onPressed: data == null ? null : () => settings(context, data),
          ),
        ],
      ),
      body: tab == 1
          ? networkLog()
          : SafeArea(
              bottom: false,
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 650),
                  child: data == null
                      ? loadError == null
                            ? const Center(child: CircularProgressIndicator())
                            : Center(
                                child: Padding(
                                  padding: const EdgeInsets.all(20),
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Text(loadError!),
                                      TextButton(
                                        onPressed: load,
                                        child: const Text('Erneut versuchen'),
                                      ),
                                    ],
                                  ),
                                ),
                              )
                      : ListView(
                          padding: const EdgeInsets.fromLTRB(18, 10, 18, 18),
                          children: [
                            Text(
                              'BEDROCK\nQUICKCONNECT',
                              style: theme.textTheme.headlineLarge?.copyWith(
                                color: theme.colorScheme.primary,
                                fontWeight: FontWeight.w900,
                                height: .98,
                                letterSpacing: 1.4,
                              ),
                            ),
                            const SizedBox(height: 10),
                            const Text(
                              'Verbinde deine Xbox mit deinen Lieblingsservern.',
                            ),
                            const SizedBox(height: 18),
                            if (phase != null &&
                                (active ||
                                    (status['detail'] as String? ?? '')
                                        .isNotEmpty))
                              statusPanel(context),
                            Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    'DEINE SERVER',
                                    style: theme.textTheme.titleSmall,
                                  ),
                                ),
                                IconButton(
                                  tooltip: 'Favoriten zuerst, dann nach Name sortieren',
                                  onPressed: () => update(data.sort),
                                  icon: const Icon(Icons.sort),
                                ),
                                IconButton.filledTonal(
                                  tooltip: 'Server hinzufügen',
                                  onPressed: () => edit(context, data),
                                  icon: const Icon(Icons.add),
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            if (data.servers.isEmpty)
                              const Text(
                                'Tippe auf +, um einen Server hinzuzufügen.',
                              ),
                            for (final server in data.servers)
                              serverCard(context, data, server),
                          ],
                        ),
                ),
              ),
            ),
      bottomNavigationBar: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (tab == 0 && data != null)
            SafeArea(
              minimum: const EdgeInsets.fromLTRB(18, 8, 18, 12),
              child: Center(
                heightFactor: 1,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 620),
                  child: SizedBox(
                    width: double.infinity,
                    height: 58,
                    child: FilledButton.icon(
                      style: FilledButton.styleFrom(
                        shape: const RoundedRectangleBorder(
                          borderRadius: BorderRadius.all(Radius.circular(9)),
                        ),
                      ),
                      onPressed: busy || (!active && target == null)
                          ? null
                          : toggle,
                      icon: Icon(active ? Icons.stop : Icons.play_arrow),
                      label: Text(
                        active ? 'VERBINDUNG STOPPEN' : 'VERBINDUNG STARTEN',
                        style: const TextStyle(
                          fontWeight: FontWeight.w800,
                          letterSpacing: .8,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          NavigationBar(
            selectedIndex: tab,
            onDestinationSelected: (value) => setState(() => tab = value),
            destinations: const [
              NavigationDestination(
                icon: Icon(Icons.dns_outlined),
                label: 'Server',
              ),
              NavigationDestination(
                icon: Icon(Icons.receipt_long_outlined),
                label: 'Netzwerk-Log',
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget networkLog() {
    final entries =
        (status['log'] as List?)?.whereType<String>().toList() ?? [];
    return SafeArea(
      bottom: false,
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 650),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 12, 18, 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Verbindungsereignisse mit Zeit seit Sitzungsstart. Server- und IP-Adressen fehlen im kopierten Log.',
                    ),
                    const SizedBox(height: 8),
                    OutlinedButton.icon(
                      onPressed: entries.isEmpty
                          ? null
                          : () async {
                              await Clipboard.setData(
                                ClipboardData(text: entries.join('\n')),
                              );
                              message('Netzwerk-Log kopiert.');
                            },
                      icon: const Icon(Icons.copy_outlined),
                      label: const Text('Logs kopieren'),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: entries.isEmpty
                    ? const Center(
                        child: Text('Noch keine Verbindungsereignisse.'),
                      )
                    : ListView.separated(
                        reverse: true,
                        padding: const EdgeInsets.fromLTRB(18, 0, 18, 12),
                        itemCount: entries.length,
                        separatorBuilder: (_, _) => const Divider(),
                        itemBuilder: (_, index) =>
                            SelectableText(entries[entries.length - index - 1]),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget statusPanel(BuildContext context) {
    final labels = {
      'STARTING': 'LAN-Dienst startet',
      'WAITING': 'Warte auf Bedrock-Verbindung',
      'CONNECTED': 'Bedrock-Client verbunden',
      'TRANSFER': 'Server-Transfer angefordert',
      'RELEASED': 'Lokale Sitzung beendet',
      'STOPPING': 'LAN-Dienst stoppt',
      'ERROR': 'Verbindung fehlgeschlagen',
      'IDLE': 'LAN-Dienst inaktiv',
    };
    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              labels[status['phase']] ?? 'LAN-Dienst',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            if (status['target'] case final String target
                when target.isNotEmpty)
              Text(target),
            if (status['ip'] case final String ip when ip.isNotEmpty)
              Text('WLAN · $ip'),
            if (status['detail'] case final String detail
                when detail.isNotEmpty)
              Text(detail),
            if (active)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text(
                  'Xbox: Minecraft → Spielen → Freunde oder Welten → LAN-Spiele → Bedrock QuickConnect',
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget serverCard(BuildContext context, Favorites data, Server server) {
    final isSelected = selected == server.id;
    final colors = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.only(bottom: 9),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(9),
        side: BorderSide(
          color: isSelected ? colors.primary : colors.outlineVariant,
          width: isSelected ? 2 : 1,
        ),
      ),
      child: ListTile(
        selected: isSelected,
        onTap: () => update(() {
          selected = server.id;
          data.last = server.id;
        }),
        leading: SizedBox(
          width: 38,
          child: Center(
            child: server.icon.isEmpty
                ? Icon(
                    isSelected ? Icons.check_box : Icons.view_in_ar,
                    color: colors.primary,
                  )
                : Text(server.icon, maxLines: 1, overflow: TextOverflow.clip),
          ),
        ),
        title: Text(
          server.name,
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
        subtitle: Text(
          [
            server.address,
            if (data.primary == server.id) 'Standardserver',
            if (server.description.isNotEmpty) server.description,
          ].join('\n'),
        ),
        trailing: PopupMenuButton<String>(
          tooltip: 'Server verwalten',
          onSelected: (action) async {
            if (action == 'edit') await edit(context, data, server);
            if (action == 'default') update(() => data.primary = server.id);
            if (action == 'delete' && context.mounted) {
              final confirmed = await showDialog<bool>(
                context: context,
                builder: (dialog) => AlertDialog(
                  title: const Text('Server löschen?'),
                  content: Text(server.name),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(dialog, false),
                      child: const Text('Abbrechen'),
                    ),
                    FilledButton(
                      onPressed: () => Navigator.pop(dialog, true),
                      child: const Text('Löschen'),
                    ),
                  ],
                ),
              );
              if (confirmed == true && mounted)
                update(() {
                  data.remove(server.id);
                  if (selected == server.id) selected = data.initialSelection;
                });
            }
          },
          itemBuilder: (_) => const [
            PopupMenuItem(value: 'edit', child: Text('Bearbeiten')),
            PopupMenuItem(
              value: 'default',
              child: Text('Als Standard festlegen'),
            ),
            PopupMenuItem(value: 'delete', child: Text('Löschen')),
          ],
        ),
      ),
    );
  }

  Future<void> edit(
    BuildContext context,
    Favorites data, [
    Server? previous,
  ]) async {
    final result = await showDialog<Server>(
      context: context,
      builder: (_) => ServerEditor(previous),
    );
    if (result != null && mounted)
      update(() {
        data.put(result);
        selected = result.id;
        data.last = result.id;
      });
  }

  void settings(BuildContext context, Favorites data) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      useSafeArea: true,
      builder: (sheet) => StatefulBuilder(
        builder: (sheet, refresh) {
          void change(VoidCallback action) {
            update(action);
            refresh(() {});
          }

          return SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SwitchListTile(
                  title: const Text('Dark Mode'),
                  value: data.dark,
                  onChanged: (value) => change(() => data.dark = value),
                ),
                SwitchListTile(
                  title: const Text('Letzten Server beim Start auswählen'),
                  value: data.remember,
                  onChanged: (value) => change(() => data.remember = value),
                ),
                SwitchListTile(
                  title: const Text('Nach lokaler Übergabe stoppen'),
                  subtitle: const Text(
                    'Beendet den LAN-Dienst nach der lokalen Übergabe.',
                  ),
                  value: data.autoStop,
                  onChanged: (value) => change(() => data.autoStop = value),
                ),
                ListTile(
                  title: const Text('LAN-Netzwerkdiagnose'),
                  onTap: () => diagnostics(sheet),
                ),
                ListTile(
                  title: const Text('Open-Source-Lizenzen'),
                  onTap: () async {
                    final text = await rootBundle.loadString('THIRD-PARTY.md');
                    if (!sheet.mounted) return;
                    await showDialog<void>(
                      context: sheet,
                      builder: (dialog) => AlertDialog(
                        title: const Text('Open-Source-Lizenzen'),
                        content: SingleChildScrollView(child: Text(text)),
                        actions: [
                          TextButton(
                            onPressed: () => showLicensePage(
                              context: dialog,
                              applicationName: appName,
                              applicationVersion: '0.1.3',
                            ),
                            child: const Text('Flutter-Lizenzen'),
                          ),
                        ],
                      ),
                    );
                  },
                ),
                const ListTile(
                  title: Text('Version 0.1.3'),
                  subtitle: Text('NetherNet · Bedrock-Protokoll 2225'),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Future<void> diagnostics(BuildContext context) async {
    String network;
    try {
      network =
          await control.invokeMethod<String>('wifi') ?? 'Kein WLAN mit IPv4';
    } catch (_) {
      network = 'WLAN-Status konnte nicht gelesen werden';
    }
    if (!context.mounted) return;
    await showDialog<void>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: const Text('LAN-Diagnose'),
        content: SingleChildScrollView(
          child: Text(
            [
              'WLAN: $network',
              'Discovery: UDP 7551',
              'WebRTC: IPv4/UDP im WLAN',
              if (status['detail'] case final String text when text.isNotEmpty)
                text,
              'Handy und Xbox müssen im selben lokalen Netz sein. Ein Gastnetz oder die Client-Isolation kann Discovery und WebRTC blockieren.',
            ].join('\n\n'),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog),
            child: const Text('Schließen'),
          ),
        ],
      ),
    );
  }
}

class ServerEditor extends StatefulWidget {
  const ServerEditor(this.previous, {super.key});
  final Server? previous;
  @override
  State<ServerEditor> createState() => _ServerEditorState();
}

class _ServerEditorState extends State<ServerEditor> {
  late final name = TextEditingController(text: widget.previous?.name);
  late final host = TextEditingController(text: widget.previous?.host);
  late final port = TextEditingController(
    text: widget.previous?.port.toString() ?? '19132',
  );
  late final icon = TextEditingController(text: widget.previous?.icon);
  late final description = TextEditingController(
    text: widget.previous?.description,
  );
  late bool favorite = widget.previous?.favorite ?? true;
  String? error;

  @override
  void dispose() {
    for (final controller in [name, host, port, icon, description]) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(
      widget.previous == null ? 'Server hinzufügen' : 'Server bearbeiten',
    ),
    content: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: name,
            decoration: const InputDecoration(labelText: 'Name'),
            autofocus: true,
          ),
          TextField(
            controller: host,
            decoration: const InputDecoration(labelText: 'Domain oder IPv4'),
            keyboardType: TextInputType.url,
          ),
          TextField(
            controller: port,
            decoration: const InputDecoration(labelText: 'Port'),
            keyboardType: TextInputType.number,
          ),
          TextField(
            controller: icon,
            decoration: const InputDecoration(labelText: 'Symbol (optional)'),
          ),
          TextField(
            controller: description,
            decoration: const InputDecoration(
              labelText: 'Beschreibung (optional)',
            ),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Favorit'),
            value: favorite,
            onChanged: (value) => setState(() => favorite = value),
          ),
          if (error != null)
            Text(
              error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Abbrechen'),
      ),
      FilledButton(
        onPressed: () {
          try {
            final server = Server.validated(
              widget.previous?.id ??
                  DateTime.now().microsecondsSinceEpoch.toString(),
              name.text,
              host.text,
              port.text,
              icon.text,
              description.text,
              favorite,
            );
            Navigator.pop(context, server);
          } on FormatException catch (e) {
            setState(() => error = e.message);
          }
        },
        child: const Text('Speichern'),
      ),
    ],
  );
}
