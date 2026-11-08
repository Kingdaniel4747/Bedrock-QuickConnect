package lan

import (
	"context"
	"fmt"
	"log/slog"
	"strings"
)

// Expose only fixed descriptions. Upstream records may contain login data,
// identities or signaling payloads.
type diagnosticHandler struct {
	report    func(string)
	transport bool
}

func diagnosticLogger(report func(string), transport bool) *slog.Logger {
	return slog.New(diagnosticHandler{report: report, transport: transport})
}

func (h diagnosticHandler) Enabled(_ context.Context, level slog.Level) bool {
	return level >= slog.LevelError || (!h.transport && level >= slog.LevelDebug)
}

func (h diagnosticHandler) Handle(_ context.Context, record slog.Record) error {
	message := record.Message
	if h.transport {
		if message == "error handling offer" || message == "error handling signal" {
			detail := "NetherNet-Signaling fehlgeschlagen."
			record.Attrs(func(attr slog.Attr) bool {
				if attr.Key != "error" {
					return true
				}
				switch err := fmt.Sprint(attr.Value.Any()); {
				case strings.Contains(err, "identity"):
					detail = "NetherNet-Identitätsprüfung fehlgeschlagen."
				case strings.Contains(err, "ICE"):
					detail = "NetherNet konnte keinen ICE-Netzwerkpfad aufbauen."
				case strings.Contains(err, "DTLS"):
					detail = "NetherNet-DTLS-Handshake fehlgeschlagen."
				case strings.Contains(err, "SCTP"):
					detail = "NetherNet-SCTP-Datenkanal konnte nicht aufgebaut werden."
				}
				return false
			})
			h.report("diagnostic:" + detail)
		}
		return nil
	}
	var detail string
	switch {
	case message == "login timed out":
		detail = "Zeitlimit bei der Bedrock-Anmeldung erreicht."
	case strings.Contains(message, "validate client data"):
		detail = "Bedrock-Clientdaten wurden bei der Anmeldung abgelehnt."
	case strings.Contains(message, "verify") || strings.Contains(message, "authenticated"):
		detail = "Bedrock-Anmeldeprüfung fehlgeschlagen."
	case strings.Contains(message, "handle *packet.Login"):
		detail = "Bedrock-Login-Paket konnte nicht verarbeitet werden."
	case strings.Contains(message, "handle *packet.ResourcePackClientResponse"):
		detail = "Bedrock-Ressourcenpaket-Aushandlung fehlgeschlagen."
	case strings.Contains(message, "entity runtime ID mismatch"):
		detail = "Bedrock hat eine unerwartete Spieler-ID gemeldet."
	case record.Level >= slog.LevelError:
		detail = "Bedrock-Datenkanal oder Paketverarbeitung abgebrochen."
	}
	if detail != "" {
		h.report("diagnostic:" + detail)
	}
	return nil
}

func (h diagnosticHandler) WithAttrs([]slog.Attr) slog.Handler { return h }
func (h diagnosticHandler) WithGroup(string) slog.Handler      { return h }
