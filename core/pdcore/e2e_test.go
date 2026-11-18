package pdcore

import (
	"context"
	"crypto/ecdh"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"encoding/pem"
	"fmt"
	"io"
	"math/big"
	"net"
	"net/http"
	"net/url"
	"strings"
	"testing"
	"time"

	xnet "github.com/xtls/xray-core/common/net"
	"github.com/xtls/xray-core/core"

	"github.com/kyzaygy/paradise/core/internal/model"
	"github.com/kyzaygy/paradise/core/internal/sub"
	"github.com/kyzaygy/paradise/core/internal/xcfg"
)

// End-to-end: a real Xray server runs on localhost for each protocol, the client config is produced
// by our link parser and config builder, and an HTTP request goes through the tunnel. The server's
// freedom outbound redirects every connection to a local HTTP server, so no internet is needed.

const e2eToken = "paradise-e2e-ok"

func freePort(t *testing.T, network string) int {
	t.Helper()
	if network == "udp" {
		c, err := net.ListenPacket("udp", "127.0.0.1:0")
		if err != nil {
			t.Fatal(err)
		}
		defer c.Close()
		return c.LocalAddr().(*net.UDPAddr).Port
	}
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer l.Close()
	return l.Addr().(*net.TCPAddr).Port
}

func httpTarget(t *testing.T) int {
	t.Helper()
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	srv := &http.Server{Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { _, _ = io.WriteString(w, e2eToken) })}
	go func() { _ = srv.Serve(l) }()
	t.Cleanup(func() { _ = srv.Close() })
	return l.Addr().(*net.TCPAddr).Port
}

type selfSigned struct {
	certPEM, keyPEM []string
	sha256          string
	tlsCert         tls.Certificate
}

func newCert(t *testing.T) selfSigned {
	t.Helper()
	key, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	tmpl := &x509.Certificate{
		SerialNumber: big.NewInt(1), Subject: pkix.Name{CommonName: "localhost"},
		NotBefore: time.Now().Add(-time.Hour), NotAfter: time.Now().Add(24 * time.Hour),
		DNSNames: []string{"localhost"}, IPAddresses: []net.IP{net.ParseIP("127.0.0.1")},
		KeyUsage: x509.KeyUsageDigitalSignature, ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
	}
	der, err := x509.CreateCertificate(rand.Reader, tmpl, tmpl, &key.PublicKey, key)
	if err != nil {
		t.Fatal(err)
	}
	kb, _ := x509.MarshalECPrivateKey(key)
	certPEM := string(pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der}))
	keyPEM := string(pem.EncodeToMemory(&pem.Block{Type: "EC PRIVATE KEY", Bytes: kb}))
	pair, _ := tls.X509KeyPair([]byte(certPEM), []byte(keyPEM))
	sum := sha256.Sum256(der)
	return selfSigned{certPEM: strings.Split(strings.TrimSpace(certPEM), "\n"), keyPEM: strings.Split(strings.TrimSpace(keyPEM), "\n"), sha256: hex.EncodeToString(sum[:]), tlsCert: pair}
}

func (c selfSigned) tlsSettings(alpn ...string) map[string]any {
	s := map[string]any{"certificates": []any{map[string]any{"certificate": c.certPEM, "key": c.keyPEM}}}
	if len(alpn) > 0 {
		s["alpn"] = alpn
	}
	return s
}

func startXray(t *testing.T, inbound map[string]any, redirectPort int) {
	t.Helper()
	cfg := map[string]any{
		"log":       map[string]any{"loglevel": "warning"},
		"inbounds":  []any{inbound},
		"outbounds": []any{map[string]any{"protocol": "freedom", "settings": map[string]any{"redirect": fmt.Sprintf("127.0.0.1:%d", redirectPort)}}},
	}
	b, _ := json.Marshal(cfg)
	inst, err := core.StartInstance("json", b)
	if err != nil {
		t.Fatalf("server: %v\n%s", err, b)
	}
	t.Cleanup(func() { _ = inst.Close() })
}

