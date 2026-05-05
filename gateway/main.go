package main

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"log"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

type streamStatus string

const (
	statusRunning streamStatus = "running"
	statusStopped streamStatus = "stopped"
)

type streamRecord struct {
	ID            string            `json:"id"`
	App           string            `json:"app"`
	Stream        string            `json:"stream"`
	PublishHost   string            `json:"publishHost"`
	ServiceMode   string            `json:"serviceMode"`
	PublisherMeta map[string]any    `json:"publisherMeta,omitempty"`
	SourceMeta    map[string]any    `json:"sourceMeta,omitempty"`
	CreatedAt     time.Time         `json:"createdAt"`
	Status        streamStatus      `json:"status"`
	PlayURLs      map[string]string `json:"playUrls"`
}

type startRequest struct {
	App                string         `json:"app"`
	Stream             string         `json:"stream"`
	ServiceMode        string         `json:"serviceMode"`
	PublisherMeta      map[string]any `json:"publisherMeta"`
	SourceMeta         map[string]any `json:"sourceMeta"`
	PublicProxyEnabled *bool          `json:"publicProxyEnabled,omitempty"`
	PublicHost         string         `json:"publicHost,omitempty"`
}

type startResponse struct {
	ID          string            `json:"id"`
	App         string            `json:"app"`
	Stream      string            `json:"stream"`
	ServiceMode string            `json:"serviceMode"`
	PublishRTMP string            `json:"publishRtmp"`
	PlayHTTPFLV string            `json:"playHttpFlv"`
	PlayHLS     string            `json:"playHls"`
	PlayURLs    map[string]string `json:"playUrls"`
}

type statusResponse struct {
	ID            string            `json:"id"`
	App           string            `json:"app"`
	Stream        string            `json:"stream"`
	ServiceMode   string            `json:"serviceMode"`
	Status        streamStatus      `json:"status"`
	PublishRTMP   string            `json:"publishRtmp"`
	PlayHTTPFLV   string            `json:"playHttpFlv"`
	PlayHLS       string            `json:"playHls"`
	PlayURLs      map[string]string `json:"playUrls"`
	PublisherMeta map[string]any    `json:"publisherMeta,omitempty"`
	SourceMeta    map[string]any    `json:"sourceMeta,omitempty"`
}

var (
	mu                  sync.RWMutex
	publicHostMu        sync.RWMutex
	streams             = map[string]*streamRecord{}
	rtmpPort            = getEnvInt("ZLM_RTMP_PORT", 1935)
	httpPort            = getEnvInt("ZLM_HTTP_PORT", 8080)
	gatewayPort         = getEnvInt("SERVICE_GATEWAY_PORT", 9000)
	ipRoundRobin        uint32
	selectedPublishHost string
	publicHostOverride  string
	publicProxyEnabled  bool
)

func main() {
	log.SetOutput(os.Stdout)
	if envHost := normalizePublicHost(os.Getenv("SERVICE_PUBLIC_HOST")); envHost != "" {
		setPublicHostOverride(envHost, true)
		log.Printf(">>> [PUBLIC-HOST][ENV] enabled host=%s", envHost)
	}
	selectedPublishHost = initPublishHostAtStartup()
	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", healthzHandler)
	mux.HandleFunc("/api/v1/debug/logs", logsHandler)
	mux.HandleFunc("/api/v1/debug/network", networkDebugHandler)
	mux.HandleFunc("/api/v1/streams/start", startHandler)
	mux.HandleFunc("/api/v1/streams/resolve", resolveHandler)
	mux.HandleFunc("/api/v1/streams/", streamByIDHandler)
	mux.HandleFunc("/api/v1/streams", listHandler)

	handler := corsMiddleware(mux)
	addr := ":" + strconv.Itoa(gatewayPort)
	log.Printf("gateway listening on %s", addr)
	if err := http.ListenAndServe(addr, handler); err != nil {
		log.Fatal(err)
	}
}

