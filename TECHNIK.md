# Protokollprüfung und Architektur

Stand 4. November 2026.

Version 0.1.2 behebt die Ablehnung signierter, für die Weiterleitung unbenutzter Client-Metadaten. Nur der lokale Transfer-Listener verwirft diese Felder nach Prüfung der Signatur. Die Prüfung des Mojang-Anmeldetokens, die Xbox-Live-Anforderung und der Abgleich mit der NetherNet-Identität bleiben aktiv.

Version 0.1.1 aktualisiert den NetherNet-Transport auf 1.0.27, verwendet eine gültige lokale Spieler-ID und sendet den Transfer ohne ReloadWorld-Flag. Die App zeigt Kategorien für frühe Transport- und Bedrock-Fehler an. Der konkrete Windows-Fehler 122 muss mit dem neuen Build am Gerät erneut geprüft werden.

| Referenz | Geprüfter Stand | Entscheidung |
| --- | --- | --- |
| [BedrockConnect](https://github.com/Pugmatt/BedrockConnect) | `master` bei `30f697e`, Entwicklungsbranch `26.60`, Release [1.72.1](https://github.com/Pugmatt/BedrockConnect/releases/tag/1.72.1), GPL-3.0 | Der Java-Server akzeptiert Bedrock-Sitzungen über Cloudburst und besitzt für NetherNet TCP/HTTP-Signaling. Sein Packet-Handler sendet ein Transferpaket mit Adresse und Port nach der Sitzungsinitialisierung. QuickConnect setzt denselben Ablauf unabhängig um. |
| [CloudburstMC Protocol](https://github.com/CloudburstMC/Protocol) | Hauptbranch `3.0` bei `17a89ac`, daneben `develop` und `next-version`; Codec 2225, 3.0-Snapshot-Linie, Apache-2.0 | Bedrock-Pakete und Serialisierung. NetherNet-Discovery und Transport liegen im separaten [CloudburstMC Network](https://github.com/CloudburstMC/Network) auf `develop`. QuickConnect verwendet stattdessen einen einbettbaren Go-Netzwerkstack und umgeht die Portierung des Desktop-Stacks auf Android. |
| [MCXboxBroadcast](https://github.com/MCXboxBroadcast/Broadcaster) | `master` bei `e7ef6b0`, Branch `feature/native-webrtc`, [Build 162](https://github.com/MCXboxBroadcast/Broadcaster/releases), GPL-3.0; Cloudburst-Codec für die 26.60-Linie und NetherNet-Transport | Der Ansatz veröffentlicht eine Sitzung über Xbox Live und benötigt ein Microsoft-Konto für den Broadcaster. QuickConnect verwendet lokale LAN-Discovery und kommt ohne dieses zusätzliche Konto aus. |
| [Mojang Protokollhistorie](https://mojang.github.io/bedrock-protocol-docs/changelog/#12661) | 1.26.60 und 1.26.61 verwenden Protokoll 2225. | Die 26.61-Hotfixlinie teilt das Paketformat mit 26.60. Die Xbox-spezifische Transferannahme bleibt separat zu prüfen. |

## Ablauf

1. Flutter lädt Favoriten über einen Android-MethodChannel. DataStore speichert den JSON-Snapshot atomar. Android meldet Zustände über einen EventChannel.
2. Ein Kotlin-Vordergrunddienst wählt ein WLAN mit IPv4, beobachtet dessen Link-Ereignisse und hält den Multicast-Lock. Er lädt den Go-Dienst per JNI. Beim Stoppen schließt der Dienst die Session und gibt Sockets sowie Android-Ressourcen frei.
3. [go-nethernet](https://github.com/df-mc/go-nethernet/tree/v1.0.27) beantwortet echte NetherNet-Discovery-Anfragen. Der Listener tauscht Signale über denselben UDP-Port aus. Pion stellt die WebRTC-Datenkanäle über ICE, DTLS und SCTP her. Ein auf dem Gerät gespeicherter Schlüssel signiert die Serveridentität für die SDP-Antwort. [Mojang NetherNet Onboarding](https://github.com/Mojang/bedrock-protocol-docs/blob/main/additional_docs/NetherNetOnboardingGuide.md)
4. [gophertunnel](https://github.com/Sandertv/gophertunnel/tree/0e179fc4bb082c13e946c7d81ab1cf9f623d942c) führt Bedrock-Login, Ressourcenpaket-Aushandlung und Initialisierung durch. Anschließend schreibt und flusht QuickConnect `Transfer`. Die lokale Verbindung bleibt bis zum Client-Disconnect oder höchstens fünf Sekunden nach dem Flush offen. Das Ende der lokalen Verbindung enthält keine Information über den Erfolg des Zielbeitritts.
5. Die Xbox baut für das Ziel eine neue Verbindung auf. Die App vermittelt nach der Übergabe keine Welt- oder Add-on-Daten.

## Lokale Anpassungen an Abhängigkeiten

- `engine/third_party/gophertunnel` enthält den Bedrock-Teil der festgelegten MIT-Revision. `minecraft/protocol/login/data.go` akzeptiert auch leere LAN-Adressmetadaten und numerische NetherNet-IDs. Für Host/Port-Metadaten wird nur die Syntax geprüft, wodurch der Listener keine DNS-Abfrage für eine vom Client gemeldete Adresse ausführt. Authentifizierung und Signaturprüfungen bleiben aktiv. Der lokale Loopback-Test hat den ursprünglichen Fehler mit der numerischen ID reproduziert.
- `engine/third_party/anet` enthält den BSD-3-Clause-Android-Netzwerkadapter aus v0.0.5. Der IPv4-Pfad verzichtet auf die privaten IPv6-Zonen-Cache-Symbole der Go-Standardbibliothek. Das beseitigt den Android-Linkfehler mit Go 1.26.1 und lässt die Android-Interface-Ermittlung bestehen.

## Teststand

- `flutter analyze` lief ohne Befunde. Drei Tests mit `flutter test` bestanden. Die Suite prüft Favoritenverwaltung, Adressen, Portgrenzen und die Serialisierung für DataStore.
- Vier Tests mit `testDebugUnitTest` bestanden. Die Suite prüft Zustandsmeldungen, Fehler und die Entscheidung bei WLAN-Änderungen.
- `go test -v ./lan github.com/df-mc/go-nethernet/discovery` bestand einschließlich der Discovery-Parser-Tests. Der Integrationstest startet einen echten Listener und einen separaten Testclient auf Windows-Loopback. Der Test dekodiert Discovery-Daten, handelt WebRTC aus, initialisiert eine Bedrock-Sitzung, liest das Transferpaket und prüft den Portkonflikt sowie die Freigabe des Testports. Er verwendet für die reproduzierbare Testanmeldung den Offline-Modus. Der APK-Dienst verwendet reguläre Tokenprüfung.
- Android-Emulator API 37, x86-64: damalige Debug-APK installiert, der echte Dienst lauschte auf UDP 7551 und stoppte über die Oberfläche. Dabei wurde kein zweiter Minecraft-Client auf dem Emulator betrieben.
- Der manuelle Test mit echter Xbox One, dem konkreten Minecraft-Hotfix und den drei DynDNS-Zielen steht aus. Er umfasst insbesondere Trust-Dialog, LAN-Broadcast zwischen Geräten und direkte Zielverbindung.






