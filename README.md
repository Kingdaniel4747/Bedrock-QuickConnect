# Bedrock QuickConnect

Bedrock QuickConnect zeigt einen lokalen Minecraft-LAN-Eintrag an und schickt einem beigetretenen Bedrock-Client das Transferpaket für den ausgewählten Favoriten. Die Oberfläche nutzt Flutter und Dart mit Material 3. Android 10 oder neuer und ein lokales WLAN mit IPv4 werden vorausgesetzt.

## Installieren und verbinden

1. Lade unter **Releases** die APK für dein Android-Gerät herunter und installiere sie. Verwende `Bedrock-QuickConnect-arm64-v8a.apk` für ARM64-Handys oder `Bedrock-QuickConnect-x86_64.apk` für x86-64-Geräte und Emulatoren.
2. Verbinde Android und Xbox One mit demselben lokalen Netz. Verwende auf dem Handy WLAN und auf der Xbox eine aktuelle Bedrock-Version.
3. Wähle einen Server aus. Über **+** legst du einen Favoriten mit Domain oder IPv4-Adresse und Port an. Das Menü an der Karte enthält **Bearbeiten**, **Als Standard festlegen** und **Löschen**. Die Sortierung stellt Favoriten zuerst und sortiert nach Name.
4. Tippe auf **Verbindung starten**. Sobald der Dienst auf UDP 7551 lauscht, öffne auf der Xbox **Minecraft → Spielen → Freunde oder Welten → LAN-Spiele** und wähle **Bedrock QuickConnect**. Der Menüname kann je nach Version variieren.
5. Warte auf den Zielbeitritt auf der Xbox. Der App-Status bestätigt das gesendete Transferpaket und das Ende der lokalen Sitzung. Beende den Dienst über die App oder die Benachrichtigung. Standardmäßig stoppt er nach der lokalen Übergabe selbstständig. Die Oberfläche bleibt für die Diagnose geöffnet.

Die App startet bei einer Neuinstallation mit leerer Serverliste. Die App übergibt die Domain unverändert an Minecraft. Der Client löst sie beim Beitritt selbst auf. Bei einer wechselnden WAN-IP gelten die normalen DNS-TTLs und Caches.

## Updates

Die veröffentlichte App prüft beim Öffnen auf GitHub, ob es eine neuere Version für das Gerät gibt. Wähle **Jetzt aktualisieren**, um die APK in der App herunterzuladen und den Android-Installer zu öffnen, oder **Später**, um den Hinweis zu schließen. Android kann beim ersten Update die Freigabe **Dieser Quelle vertrauen** verlangen. Bestätige anschließend die Installation. Bei Updates mit demselben Signaturschlüssel bleiben die Favoriten erhalten.

Falls noch eine frühere Debug-APK installiert ist, muss sie vor der ersten Installation mit dem Release-Schlüssel deinstalliert werden. Dabei werden lokal gespeicherte Favoriten gelöscht.

## Automatische GitHub-Releases

Jeder Push auf den Standardbranch baut beide APKs und veröffentlicht sie gemeinsam unter **Releases**. Der Workflow prüft die Signaturen und vergibt pro Lauf einen steigenden Android-Versionscode. Das öffentliche Repository für die Update-Abfrage wird beim Build automatisch eingebettet.

Vor dem ersten Push mit aktivem Workflow einen PKCS12-Signaturschlüssel mit dem Alias `quickconnect` erstellen und sicher sichern:

```sh
keytool -genkeypair -keystore quickconnect.p12 -storetype PKCS12 -alias quickconnect \
  -keyalg RSA -keysize 3072 -validity 10000
```

Im GitHub-Repository unter **Settings → Secrets and variables → Actions** die Secrets `ANDROID_KEYSTORE_BASE64` (Base64 der gesamten Datei) und `ANDROID_KEYSTORE_PASSWORD` (das beim Erstellen vergebene Passwort) hinterlegen. Für alle Releases denselben Schlüssel verwenden.

## Bauen und Hot Reload

Benötigt werden Flutter 3.47.7 mit Dart 3.13.5, Go 1.25 oder neuer (geprüfte Toolchain 1.26.1), ein JDK für Android Gradle Plugin 9.1, Android SDK 36, Build Tools 36 und NDK 28.2.13676358. Flutter muss das Android SDK finden. Go muss im PATH liegen oder über `QUICKCONNECT_GO` auf seine ausführbare Datei zeigen. Die APK enthält native Bibliotheken für ARM64 und x86-64.

```sh
flutter pub get
flutter analyze
flutter test
flutter build apk --debug --target-platform android-arm64,android-x64
flutter run
```

Die Debug-APK liegt unter `build/app/outputs/flutter-apk/app-debug.apk`. Für den Hot Reload im Terminal drücke während `flutter run` die Taste `r`. Änderungen an Kotlin, Go oder JNI erfordern einen neuen Build und App-Start.

```sh
cd engine
go test -v ./lan
cd ../android
./gradlew testDebugUnitTest assembleDebug
```