func healthzHandler(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

func startHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeJSON(w, http.StatusMethodNotAllowed, map[string]string{"error": "method not allowed"})
		return
	}

	var req startRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid json"})
		return
	}

	app := strings.TrimSpace(req.App)
	if app == "" {
		app = "live"
	}
	stream := strings.TrimSpace(req.Stream)
	if stream == "" {
		stream = "stream001"
	}
	serviceMode := normalizeServiceMode(req.ServiceMode)
	if serviceMode == "" {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "serviceMode must be one of direct|broadcast|httpflv"})
		return
	}
	if req.PublicProxyEnabled != nil {
		if *req.PublicProxyEnabled {
			host := normalizePublicHost(req.PublicHost)
			if host == "" {
				writeJSON(w, http.StatusBadRequest, map[string]string{"error": "publicHost is required when publicProxyEnabled=true"})
				return
			}
			setPublicHostOverride(host, true)
		} else {
			setPublicHostOverride("", false)
		}
	}

	mu.RLock()
	for _, rec := range streams {
		if rec.App == app && rec.Stream == stream && rec.Status == statusRunning {
			host := publishHostForResponse(r)
			resp := startResponse{
				ID:          rec.ID,
				App:         rec.App,
				Stream:      rec.Stream,
				ServiceMode: rec.ServiceMode,
				PublishRTMP: "rtmp://" + host + ":" + strconv.Itoa(rtmpPort) + "/" + rec.App + "/" + rec.Stream,
				PlayHTTPFLV: rec.PlayURLs["httpFlv"],
				PlayHLS:     rec.PlayURLs["hls"],
				PlayURLs:    rec.PlayURLs,
			}
			mu.RUnlock()
			writeJSON(w, http.StatusOK, resp)
			return
		}
	}
	mu.RUnlock()

	id, err := randomID()
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "generate id failed"})
		return
	}

	rec := &streamRecord{
		ID:            id,
		App:           app,
		Stream:        stream,
		ServiceMode:   serviceMode,
		PublisherMeta: req.PublisherMeta,
		SourceMeta:    req.SourceMeta,
		CreatedAt:     time.Now(),
		Status:        statusRunning,
	}

	host := publishHostForResponse(r)
	rec.PlayURLs = buildPlayURLs(host, rec.App, rec.Stream, rec.ServiceMode)
	rec.PublishHost = host

	mu.Lock()
	streams[id] = rec
	mu.Unlock()

	resp := startResponse{
		ID:          rec.ID,
		App:         rec.App,
		Stream:      rec.Stream,
		ServiceMode: rec.ServiceMode,
		PublishRTMP: "rtmp://" + host + ":" + strconv.Itoa(rtmpPort) + "/" + rec.App + "/" + rec.Stream,
		PlayHTTPFLV: rec.PlayURLs["httpFlv"],
		PlayHLS:     rec.PlayURLs["hls"],
		PlayURLs:    rec.PlayURLs,
	}
	writeJSON(w, http.StatusOK, resp)
}

func streamByIDHandler(w http.ResponseWriter, r *http.Request) {
	path := strings.TrimPrefix(r.URL.Path, "/api/v1/streams/")
	if path == "" {
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "not found"})
		return
	}

	parts := strings.Split(path, "/")
	id := parts[0]
	if id == "" {
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "not found"})
		return
	}

	switch {
	case len(parts) == 2 && parts[1] == "stop":
		stopHandler(w, r, id)
	case len(parts) == 2 && parts[1] == "status":
		statusHandler(w, r, id)
	default:
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "not found"})
	}
}

func stopHandler(w http.ResponseWriter, r *http.Request, id string) {
	if r.Method != http.MethodPost {
		writeJSON(w, http.StatusMethodNotAllowed, map[string]string{"error": "method not allowed"})
		return
	}
	mu.Lock()
	rec, ok := streams[id]
	if !ok {
		mu.Unlock()
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "stream not found"})
		return
	}
	rec.Status = statusStopped
	mu.Unlock()
	writeJSON(w, http.StatusOK, map[string]string{"id": id, "status": "stopped"})
}

