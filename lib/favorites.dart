import 'dart:convert';

class Server {
  const Server(
    this.id,
    this.name,
    this.host,
    this.port, {
    this.icon = '',
    this.description = '',
    this.favorite = true,
  });

  final String id, name, host, icon, description;
  final int port;
  final bool favorite;
  String get address => '$host:$port';

  factory Server.validated(
    String id,
    String name,
    String address,
    String port,
    String icon,
    String description,
    bool favorite,
  ) {
    name = name.trim();
    address = address.trim().toLowerCase().replaceFirst(RegExp(r'\.$'), '');
    port = port.trim();
    if (name.isEmpty || name.length > 60) {
      throw const FormatException('Der Name muss 1–60 Zeichen enthalten.');
    }
    final labels = address.split('.');
    final valid = RegExp(r'^[0-9.]+$').hasMatch(address)
        ? labels.length == 4 &&
              labels.every(
                (part) =>
                    RegExp(r'^(0|[1-9][0-9]{0,2})$').hasMatch(part) &&
                    int.parse(part) <= 255,
              )
        : address.length <= 253 &&
              labels.length >= 2 &&
              labels.every(
                (part) =>
                    RegExp(r'^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$')
                        .hasMatch(part),
              );
    if (!valid) {
      throw const FormatException(
        'IPv4-Adresse oder Domain eingeben. Für IDN die Punycode-Schreibweise verwenden.',
      );
    }
    final number = int.tryParse(port);
    if (!RegExp(r'^[0-9]{1,5}$').hasMatch(port) ||
        number == null ||
        number < 1 ||
        number > 65535) {
      throw const FormatException('Der Port muss zwischen 1 und 65535 liegen.');
    }
    if (icon.trim().length > 8 || description.trim().length > 240) {
      throw const FormatException(
        'Symbol auf 8 und Beschreibung auf 240 Zeichen begrenzen.',
      );
    }
    return Server(
      id,
      name,
      address,
      number,
      icon: icon.trim(),
      description: description.trim(),
      favorite: favorite,
    );
  }

  factory Server.fromJson(Map<String, dynamic> json) => Server(
    json['id'] as String,
    json['name'] as String,
    json['host'] as String,
    json['port'] as int,
    icon: json['icon'] as String? ?? '',
    description: json['description'] as String? ?? '',
    favorite: json['favorite'] as bool? ?? true,
  );

  Map<String, Object> toJson() => {
    'id': id,
    'name': name,
    'host': host,
    'port': port,
    'icon': icon,
    'description': description,
    'favorite': favorite,
  };
}

class Favorites {
  Favorites({
    List<Server>? servers,
    this.last,
    this.primary,
    this.dark = true,
    this.remember = true,
    this.autoStop = true,
  }) : servers = List.of(servers ?? const <Server>[]);

  final List<Server> servers;
  String? last, primary;
  bool dark, remember, autoStop;

  String? get initialSelection =>
      [if (remember) last, primary, if (servers.isNotEmpty) servers.first.id]
          .whereType<String>()
          .where((id) => servers.any((s) => s.id == id))
          .firstOrNull;

  void put(Server server) {
    final index = servers.indexWhere((item) => item.id == server.id);
    if (index == -1) {
      servers.add(server);
    } else {
      servers[index] = server;
    }
  }

  void remove(String id) {
    servers.removeWhere((server) => server.id == id);
    if (last == id) last = null;
    if (primary == id) primary = null;
  }

  void sort() => servers.sort((a, b) {
    if (a.favorite != b.favorite) return a.favorite ? -1 : 1;
    final order = a.name.toLowerCase().compareTo(b.name.toLowerCase());
    return order == 0 ? a.id.compareTo(b.id) : order;
  });

  factory Favorites.decode(String? source) {
    if (source == null) return Favorites();
    final data = jsonDecode(source) as Map<String, dynamic>;
    final legacy = data['schema'] != 1;
    final favorites = Favorites(
      servers: (data['servers'] as List<dynamic>)
          .map((entry) => Server.fromJson(entry as Map<String, dynamic>))
          .toList(),
      last: data['last'] as String?,
      primary: data['primary'] as String?,
      dark: data['dark'] as bool? ?? true,
      remember: data['remember'] as bool? ?? true,
      autoStop: legacy ? true : data['autoStop'] as bool? ?? true,
    );
    if (legacy) {
      // Older versions used numeric timestamp IDs for user-added entries and
      // fixed text IDs for bundled entries. Remove those without bundling their data again.
      final seeded = favorites.servers
          .where((server) => !RegExp(r'^[0-9]+$').hasMatch(server.id))
          .map((server) => server.id)
          .toList();
      for (final id in seeded) {
        favorites.remove(id);
      }
    }
    return favorites;
  }

  String encode() => jsonEncode({
    'servers': servers,
    'last': last,
    'primary': primary,
    'dark': dark,
    'remember': remember,
    'autoStop': autoStop,
    'schema': 1,
  });
}