// fetchThrough starts the client config Paradise builds for srv and sends an HTTP request to a public address.
func fetchThrough(t *testing.T, srv model.Server) {
	t.Helper()
	cfg, err := xcfg.Probe(srv, xcfg.Options{Settings: model.DefaultSettings()})
	if err != nil {
		t.Fatal(err)
	}
	inst, err := core.StartInstance("json", cfg)
	if err != nil {
		t.Fatalf("client: %v\n%s", err, cfg)
	}
	defer inst.Close()
	var lastErr error
	for attempt := 0; attempt < 3; attempt++ {
		ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
		body, err := func() (string, error) {
			conn, err := core.Dial(ctx, inst, xnet.TCPDestination(xnet.ParseAddress("93.184.215.14"), 80))
			if err != nil {
				return "", err
			}
			defer conn.Close()
			_ = conn.SetDeadline(time.Now().Add(8 * time.Second))
			if _, err := io.WriteString(conn, "GET / HTTP/1.1\r\nHost: e2e.test\r\nConnection: close\r\n\r\n"); err != nil {
				return "", err
			}
			b, err := io.ReadAll(conn)
			return string(b), err
		}()
		cancel()
		if strings.Contains(body, e2eToken) {
			return
		}
		lastErr = fmt.Errorf("%v (got %q)", err, body)
		time.Sleep(300 * time.Millisecond)
	}
	t.Fatalf("%s: no response through the tunnel: %v", srv.Protocol, lastErr)
}

func mustLink(t *testing.T, link string) model.Server {
	t.Helper()
	srv, err := sub.ParseURI(link)
	if err != nil {
		t.Fatalf("%s: %v", link, err)
	}
	return srv
}

