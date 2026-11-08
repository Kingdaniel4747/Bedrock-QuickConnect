import 'dart:convert';

import 'package:bedrock_quickconnect/favorites.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('validates domains, IPv4 addresses and port bounds', () {
    Server parse(String host, String port) =>
        Server.validated('id', ' Test ', host, port, '', '', true);
    expect(parse(' EXAMPLE.COM. ', '1').host, 'example.com');
    expect(parse('192.168.0.255', '65535').address, '192.168.0.255:65535');
    for (final invalid in [
      '1.2.3.999',
      '01.2.3.4',
      'https://host.de',
      '::1',
      'a..de',
      '-a.de',
    ]) {
      expect(() => parse(invalid, '19132'), throwsFormatException);
    }
    for (final invalid in ['0', '65536', '+1', '1.2']) {
      expect(() => parse('host.de', invalid), throwsFormatException);
    }
  });

  test('edits, sorts and removes favorites and selection references', () {
    final data = Favorites()
      ..put(const Server('own', 'AAA', 'test.de', 42, favorite: false));
    data.sort();
    expect(data.servers.last.id, 'own');
    data.put(const Server('own', 'AAA', 'test.de', 43));
    data.sort();
    expect(data.servers.first.port, 43);
    data.put(const Server('secondary', 'Beta', 'example.net', 19132));
    data.primary = 'secondary';
    data.last = 'own';
    expect(data.initialSelection, 'own');
    data.remember = false;
    expect(data.initialSelection, 'secondary');
    data.remove('secondary');
    expect(data.primary, isNull);
    data.remove('own');
    expect(data.last, isNull);
  });

  test(
    'round trips all settings, metadata and an intentionally empty list',
    () {
      final data = Favorites(
        servers: [],
        last: 'x',
        primary: 'x',
        dark: false,
        remember: false,
        autoStop: false,
      );
      expect(Favorites.decode(data.encode()).encode(), data.encode());
      data.put(
        const Server(
          'x',
          'Name',
          'test.de',
          1024,
          icon: '⬛',
          description: 'Welt',
          favorite: false,
        ),
      );
      expect(Favorites.decode(data.encode()).encode(), data.encode());
      expect(Favorites.decode(null).servers, isEmpty);
      expect(Favorites.decode(null).autoStop, isTrue);
    },
  );

  test('migrates old presets while preserving user-added servers', () {
    const preset = Server('preset', 'Old default', 'preset.example', 19132);
    const custom = Server('123456789', 'My server', 'private.example', 19133);
    final migrated = Favorites.decode(
      jsonEncode({
        'servers': [preset, custom],
        'primary': preset.id,
        'last': custom.id,
        'autoStop': false,
      }),
    );
    expect(migrated.servers.map((server) => server.id), [custom.id]);
    expect(migrated.initialSelection, custom.id);
    expect(migrated.primary, isNull);
    expect(migrated.autoStop, isTrue);
    expect(Favorites.decode(migrated.encode()).encode(), migrated.encode());
  });
}