func statusHandler(w http.ResponseWriter, r *http.Request, id string) {
	if r.Method != http.MethodGet {
		writeJSON(w, http.StatusMethodNotAllowed, map[string]string{"error": "method not allowed"})
		return
	}
	mu.RLock()
	rec, ok := streams[id]
	mu.RUnlock()
	if !ok {
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "stream not found"})
		return
	}
	host := strings.TrimSpace(rec.PublishHost)
	if host == "" {
		host = publishHostForResponse(r)
	}
	playUrls := buildPlayURLs(host, rec.App, rec.Stream, rec.ServiceMode)
	rec.PlayURLs = playUrls
	writeJSON(w, http.StatusOK, statusResponse{
		ID:            rec.ID,
		App:           rec.App,
		Stream:        rec.Stream,
		ServiceMode:   rec.ServiceMode,
		Status:        rec.Status,
		PublishRTMP:   "rtmp://" + host + ":" + strconv.Itoa(rtmpPort) + "/" + rec.App + "/" + rec.Stream,
		PlayHTTPFLV:   playUrls["httpFlv"],
		PlayHLS:       playUrls["hls"],
		PlayURLs:      playUrls,
		PublisherMeta: rec.PublisherMeta,
		SourceMeta:    rec.SourceMeta,
	})
}

func listHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeJSON(w, http.StatusMethodNotAllowed, map[string]string{"error": "method not allowed"})
		return
	}
	mu.RLock()
	items := make([]*streamRecord, 0, len(streams))
	for _, rec := range streams {
		items = append(items, rec)
	}
	mu.RUnlock()
	writeJSON(w, http.StatusOK, map[string]any{"items": items})
}

func resolveHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeJSON(w, http.StatusMethodNotAllowed, map[string]string{"error": "method not allowed"})
		return
	}
	app := strings.TrimSpace(r.URL.Query().Get("app"))
	stream := strings.TrimSpace(r.URL.Query().Get("stream"))
	if app == "" || stream == "" {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "app and stream are required"})
		return
	}

	mu.RLock()
	var target *streamRecord
	for _, rec := range streams {
		if rec == nil || rec.App != app || rec.Stream != stream {
			continue
		}
		if target == nil || rec.CreatedAt.After(target.CreatedAt) {
			target = rec
		}
	}
	mu.RUnlock()

	if target == nil {
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "stream not found"})
		return
	}

	host := strings.TrimSpace(target.PublishHost)
	if host == "" {
		host = publishHostForResponse(r)
	}
	playUrls := buildPlayURLs(host, target.App, target.Stream, target.ServiceMode)
	writeJSON(w, http.StatusOK, statusResponse{
		ID:            target.ID,
		App:           target.App,
		Stream:        target.Stream,
		ServiceMode:   target.ServiceMode,
		Status:        target.Status,
		PublishRTMP:   "rtmp://" + host + ":" + strconv.Itoa(rtmpPort) + "/" + target.App + "/" + target.Stream,
		PlayHTTPFLV:   playUrls["httpFlv"],
		PlayHLS:       playUrls["hls"],
		PlayURLs:      playUrls,
		PublisherMeta: target.PublisherMeta,
		SourceMeta:    target.SourceMeta,
	})
}

func logsHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeJSON(w, http.StatusMethodNotAllowed, map[string]string{"error": "method not allowed"})
		return
	}
	limit := 200
	if raw := strings.TrimSpace(r.URL.Query().Get("limit")); raw != "" {
		if v, err := strconv.Atoi(raw); err == nil && v > 0 && v <= 2000 {
			limit = v
		}
	}
	logDir := strings.TrimSpace(os.Getenv("SERVICE_LOG_DIR"))
	if logDir == "" {
		logDir = filepath.Clean(filepath.Join("..", "logs"))
	}
	zlmLog := readTailLines(filepath.Join(logDir, "zlm.log"), limit)
	gatewayLog := readTailLines(filepath.Join(logDir, "gateway.log"), limit)
	gatewayErr := readTailLines(filepath.Join(logDir, "gateway.err.log"), limit)
	uiErr := readTailLines(filepath.Join(logDir, "ui.err.log"), limit)
	writeJSON(w, http.StatusOK, map[string]any{
		"logDir": logDir,
		"zlm": map[string]string{
			"tail": zlmLog,
		},
		"gateway": map[string]string{
			"tail": gatewayLog,
			"err":  gatewayErr,
		},
		"ui": map[string]string{
			"err": uiErr,
		},
	})
}

func networkDebugHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeJSON(w, http.StatusMethodNotAllowed, map[string]string{"error": "method not allowed"})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"publishHost":         publishHostForResponse(r),
		"selectedPublishHost": selectedPublishHost,
		"publicProxyEnabled":  getPublicProxyEnabled(),
		"publicHost":          getPublicHostOverride(),
		"gatewayPort":         gatewayPort,
		"rtmpPort":            rtmpPort,
		"httpPort":            httpPort,
		"os":                  runtime.GOOS,
	})
}

func readTailLines(path string, limit int) string {
	data, err := os.ReadFile(path)
	if err != nil {
		return "read log failed: " + err.Error()
	}
	content := strings.ReplaceAll(string(data), "\r\n", "\n")
	lines := strings.Split(content, "\n")
	if len(lines) > limit {
		lines = lines[len(lines)-limit:]
	}
	return strings.TrimSpace(strings.Join(lines, "\n"))
}

func randomID() (string, error) {
	buf := make([]byte, 8)
	if _, err := rand.Read(buf); err != nil {
		return "", err
	}
	return hex.EncodeToString(buf), nil
}

func normalizeServiceMode(raw string) string {
	mode := strings.ToLower(strings.TrimSpace(raw))
	switch mode {
	case "", "direct":
		return "direct"
	case "broadcast":
		return "broadcast"
	case "httpflv", "http-flv", "http_flv":
		return "httpflv"
	default:
		return ""
	}
}

func buildPlayURLs(host, app, stream, mode string) map[string]string {
	urls := map[string]string{
		"rtmp": "rtmp://" + host + ":" + strconv.Itoa(rtmpPort) + "/" + app + "/" + stream,
	}
	if mode == "httpflv" || mode == "broadcast" {
		urls["httpFlv"] = "http://" + host + ":" + strconv.Itoa(httpPort) + "/" + app + "/" + stream + ".flv"
		urls["hls"] = "http://" + host + ":" + strconv.Itoa(httpPort) + "/" + app + "/" + stream + "/hls.m3u8"
	}
	return urls
}

func getEnvInt(key string, fallback int) int {
	raw := strings.TrimSpace(os.Getenv(key))
	if raw == "" {
		return fallback
	}
	v, err := strconv.Atoi(raw)
	if err != nil || v <= 0 || v > 65535 {
		return fallback
	}
	return v
}

func writeJSON(w http.ResponseWriter, code int, data any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(data)
}

func corsMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Access-Control-Allow-Origin", "*")
		w.Header().Set("Access-Control-Allow-Headers", "Content-Type")
		w.Header().Set("Access-Control-Allow-Methods", "GET,POST,OPTIONS")
		if r.Method == http.MethodOptions {
			w.WriteHeader(http.StatusNoContent)
			return
		}
		next.ServeHTTP(w, r)
	})
}

func localIPv4() string {
	ifaces, err := net.Interfaces()
	if err != nil {
		return "127.0.0.1"
	}
	for _, iface := range ifaces {
		if iface.Flags&net.FlagUp == 0 || iface.Flags&net.FlagLoopback != 0 {
			continue
		}
		addrs, err := iface.Addrs()
		if err != nil {
			continue
		}
		for _, addr := range addrs {
			ipNet, ok := addr.(*net.IPNet)
			if !ok || ipNet.IP == nil {
				continue
			}
			ip := ipNet.IP.To4()
			if ip == nil {
				continue
			}
			return ip.String()
		}
	}
	return "127.0.0.1"
}