Unter Windows verwende `gradlew.bat`. Führe den direkten Gradle-Aufruf nach dem ersten Flutter-Build aus, damit Flutter die lokalen SDK-Pfade eingerichtet hat. Der Go-Test verwendet vorübergehend einen freien UDP-Port auf Windows-Loopback. Der Android-Dienst verwendet UDP 7551.

## Netzwerk und Diagnose

- **Handy:** NetherNet-LAN-Discovery und SDP/ICE-Signaling über UDP 7551. WebRTC nutzt dynamische UDP-Ports und lokale IPv4-Kandidaten der ausgewählten WLAN-Adresse. Für den Handy-Dienst sind weder ein DNS-Wechsel noch eine Router-Portweiterleitung nötig.
- **Zielserver:** Der Transfer übergibt Domain und Port. Bei einem externen NetherNet-BDS muss die Xbox dessen TCP-Signaling und UDP-WebRTC-Kandidaten erreichen können. Konfiguration, NAT und Firewall des Zielservers bleiben maßgeblich. Von innen kann eine öffentliche DynDNS-Adresse NAT-Loopback oder passendes lokales DNS voraussetzen. Eine Vertrauensabfrage für die lokale Identität oder das Ziel kann auf der Xbox erscheinen.
- **Anmeldung:** Der lokale Bedrock-Listener prüft reguläre Minecraft-Anmeldetoken mit Mojangs Autorisierungsdaten. Der Dienst braucht dafür Zugriff auf die Minecraft-Authentifizierungsendpunkte. Die App hat kein Benutzerkonto und keinen eigenen Cloud-Dienst. LAN-SDP-Angebote dürfen ohne Transport-Identität ankommen. Liegt ein Transport-Schlüssel vor, prüft der Bedrock-Listener seine Bindung an den Login-Schlüssel.
- **Kein LAN-Eintrag:** Öffne die LAN-Diagnose und prüfe IPv4 und Dienststatus. Gast-WLAN, AP-Isolation oder Netzwechsel können die Verbindung unterbrechen. Bei WLAN-Verlust oder IPv4-Wechsel beendet die App die alte Sitzung. Starte sie nach dem Wechsel erneut.
- **Transfer gesendet, Ziel bleibt unerreichbar:** Prüfe die Meldung auf der Xbox, die Erreichbarkeit des Zielservers über NetherNet und gegebenenfalls eine Vertrauensabfrage. Der Handy-Dienst kann die neue Verbindung nach dem Transfer nicht sehen.
- **Versionen:** Implementiert ist Bedrock-Protokoll 2225 für die 26.60/26.61-Familie. Neuere Builds mit anderer Protokollnummer benötigen einen Codec-Abgleich. IPv6-only-WLAN und ältere RakNet-LAN-Clients werden von diesem Build nicht unterstützt.

Android benötigt Internet- und Netzwerkstatuszugriff, WLAN-Status und einen Multicast-Lock während der Sitzung. Der Vordergrunddienst verwendet den Typ `connectedDevice`; die dafür deklarierte Netzwerkberechtigung wird nicht verwendet, um WLAN, Routing oder DNS umzukonfigurieren. Die Benachrichtigungsberechtigung ab Android 13 ist für die sichtbare Stop-Aktion vorgesehen. Favoriten werden in Android DataStore gespeichert. Die lokale P-384-Betreiberidentität bleibt im privaten App-Speicher. Der Tab **Netzwerk-Log** zeigt die letzten 80 Ereignisse mit Zeitstempel und verstrichener Zeit seit Sitzungsbeginn. Der Inhalt bleibt im Arbeitsspeicher. Beim Kopieren werden nur diese Ereignisse übernommen, ohne Servernamen, IP-Adressen, Anmeldedaten oder rohe Protokollpakete.

## Manueller Abnahmetest mit Xbox One

1. APK auf einem echten Android-Gerät installieren. Android-Version, Xbox-Modell und exakte Minecraft-Version festhalten.
2. Handy und Xbox ins gleiche WLAN bringen. Einen bekannten NetherNet-BDS als Ziel auswählen. Zielport und Erreichbarkeit vorab separat prüfen.
3. Dienst starten. In der Xbox-LAN-Liste den Eintrag auswählen. Uhrzeit und eventuelle Vertrauensabfragen notieren.
4. In der App die Ereignisse für Clientverbindung und Transfer prüfen. Auf der Xbox kontrollieren, ob der ausgewählte Zielserver geladen wird. Falls möglich, den Login im Zielserver-Log bestätigen.
5. Dienst stoppen und prüfen, dass der LAN-Eintrag nach Aktualisierung verschwindet. Den Start wiederholen. Während einer zweiten Sitzung das WLAN wechseln und prüfen, dass der alte Dienst beendet wird.
6. Für die Automatik den Test mit aktiviertem automatischem Stopp wiederholen. Danach auf der Xbox prüfen, dass der Zielserver unabhängig vom Handy weiterläuft.

Details zu den Quellen, Änderungen und Testgrenzen stehen in [TECHNIK.md](TECHNIK.md).


