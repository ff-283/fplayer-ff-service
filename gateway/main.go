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
	"strconv"
	"strings"
	"sync"
	"time"
)

type streamStatus string

const (
	statusRunning streamStatus = "running"
	statusStopped streamStatus = "stopped"
)

type streamRecord struct {
	ID            string                 `json:"id"`
	App           string                 `json:"app"`
	Stream        string                 `json:"stream"`
	ServiceMode   string                 `json:"serviceMode"`
	PublisherMeta map[string]any         `json:"publisherMeta,omitempty"`
	SourceMeta    map[string]any         `json:"sourceMeta,omitempty"`
	CreatedAt     time.Time              `json:"createdAt"`
	Status        streamStatus           `json:"status"`
	PlayURLs      map[string]string      `json:"playUrls"`
}

type startRequest struct {
	App           string         `json:"app"`
	Stream        string         `json:"stream"`
	ServiceMode   string         `json:"serviceMode"`
	PublisherMeta map[string]any `json:"publisherMeta"`
	SourceMeta    map[string]any `json:"sourceMeta"`
}

type startResponse struct {
	ID          string `json:"id"`
	App         string `json:"app"`
	Stream      string `json:"stream"`
	ServiceMode string `json:"serviceMode"`
	PublishRTMP string `json:"publishRtmp"`
	PlayHTTPFLV string `json:"playHttpFlv"`
	PlayHLS     string `json:"playHls"`
	PlayURLs    map[string]string `json:"playUrls"`
}

type statusResponse struct {
	ID          string       `json:"id"`
	App         string       `json:"app"`
	Stream      string       `json:"stream"`
	ServiceMode string       `json:"serviceMode"`
	Status      streamStatus `json:"status"`
	PublishRTMP string      `json:"publishRtmp"`
	PlayHTTPFLV string      `json:"playHttpFlv"`
	PlayHLS     string      `json:"playHls"`
	PlayURLs    map[string]string `json:"playUrls"`
	PublisherMeta map[string]any `json:"publisherMeta,omitempty"`
	SourceMeta map[string]any `json:"sourceMeta,omitempty"`
}

var (
	mu      sync.RWMutex
	streams = map[string]*streamRecord{}
	rtmpPort    = getEnvInt("ZLM_RTMP_PORT", 1935)
	httpPort    = getEnvInt("ZLM_HTTP_PORT", 8080)
	gatewayPort = getEnvInt("SERVICE_GATEWAY_PORT", 9000)
)

func main() {
	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", healthzHandler)
	mux.HandleFunc("/api/v1/debug/logs", logsHandler)
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

	host := localIPv4()
	rec.PlayURLs = buildPlayURLs(host, rec.App, rec.Stream, rec.ServiceMode)

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
	host := localIPv4()
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

	host := localIPv4()
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