func publishHostForResponse(r *http.Request) string {
	if getPublicProxyEnabled() {
		override := getPublicHostOverride()
		if strings.TrimSpace(override) != "" {
			return strings.TrimSpace(override)
		}
	}
	if strings.TrimSpace(selectedPublishHost) != "" {
		return strings.TrimSpace(selectedPublishHost)
	}
	return responseHostFallback(r)
}

func setPublicHostOverride(host string, enabled bool) {
	publicHostMu.Lock()
	defer publicHostMu.Unlock()
	if enabled {
		publicHostOverride = host
		publicProxyEnabled = true
		log.Printf(">>> [PUBLIC-HOST][SET] enabled host=%s", host)
		return
	}
	publicHostOverride = ""
	publicProxyEnabled = false
	log.Printf(">>> [PUBLIC-HOST][SET] disabled, fallback to auto host select")
}

func getPublicHostOverride() string {
	publicHostMu.RLock()
	defer publicHostMu.RUnlock()
	return publicHostOverride
}

func getPublicProxyEnabled() bool {
	publicHostMu.RLock()
	defer publicHostMu.RUnlock()
	return publicProxyEnabled
}

func normalizePublicHost(raw string) string {
	s := strings.TrimSpace(raw)
	if s == "" {
		return ""
	}
	if strings.Contains(s, "://") {
		if idx := strings.Index(s, "://"); idx >= 0 {
			s = s[idx+3:]
		}
	}
	if idx := strings.IndexAny(s, "/?#"); idx >= 0 {
		s = s[:idx]
	}
	if h, _, err := net.SplitHostPort(s); err == nil && strings.TrimSpace(h) != "" {
		s = strings.TrimSpace(h)
	}
	if strings.HasPrefix(s, "[") && strings.HasSuffix(s, "]") {
		s = strings.TrimSuffix(strings.TrimPrefix(s, "["), "]")
	}
	if idx := strings.LastIndex(s, ":"); idx > 0 && strings.Count(s, ":") == 1 {
		s = s[:idx]
	}
	return strings.TrimSpace(s)
}

func responseHostFallback(r *http.Request) string {
	if runtime.GOOS == "linux" {
		if host := pickLinuxReachableHost(r); host != "" {
			log.Printf("[host-select] final selected host=%s (linux reachable strategy)", host)
			return host
		}
		log.Printf("[host-select] linux reachable strategy found no suitable host, fallback to generic strategy")
	}

	raw := strings.TrimSpace(r.Host)
	if forwarded := strings.TrimSpace(r.Header.Get("X-Forwarded-Host")); forwarded != "" {
		parts := strings.Split(forwarded, ",")
		if len(parts) > 0 && strings.TrimSpace(parts[0]) != "" {
			raw = strings.TrimSpace(parts[0])
		}
	}
	if raw == "" {
		return localIPv4()
	}
	if h, _, err := net.SplitHostPort(raw); err == nil && strings.TrimSpace(h) != "" {
		return strings.TrimSpace(h)
	}
	if strings.HasPrefix(raw, "[") && strings.HasSuffix(raw, "]") {
		return strings.TrimSuffix(strings.TrimPrefix(raw, "["), "]")
	}
	if idx := strings.LastIndex(raw, ":"); idx > 0 {
		return raw[:idx]
	}
	return raw
}

func initPublishHostAtStartup() string {
	if runtime.GOOS != "linux" {
		host := localIPv4()
		log.Printf("=== [HOST-SELECT][BOOT] os=%s host=%s (default localIPv4) ===", runtime.GOOS, host)
		return host
	}
	host := pickLinuxReachableHostAtStartup()
	if strings.TrimSpace(host) == "" {
		host = localIPv4()
	}
	log.Printf("============================================================")
	log.Printf(">>> [HOST-SELECT][BOOT][FINAL] publish host = %s", host)
	log.Printf(">>> [HOST-SELECT][BOOT][INFO ] gateway=%d rtmp=%d http=%d", gatewayPort, rtmpPort, httpPort)
	log.Printf("============================================================")
	return host
}