func TestEndToEndProtocols(t *testing.T) {
	target := httpTarget(t)
	cert := newCert(t)
	const id = "b831381d-6324-4d53-ad4f-8cda48b30811"

	t.Run("vless-tcp", func(t *testing.T) {
		port := freePort(t, "tcp")
		startXray(t, map[string]any{"protocol": "vless", "listen": "127.0.0.1", "port": port,
			"settings": map[string]any{"clients": []any{map[string]any{"id": id}}, "decryption": "none"}}, target)
		fetchThrough(t, mustLink(t, fmt.Sprintf("vless://%s@127.0.0.1:%d?type=tcp&security=none#v", id, port)))
	})

	t.Run("vless-reality-vision", func(t *testing.T) {
		dest := freePort(t, "tcp")
		l, err := tls.Listen("tcp", fmt.Sprintf("127.0.0.1:%d", dest), &tls.Config{Certificates: []tls.Certificate{cert.tlsCert}, MinVersion: tls.VersionTLS13})
		if err != nil {
			t.Fatal(err)
		}
		destSrv := &http.Server{Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { _, _ = io.WriteString(w, "camouflage") })}
		go func() { _ = destSrv.Serve(l) }()
		defer destSrv.Close()
		priv, _ := ecdh.X25519().GenerateKey(rand.Reader)
		port := freePort(t, "tcp")
		startXray(t, map[string]any{"protocol": "vless", "listen": "127.0.0.1", "port": port,
			"settings": map[string]any{"clients": []any{map[string]any{"id": id, "flow": "xtls-rprx-vision"}}, "decryption": "none"},
			"streamSettings": map[string]any{"network": "tcp", "security": "reality", "realitySettings": map[string]any{
				"dest": fmt.Sprintf("127.0.0.1:%d", dest), "serverNames": []any{"localhost"},
				"privateKey": base64.RawURLEncoding.EncodeToString(priv.Bytes()), "shortIds": []any{"ab12"}}}}, target)
		pbk := base64.RawURLEncoding.EncodeToString(priv.PublicKey().Bytes())
		fetchThrough(t, mustLink(t, fmt.Sprintf("vless://%s@127.0.0.1:%d?type=tcp&security=reality&pbk=%s&sid=ab12&sni=localhost&fp=chrome&flow=xtls-rprx-vision#r", id, port, pbk)))
	})

	t.Run("vmess-ws", func(t *testing.T) {
		port := freePort(t, "tcp")
		startXray(t, map[string]any{"protocol": "vmess", "listen": "127.0.0.1", "port": port,
			"settings":       map[string]any{"clients": []any{map[string]any{"id": id}}},
			"streamSettings": map[string]any{"network": "ws", "wsSettings": map[string]any{"path": "/ws"}}}, target)
		vm, _ := json.Marshal(map[string]any{"v": "2", "ps": "vm", "add": "127.0.0.1", "port": fmt.Sprint(port), "id": id, "aid": "0", "net": "ws", "path": "/ws", "tls": ""})
		fetchThrough(t, mustLink(t, "vmess://"+base64.StdEncoding.EncodeToString(vm)))
	})

	t.Run("trojan-tls-pinned", func(t *testing.T) {
		port := freePort(t, "tcp")
		startXray(t, map[string]any{"protocol": "trojan", "listen": "127.0.0.1", "port": port,
			"settings":       map[string]any{"clients": []any{map[string]any{"password": "secret"}}},
			"streamSettings": map[string]any{"network": "tcp", "security": "tls", "tlsSettings": cert.tlsSettings()}}, target)
		fetchThrough(t, mustLink(t, fmt.Sprintf("trojan://secret@127.0.0.1:%d?security=tls&sni=localhost&pcs=%s&allowInsecure=1#t", port, cert.sha256)))
	})

	t.Run("shadowsocks-2022", func(t *testing.T) {
		key := make([]byte, 16)
		_, _ = rand.Read(key)
		pass := base64.StdEncoding.EncodeToString(key)
		port := freePort(t, "tcp")
		startXray(t, map[string]any{"protocol": "shadowsocks", "listen": "127.0.0.1", "port": port,
			"settings": map[string]any{"method": "2022-blake3-aes-128-gcm", "password": pass, "network": "tcp,udp"}}, target)
		fetchThrough(t, mustLink(t, "ss://"+url.UserPassword("2022-blake3-aes-128-gcm", pass).String()+fmt.Sprintf("@127.0.0.1:%d#ss", port)))
	})

	t.Run("socks-base64", func(t *testing.T) {
		port := freePort(t, "tcp")
		startXray(t, map[string]any{"protocol": "socks", "listen": "127.0.0.1", "port": port,
			"settings": map[string]any{"auth": "password", "accounts": []any{map[string]any{"user": "u", "pass": "p"}}}}, target)
		fetchThrough(t, mustLink(t, "socks://"+base64.StdEncoding.EncodeToString([]byte("u:p"))+fmt.Sprintf("@127.0.0.1:%d#s", port)))
	})

	t.Run("hysteria2-pinned", func(t *testing.T) {
		port := freePort(t, "udp")
		startXray(t, map[string]any{"protocol": "hysteria", "listen": "127.0.0.1", "port": port,
			"settings": map[string]any{"version": 2, "clients": []any{map[string]any{"auth": "pass"}}},
			"streamSettings": map[string]any{"network": "hysteria", "security": "tls", "tlsSettings": cert.tlsSettings("h3"),
				"hysteriaSettings": map[string]any{"version": 2}}}, target)
		fetchThrough(t, mustLink(t, fmt.Sprintf("hysteria2://pass@127.0.0.1:%d?sni=localhost&pinSHA256=%s#hy", port, cert.sha256)))
	})

	t.Run("wireguard", func(t *testing.T) {
		serverKey, _ := ecdh.X25519().GenerateKey(rand.Reader)
		clientKey, _ := ecdh.X25519().GenerateKey(rand.Reader)
		port := freePort(t, "udp")
		startXray(t, map[string]any{"protocol": "wireguard", "listen": "127.0.0.1", "port": port,
			"settings": map[string]any{"secretKey": base64.StdEncoding.EncodeToString(serverKey.Bytes()), "mtu": 1420,
				"noKernelTun": true, "peers": []any{map[string]any{"publicKey": base64.StdEncoding.EncodeToString(clientKey.PublicKey().Bytes()), "allowedIPs": []any{"10.66.0.2/32"}}}}}, target)
		conf := fmt.Sprintf("[Interface]\nPrivateKey = %s\nAddress = 10.66.0.2/32\nMTU = 1420\n\n[Peer]\nPublicKey = %s\nAllowedIPs = 0.0.0.0/0\nEndpoint = 127.0.0.1:%d\nPersistentKeepalive = 15\n",
			base64.StdEncoding.EncodeToString(clientKey.Bytes()), base64.StdEncoding.EncodeToString(serverKey.PublicKey().Bytes()), port)
		parsed, err := sub.Parse([]byte(conf), "wg")
		if err != nil {
			t.Fatal(err)
		}
		fetchThrough(t, parsed.Servers[0])
	})
}
