package lan

import (
	"context"
	"crypto/ecdsa"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/df-mc/go-nethernet"
	"github.com/df-mc/go-nethernet/discovery"
	"github.com/pion/webrtc/v4"
	"github.com/sandertv/gophertunnel/minecraft"
	"github.com/sandertv/gophertunnel/minecraft/protocol"
	"github.com/sandertv/gophertunnel/minecraft/protocol/packet"
)

type Session struct {
	discovery *discovery.Listener
	listener  *minecraft.Listener
	cancel    context.CancelFunc
	done      chan struct{}
	once      sync.Once
}

// Start runs local discovery and hosts one Bedrock player at a time.
func Start(localIP, host string, port uint16, key *ecdsa.PrivateKey, offline bool, report func(string)) (*Session, error) {
	return start("0.0.0.0:7551", localIP, host, port, key, offline, report)
}

func start(discoveryAddr, localIP, host string, port uint16, key *ecdsa.PrivateKey, offline bool, report func(string)) (*Session, error) {
	ip := net.ParseIP(localIP)
	if ip == nil || ip.To4() == nil || host == "" || port == 0 || key == nil {
		return nil, errors.New("invalid LAN or target configuration")
	}
	quiet := slog.New(slog.NewTextHandler(io.Discard, nil))
	dc := discovery.ListenConfig{Log: quiet}
	d, err := dc.Listen(discoveryAddr)
	if err != nil {
		return nil, fmt.Errorf("NetherNet Discovery %s: %w", discoveryAddr, err)
	}

	var settings webrtc.SettingEngine
	settings.SetIncludeLoopbackCandidate(ip.IsLoopback())
	settings.SetNetworkTypes([]webrtc.NetworkType{webrtc.NetworkTypeUDP4})
	settings.SetIPFilter(func(candidate net.IP) bool { return candidate.Equal(ip) })
	n := minecraft.NetherNet{Signaling: lanSignaling{d}, ListenConfig: nethernet.ListenConfig{
		Log: diagnosticLogger(report, true), API: webrtc.NewAPI(webrtc.WithSettingEngine(settings)),
		AllowAnonymous: true,
		IssueServerIdentity: func(context.Context) (*nethernet.Identity, error) {
			return nethernet.ServerIdentity(key, "self")
		},
	}}
	cfg := minecraft.ListenConfig{
		ErrorLog:               diagnosticLogger(report, false),
		HTTPClient:             &http.Client{Timeout: 8 * time.Second},
		AuthenticationDisabled: offline,
		DiscardClientMetadata:  true,
		LoginTimeout:           12 * time.Second, MaximumPlayers: 1,
		StatusProvider: minecraft.NewStatusProvider("Bedrock QuickConnect", "Survival"),
	}
	l, err := cfg.ListenNetwork(n, d.NetworkID())
	if err != nil {
		d.Close()
		return nil, err
	}

	nonce := make([]byte, 16)
	if _, err := rand.Read(nonce); err != nil {
		l.Close()
		d.Close()
		return nil, err
	}
	// Install full LAN metadata. The listener's PongData hook is suppressed
	// below so periodic status updates do not replace the LAN nonce.
	d.ServerData(&discovery.ServerData{
		ServerName: "Bedrock QuickConnect", LevelName: "Bedrock QuickConnect",
		Protocol: protocol.CurrentProtocol, Version: protocol.CurrentVersion,
		GameType: discovery.GameTypeAdventure, MaxPlayerCount: 1,
		AcceptsOnlineAuth: true, AcceptsSelfSignedAuth: offline,
		Nonce: hex.EncodeToString(nonce), ConnectionType: 4,
	})
	ctx, cancel := context.WithCancel(context.Background())
	s := &Session{discovery: d, listener: l, cancel: cancel, done: make(chan struct{})}
	go s.serve(ctx, host, port, report)
	return s, nil
}

func (s *Session) Close() {
	s.once.Do(func() {
		s.cancel()
		s.listener.Close()
		s.discovery.Close()
		<-s.done
	})
}

func (s *Session) serve(ctx context.Context, host string, port uint16, report func(string)) {
	defer close(s.done)
	for {
		raw, err := s.listener.Accept()
		if err != nil {
			if ctx.Err() == nil {
				report("error:Bedrock-Listener beendet: " + err.Error())
			}
			return
		}
		if ctx.Err() != nil {
			raw.Close()
			return
		}
		report("connected")
		err = transfer(ctx, raw.(*minecraft.Conn), host, port, report)
		if ctx.Err() != nil {
			return
		}
		if err != nil {
			report("peer-error:" + err.Error())
		} else {
			report("released")
		}
	}
}

func transfer(parent context.Context, conn *minecraft.Conn, host string, port uint16, report func(string)) error {
	defer conn.Close()
	stop := context.AfterFunc(parent, func() { conn.Close() })
	defer stop()
	ctx, cancel := context.WithTimeout(parent, 15*time.Second)
	defer cancel()
	if err := conn.StartGameContext(ctx, minecraft.GameData{
		WorldName: "Bedrock QuickConnect", BaseGameVersion: protocol.CurrentVersion,
		EntityUniqueID: 1, EntityRuntimeID: 1, ChunkRadius: 4,
		Difficulty: 0, WorldGameMode: 2, PlayerGameMode: 2,
	}); err != nil {
		return fmt.Errorf("Bedrock-Welt konnte nicht initialisiert werden: %w", err)
	}
	if err := conn.WritePacket(&packet.Transfer{Address: host, Port: port}); err != nil {
		return err
	}
	if err := conn.Flush(); err != nil {
		return err
	}
	report("transfer:" + net.JoinHostPort(host, strconv.Itoa(int(port))))
	// Give the reliable SCTP channel time to deliver the packet. A disconnect
	// only describes the local session and does not prove a successful join.
	timer := time.NewTimer(5 * time.Second)
	defer timer.Stop()
	select {
	case <-timer.C:
	case <-conn.Context().Done():
	case <-parent.Done():
	}
	return nil
}

// Keep only explicit LAN metadata, independent of the generic Bedrock pong.
type lanSignaling struct{ *discovery.Listener }

func (lanSignaling) PongData([]byte) {}

// Redact multiline native errors before passing them to the UI.
func Message(err error) string { return strings.Join(strings.Fields(err.Error()), " ") }
