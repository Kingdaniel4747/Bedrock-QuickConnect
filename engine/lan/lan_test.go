package lan

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"net"
	"strconv"
	"testing"
	"time"

	"github.com/df-mc/go-nethernet"
	"github.com/df-mc/go-nethernet/discovery"
	"github.com/pion/webrtc/v4"
	"github.com/sandertv/gophertunnel/minecraft"
	"github.com/sandertv/gophertunnel/minecraft/protocol"
	"github.com/sandertv/gophertunnel/minecraft/protocol/login"
	"github.com/sandertv/gophertunnel/minecraft/protocol/packet"
)

func TestNetherNetDiscoveryAndTransfer(t *testing.T) {
	const host = "example.com"
	const port = 19132
	key, err := ecdsa.GenerateKey(elliptic.P384(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	events := make(chan string, 8)
	local := net.IPv4(127, 0, 0, 1)
	reservation, err := net.ListenUDP("udp4", &net.UDPAddr{IP: local})
	if err != nil {
		t.Fatal(err)
	}
	discoveryAddr := reservation.LocalAddr().(*net.UDPAddr)
	reservation.Close()
	s, err := start(discoveryAddr.String(), local.String(), host, port, key, true, func(event string) { events <- event })
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()

	// Verify that a second server cannot take over the discovery socket.
	duplicate, err := start(discoveryAddr.String(), local.String(), host, port, key, true, func(string) {})
	if err == nil {
		duplicate.Close()
		t.Fatal("second discovery listener started")
	}

	dc := discovery.ListenConfig{BroadcastAddress: discoveryAddr}
	client, err := dc.Listen("127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer client.Close()
	ctx, cancel := context.WithTimeout(t.Context(), 25*time.Second)
	defer cancel()

	id := waitForDiscovery(t, ctx, client)
	// Pion excludes loopback interfaces by default.
	settings := testSettings(local)
	n := minecraft.NetherNet{Signaling: client, Dialer: settings}
	// Vanilla clients and cosmetics can supply metadata outside the
	// gameplay validator's assumptions. This must not prevent a transfer.
	data := login.ClientData{
		DeviceOS: protocol.DeviceWin32, GameVersion: "1.26.62", LanguageCode: "de_DE",
		PlatformOnlineID: "platform-specific-id", SkinResourcePatch: "not-json",
	}
	if data.Validate() == nil {
		t.Fatal("fixture must be rejected by strict client data validation")
	}
	conn, err := (minecraft.Dialer{ClientData: data}).DialContextNetwork(ctx, n, id)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	if err := conn.DoSpawnContext(ctx); err != nil {
		t.Fatal(err)
	}
	_ = conn.SetReadDeadline(time.Now().Add(5 * time.Second))
	for {
		pk, err := conn.ReadPacket()
		if err != nil {
			t.Fatal(err)
		}
		if transfer, ok := pk.(*packet.Transfer); ok {
			if transfer.Address != host || transfer.Port != port || transfer.ReloadWorld {
				t.Fatalf("unexpected transfer: %#v", transfer)
			}
			break
		}
	}
	for _, want := range []string{"connected", "transfer:example.com:19132"} {
		select {
		case event := <-events:
			if event != want {
				t.Fatalf("event %q, want %q", event, want)
			}
		case <-ctx.Done():
			t.Fatal(ctx.Err())
		}
	}

	s.Close()
	bound, err := net.ListenPacket("udp4", discoveryAddr.String())
	if err != nil {
		t.Fatalf("port was not released: %v", err)
	}
	bound.Close()
}

func waitForDiscovery(t *testing.T, ctx context.Context, client *discovery.Listener) string {
	t.Helper()
	tick := time.NewTicker(25 * time.Millisecond)
	defer tick.Stop()
	for {
		select {
		case <-ctx.Done():
			t.Fatal("no valid NetherNet discovery response")
		case <-tick.C:
			for id, payload := range client.Responses() {
				var data discovery.ServerData
				if err := data.UnmarshalBinary(payload); err != nil {
					t.Fatal(err)
				}
				if data.ServerName != "Bedrock QuickConnect" || data.ConnectionType != 4 || data.Nonce == "" {
					t.Fatalf("invalid discovery metadata: %#v", data)
				}
				return strconv.FormatUint(id, 10)
			}
		}
	}
}

func testSettings(ip net.IP) nethernet.Dialer {
	var engine webrtc.SettingEngine
	engine.SetIncludeLoopbackCandidate(true)
	engine.SetNetworkTypes([]webrtc.NetworkType{webrtc.NetworkTypeUDP4})
	engine.SetIPFilter(func(candidate net.IP) bool { return candidate.Equal(ip) })
	return nethernet.Dialer{API: webrtc.NewAPI(webrtc.WithSettingEngine(engine))}
}