func pickLinuxReachableHostAtStartup() string {
	candidates := localIPv4Candidates()
	log.Printf("[host-select][boot] linux candidates=%v", candidates)
	if len(candidates) == 0 {
		log.Printf("[host-select][boot] no candidates")
		return ""
	}
	start := int(atomic.AddUint32(&ipRoundRobin, 1)-1) % len(candidates)
	log.Printf("[host-select][boot] round-robin start=%d", start)
	for i := 0; i < len(candidates); i++ {
		idx := (start + i) % len(candidates)
		host := candidates[idx]
		log.Printf("[host-select][boot] probe candidate=%s", host)
		if canReachMediaOnStartup(host) {
			log.Printf("*** [host-select][boot] selected=%s", host)
			return host
		}
		log.Printf("[host-select][boot] rejected=%s", host)
	}
	log.Printf("[host-select][boot] all candidates rejected")
	return ""
}

func canReachMediaOnStartup(host string) bool {
	// Startup phase happens before gateway/ZLM begin listening.
	// Probe bindability of candidate IP instead of probing service ports.
	if !canBindLocalIP(host, "boot-bind") {
		return false
	}
	return true
}

func canBindLocalIP(host string, name string) bool {
	addr := net.JoinHostPort(host, "0")
	log.Printf("[host-select] bind probe begin service=%s addr=%s", name, addr)
	ln, err := net.Listen("tcp", addr)
	if err != nil {
		log.Printf("[host-select] bind probe fail service=%s addr=%s err=%v", name, addr, err)
		return false
	}
	_ = ln.Close()
	log.Printf("[host-select] bind probe ok service=%s addr=%s", name, addr)
	return true
}

func pickLinuxReachableHost(r *http.Request) string {
	candidates := localIPv4Candidates()
	log.Printf("[host-select] linux candidates=%v", candidates)
	if len(candidates) == 0 {
		log.Printf("[host-select] no linux ipv4 candidates")
		return ""
	}

	clientIP := requestClientIP(r)
	if clientIP != nil {
		log.Printf("[host-select] client ip=%s", clientIP.String())
	} else {
		log.Printf("[host-select] client ip unavailable")
	}
	if clientIP != nil {
		if byRoute := routePreferredLocalIP(clientIP); byRoute != "" && isUsableIPv4(byRoute) {
			log.Printf("[host-select] route preferred local ip candidate=%s", byRoute)
			if canReachLocalService(byRoute) {
				log.Printf("[host-select] selected route preferred ip=%s", byRoute)
				return byRoute
			}
			log.Printf("[host-select] route preferred ip unreachable=%s", byRoute)
		}

		sameSubnet := make([]string, 0, len(candidates))
		for _, c := range candidates {
			if same24Subnet(clientIP.String(), c) {
				sameSubnet = append(sameSubnet, c)
			}
		}
		log.Printf("[host-select] same /24 subnet candidates=%v", sameSubnet)
		if host := pickRoundRobinReachable(sameSubnet); host != "" {
			log.Printf("[host-select] selected same-subnet host=%s", host)
			return host
		}
		log.Printf("[host-select] no same-subnet host passed reachability probe")
	}

	log.Printf("[host-select] fallback to all candidates round-robin probing")
	return pickRoundRobinReachable(candidates)
}

func pickRoundRobinReachable(candidates []string) string {
	if len(candidates) == 0 {
		log.Printf("[host-select] round-robin skipped, empty candidate list")
		return ""
	}
	start := int(atomic.AddUint32(&ipRoundRobin, 1)-1) % len(candidates)
	log.Printf("[host-select] round-robin start index=%d candidates=%v", start, candidates)
	for i := 0; i < len(candidates); i++ {
		idx := (start + i) % len(candidates)
		host := candidates[idx]
		log.Printf("[host-select] probing host=%s", host)
		if canReachLocalService(host) {
			log.Printf("[host-select] host probe passed=%s", host)
			return host
		}
		log.Printf("[host-select] host probe failed=%s", host)
	}
	log.Printf("[host-select] all host probes failed")
	return ""
}

func canReachLocalService(host string) bool {
	if !tcpReachable(host, gatewayPort, 300*time.Millisecond, "gateway") {
		return false
	}
	if rtmpPort > 0 && !tcpReachable(host, rtmpPort, 300*time.Millisecond, "rtmp") {
		return false
	}
	return true
}

func tcpReachable(host string, port int, timeout time.Duration, name string) bool {
	addr := net.JoinHostPort(host, strconv.Itoa(port))
	log.Printf("[host-select] tcp probe begin service=%s addr=%s timeout=%s", name, addr, timeout)
	conn, err := net.DialTimeout("tcp", addr, timeout)
	if err != nil {
		log.Printf("[host-select] tcp probe fail service=%s addr=%s err=%v", name, addr, err)
		return false
	}
	_ = conn.Close()
	log.Printf("[host-select] tcp probe ok service=%s addr=%s", name, addr)
	return true
}

func localIPv4Candidates() []string {
	ifaces, err := net.Interfaces()
	if err != nil {
		return nil
	}
	result := make([]string, 0, 4)
	seen := map[string]struct{}{}
	for _, iface := range ifaces {
		if iface.Flags&net.FlagUp == 0 || iface.Flags&net.FlagLoopback != 0 {
			continue
		}
		addrs, err := iface.Addrs()
		if err != nil {
			continue
		}
		for _, addr := range addrs {
			ipNet, ok := addr.(*net.IPNet)
			if !ok || ipNet.IP == nil {
				continue
			}
			ip := ipNet.IP.To4()
			if ip == nil {
				continue
			}
			s := ip.String()
			if !isUsableIPv4(s) {
				continue
			}
			if _, ok := seen[s]; ok {
				continue
			}
			seen[s] = struct{}{}
			result = append(result, s)
		}
	}
	return result
}

func isUsableIPv4(ip string) bool {
	if strings.TrimSpace(ip) == "" {
		return false
	}
	if strings.HasPrefix(ip, "127.") {
		return false
	}
	if strings.HasPrefix(ip, "169.254.") {
		return false
	}
	return true
}

func requestClientIP(r *http.Request) net.IP {
	if r == nil {
		return nil
	}
	if xff := strings.TrimSpace(r.Header.Get("X-Forwarded-For")); xff != "" {
		parts := strings.Split(xff, ",")
		if len(parts) > 0 {
			if ip := net.ParseIP(strings.TrimSpace(parts[0])); ip != nil {
				return ip.To4()
			}
		}
	}
	host, _, err := net.SplitHostPort(strings.TrimSpace(r.RemoteAddr))
	if err != nil {
		return nil
	}
	ip := net.ParseIP(host)
	if ip == nil {
		return nil
	}
	return ip.To4()
}

func routePreferredLocalIP(remote net.IP) string {
	if remote == nil {
		return ""
	}
	conn, err := net.DialTimeout("udp", net.JoinHostPort(remote.String(), "53"), 300*time.Millisecond)
	if err != nil {
		return ""
	}
	defer conn.Close()
	localAddr, ok := conn.LocalAddr().(*net.UDPAddr)
	if !ok || localAddr == nil || localAddr.IP == nil {
		return ""
	}
	ip := localAddr.IP.To4()
	if ip == nil {
		return ""
	}
	s := ip.String()
	if !isUsableIPv4(s) {
		return ""
	}
	return s
}

func same24Subnet(a, b string) bool {
	pa := net.ParseIP(strings.TrimSpace(a))
	pb := net.ParseIP(strings.TrimSpace(b))
	if pa == nil || pb == nil {
		return false
	}
	a4 := pa.To4()
	b4 := pb.To4()
	if a4 == nil || b4 == nil {
		return false
	}
	return a4[0] == b4[0] && a4[1] == b4[1] && a4[2] == b4[2]
}
