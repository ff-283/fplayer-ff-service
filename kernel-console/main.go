package main

import (
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"runtime"
	"strings"
	"syscall"
	"time"
)

type runtimeInfo struct {
	StartedAt string `json:"startedAt"`
	Gateway   struct {
		URL  string `json:"url"`
		Host string `json:"host"`
		Port int    `json:"port"`
	} `json:"gateway"`
	ZLM struct {
		RTMPPort  int `json:"rtmpPort"`
		HTTPPort  int `json:"httpPort"`
		HTTPSPort int `json:"httpsPort"`
	} `json:"zlm"`
	Endpoints struct {
		PublishRtmp string `json:"publishRtmp"`
		PlayHTTPFlv string `json:"playHttpFlv"`
	} `json:"endpoints"`
}

type userLinks struct {
	lanIP            string
	gatewayURL       string
	healthURL        string
	startAPI         string
	statusAPIExample string
	stopAPIExample   string
	rtmpPublishLocal string
	rtmpPublishLAN   string
	httpFlvPlayLocal string
	httpFlvPlayLAN   string
}

type serviceLayout struct {
	RootDir       string
	RunDir        string
	LogDir        string
	ZLMExe        string
	ZLMCfg        string
	ZLMRuntimeCfg string
	GatewayExe    string
	GatewayDir    string
}

type childProcs struct {
	zlm     *exec.Cmd
	gateway *exec.Cmd
	zlmOut  io.Closer
	zlmErr  io.Closer
	gwOut   io.Closer
	gwErr   io.Closer
}

var publicHostFlag = flag.String("public-host", "", "Public host/IP used by gateway to generate play URLs")

func main() {
	flag.Parse()
	layout, err := detectLayout()
	if err != nil {
		fmt.Printf("Layout error: %v\n", err)
		waitExitPrompt()
		os.Exit(1)
	}

	fmt.Println("==================================================")
	fmt.Println(" FPlayer FF Service Kernel Console")
	fmt.Println("==================================================")
	fmt.Println("Starting service core (ZLM + gateway) ...")

	procs, runtime, err := startCore(layout)
	if err != nil {
		fmt.Printf("Start failed: %v\n", err)
		waitExitPrompt()
		os.Exit(1)
	}

	printRuntimeSummary(runtime)
	fmt.Println("")
	fmt.Println("Service is running. Press Ctrl+C to stop.")

	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, os.Interrupt, syscall.SIGTERM)
	<-sigCh

	fmt.Println("")
	fmt.Println("Stopping service core ...")
	stopCore(layout, procs)
	fmt.Println("Service stopped.")
}

func detectLayout() (serviceLayout, error) {
	layout := serviceLayout{}
	exePath, err := os.Executable()
	if err != nil {
		return layout, err
	}
	candidates := []string{
		filepath.Dir(exePath),
		filepath.Join(filepath.Dir(exePath), ".."),
		filepath.Join(filepath.Dir(exePath), "..", ".."),
	}
	for _, c := range candidates {
		root := filepath.Clean(c)
		if isServiceRoot(root) {
			isWin := runtime.GOOS == "windows"
			zlmBase := filepath.Join(root, "3rd", "zlm")
			zlmDir := filepath.Join(zlmBase, "windows")
			if !isWin {
				if _, err := os.Stat(filepath.Join(zlmBase, "linux")); err == nil {
					zlmDir = filepath.Join(zlmBase, "linux")
				} else if _, err := os.Stat(filepath.Join(zlmBase, "Linux")); err == nil {
					zlmDir = filepath.Join(zlmBase, "Linux")
				}
			}
			gatewayName := "gateway"
			zlmExeName := "MediaServer"
			if isWin {
				gatewayName = "gateway.exe"
				zlmExeName = "MediaServer.exe"
			}

			layout.RootDir = root
			layout.RunDir = filepath.Join(root, "run")
			layout.LogDir = filepath.Join(root, "logs")
			layout.ZLMExe = filepath.Join(zlmDir, zlmExeName)
			layout.ZLMCfg = filepath.Join(zlmDir, "config.ini")
			layout.ZLMRuntimeCfg = filepath.Join(layout.RunDir, "zlm.runtime.ini")
			layout.GatewayExe = filepath.Join(root, "gateway", "bin", gatewayName)
			layout.GatewayDir = filepath.Join(root, "gateway")
			return layout, nil
		}
	}
	return layout, errors.New("service root not found near executable")
}

func isServiceRoot(root string) bool {
	isWin := runtime.GOOS == "windows"
	gatewayName := "gateway"
	zlmCandidates := []string{
		filepath.Join(root, "3rd", "zlm", "linux", "MediaServer"),
		filepath.Join(root, "3rd", "zlm", "Linux", "MediaServer"),
	}
	if isWin {
		gatewayName = "gateway.exe"
		zlmCandidates = []string{filepath.Join(root, "3rd", "zlm", "windows", "MediaServer.exe")}
	}

	zlmOK := false
	for _, p := range zlmCandidates {
		if _, err := os.Stat(p); err == nil {
			zlmOK = true
			break
		}
	}
	if !zlmOK {
		return false
	}

	checks := []string{
		filepath.Join(root, "gateway", "bin", gatewayName),
		filepath.Join(root, "scripts"),
	}
	for _, p := range checks {
		if _, err := os.Stat(p); err != nil {
			return false
		}
	}
	return true
}

func ensureDir(p string) error {
	return os.MkdirAll(p, 0o755)
}

func getFreePort(preferred int) int {
	try := func(p int) int {
		ln, err := net.Listen("tcp", fmt.Sprintf("127.0.0.1:%d", p))
		if err != nil {
			return 0
		}
		defer ln.Close()
		addr, ok := ln.Addr().(*net.TCPAddr)
		if !ok {
			return 0
		}
		return addr.Port
	}
	if preferred > 0 {
		if p := try(preferred); p > 0 {
			return p
		}
	}
	return try(0)
}

func patchConfig(templatePath, targetPath string, rtmpPort, httpPort, httpsPort int, rtspPort int) error {
	raw, err := os.ReadFile(templatePath)
	if err != nil {
		return err
	}
	lines := strings.Split(strings.ReplaceAll(string(raw), "\r\n", "\n"), "\n")
	replace := func(section, key string, value int) {
		inSection := false
		for i, line := range lines {
			l := strings.TrimSpace(line)
			if strings.HasPrefix(l, "[") && strings.HasSuffix(l, "]") {
				inSection = strings.Trim(l, "[]") == section
				continue
			}
			if inSection && strings.HasPrefix(strings.TrimSpace(line), key+"=") {
				lines[i] = fmt.Sprintf("%s=%d", key, value)
				return
			}
		}
	}
	replace("http", "port", httpPort)
	replace("http", "sslport", httpsPort)
	replace("rtmp", "port", rtmpPort)
	if rtspPort > 0 {
		replace("rtsp", "port", rtspPort)
	}
	return os.WriteFile(targetPath, []byte(strings.Join(lines, "\n")), 0o644)
}

func openLogWriters(logDir, base string) (io.WriteCloser, io.WriteCloser, error) {
	outPath := filepath.Join(logDir, base+".log")
	errPath := filepath.Join(logDir, base+".err.log")
	outFile, err := os.OpenFile(outPath, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o644)
	if err != nil {
		return nil, nil, err
	}
	errFile, err := os.OpenFile(errPath, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o644)
	if err != nil {
		_ = outFile.Close()
		return nil, nil, err
	}
	return outFile, errFile, nil
}

func waitGatewayHealthy(port int, timeout time.Duration) bool {
	deadline := time.Now().Add(timeout)
	url := fmt.Sprintf("http://127.0.0.1:%d/healthz", port)
	for time.Now().Before(deadline) {
		resp, err := http.Get(url)
		if err == nil && resp != nil {
			_ = resp.Body.Close()
			if resp.StatusCode == 200 {
				return true
			}
		}
		time.Sleep(200 * time.Millisecond)
	}
	return false
}

func startCore(layout serviceLayout) (childProcs, runtimeInfo, error) {
	var procs childProcs
	var info runtimeInfo

	if err := ensureDir(layout.RunDir); err != nil {
		return procs, info, err
	}
	if err := ensureDir(layout.LogDir); err != nil {
		return procs, info, err
	}

	rtmpPort := getFreePort(1935)
	httpPort := getFreePort(8080)
	httpsPort := getFreePort(8443)
	rtspPort := 0
	if runtime.GOOS == "linux" {
		rtspPort = getFreePort(8554)
	}
	if rtmpPort == 0 || httpPort == 0 || httpsPort == 0 {
		return procs, info, errors.New("failed to allocate dynamic ports")
	}
	fmt.Printf("Selected ports => rtmp:%d http:%d https:%d", rtmpPort, httpPort, httpsPort)
	if rtspPort > 0 {
		fmt.Printf(" rtsp:%d", rtspPort)
	}
	fmt.Println("")
	if err := patchConfig(layout.ZLMCfg, layout.ZLMRuntimeCfg, rtmpPort, httpPort, httpsPort, rtspPort); err != nil {
		return procs, info, err
	}
	fmt.Printf("Generated runtime config: %s\n", layout.ZLMRuntimeCfg)

	zlmOut, zlmErr, err := openLogWriters(layout.LogDir, "zlm")
	if err != nil {
		return procs, info, err
	}
	zlmCmd := exec.Command(layout.ZLMExe, "-c", layout.ZLMRuntimeCfg)
	zlmCmd.Dir = filepath.Dir(layout.ZLMExe)
	zlmCmd.Stdout = zlmOut
	zlmCmd.Stderr = zlmErr
	if err := zlmCmd.Start(); err != nil {
		_ = zlmOut.Close()
		_ = zlmErr.Close()
		return procs, info, err
	}
	procs.zlm = zlmCmd
	procs.zlmOut = zlmOut
	procs.zlmErr = zlmErr
	fmt.Printf("ZLM started (pid=%d)\n", zlmCmd.Process.Pid)

	var gatewayCmd *exec.Cmd
	gatewayPort := 0
	var gwOut io.Closer
	var gwErr io.Closer
	for i := 0; i < 8; i++ {
		preferred := 0
		if i == 0 {
			preferred = 9000
		}
		candidate := getFreePort(preferred)
		if candidate == 0 {
			continue
		}
		fmt.Printf("Trying gateway port: %d\n", candidate)
		tmpOut, tmpErr, e := openLogWriters(layout.LogDir, "gateway")
		if e != nil {
			continue
		}
		cmd := exec.Command(layout.GatewayExe)
		cmd.Dir = layout.GatewayDir
		cmd.Stdout = tmpOut
		cmd.Stderr = tmpErr
		cmd.Env = append(os.Environ(),
			fmt.Sprintf("ZLM_RTMP_PORT=%d", rtmpPort),
			fmt.Sprintf("ZLM_HTTP_PORT=%d", httpPort),
			fmt.Sprintf("SERVICE_GATEWAY_PORT=%d", candidate),
			fmt.Sprintf("SERVICE_LOG_DIR=%s", layout.LogDir),
		)
		if host := strings.TrimSpace(*publicHostFlag); host != "" {
			cmd.Env = append(cmd.Env, fmt.Sprintf("SERVICE_PUBLIC_HOST=%s", host))
		}
		if e = cmd.Start(); e != nil {
			_ = tmpOut.Close()
			_ = tmpErr.Close()
			continue
		}
		if waitGatewayHealthy(candidate, 5*time.Second) {
			gatewayCmd = cmd
			gatewayPort = candidate
			gwOut = tmpOut
			gwErr = tmpErr
			fmt.Printf("Gateway started (pid=%d, port=%d)\n", cmd.Process.Pid, candidate)
			break
		}
		_ = cmd.Process.Kill()
		_, _ = cmd.Process.Wait()
		_ = tmpOut.Close()
		_ = tmpErr.Close()
		fmt.Printf("Gateway health check failed on port %d, retrying...\n", candidate)
	}
	if gatewayCmd == nil || gatewayPort == 0 {
		stopCore(layout, procs)
		return procs, info, errors.New("gateway failed to start on available ports")
	}
	procs.gateway = gatewayCmd
	procs.gwOut = gwOut
	procs.gwErr = gwErr

	info.StartedAt = time.Now().Format("2006-01-02T15:04:05")
	info.Gateway.Host = getLanIPv4()
	info.Gateway.Port = gatewayPort
	info.Gateway.URL = fmt.Sprintf("http://%s:%d", info.Gateway.Host, gatewayPort)
	info.ZLM.RTMPPort = rtmpPort
	info.ZLM.HTTPPort = httpPort
	info.ZLM.HTTPSPort = httpsPort
	info.Endpoints.PublishRtmp = fmt.Sprintf("rtmp://127.0.0.1:%d/live/stream001", rtmpPort)
	info.Endpoints.PlayHTTPFlv = fmt.Sprintf("http://127.0.0.1:%d/live/stream001.flv", httpPort)

	if err := writeRuntime(layout, info); err != nil {
		stopCore(layout, procs)
		return childProcs{}, runtimeInfo{}, err
	}
	fmt.Printf("Runtime file written: %s\n", filepath.Join(layout.RunDir, "runtime.json"))
	return procs, info, nil
}

func writeRuntime(layout serviceLayout, info runtimeInfo) error {
	raw, err := json.MarshalIndent(info, "", "  ")
	if err != nil {
		return err
	}
	runtimePath := filepath.Join(layout.RunDir, "runtime.json")
	return os.WriteFile(runtimePath, raw, 0o644)
}

func stopCore(layout serviceLayout, procs childProcs) {
	stopOne := func(name string, cmd *exec.Cmd) {
		if cmd == nil || cmd.Process == nil {
			return
		}
		_ = cmd.Process.Signal(os.Interrupt)
		done := make(chan struct{}, 1)
		go func() {
			_, _ = cmd.Process.Wait()
			done <- struct{}{}
		}()
		select {
		case <-done:
			fmt.Printf("%s stopped gracefully.\n", name)
		case <-time.After(1500 * time.Millisecond):
			fmt.Printf("%s still running, force killing...\n", name)
			_ = cmd.Process.Kill()
			_, _ = cmd.Process.Wait()
		}
	}
	stopOne("gateway", procs.gateway)
	stopOne("zlm", procs.zlm)
	if procs.gwOut != nil {
		_ = procs.gwOut.Close()
	}
	if procs.gwErr != nil {
		_ = procs.gwErr.Close()
	}
	if procs.zlmOut != nil {
		_ = procs.zlmOut.Close()
	}
	if procs.zlmErr != nil {
		_ = procs.zlmErr.Close()
	}
	_ = os.Remove(filepath.Join(layout.RunDir, "runtime.json"))
}

func printRuntimeSummary(info runtimeInfo) {
	fmt.Println("")
	fmt.Println("Runtime (copy-friendly):")
	links := buildUserLinks(info)
	printAlignedPairs([][2]string{
		{"Gateway URL", links.gatewayURL},
		{"Health Check", links.healthURL},
		{"Start API", links.startAPI},
		{"Status API", links.statusAPIExample},
		{"Stop API", links.stopAPIExample},
		{"RTMP Publish (Local)", links.rtmpPublishLocal},
		{"RTMP Publish (LAN)", links.rtmpPublishLAN},
		{"HTTP-FLV Play (Local)", links.httpFlvPlayLocal},
		{"HTTP-FLV Play (LAN)", links.httpFlvPlayLAN},
	})
}

func waitExitPrompt() {
	fmt.Println("")
	fmt.Println("Press Enter to exit.")
	_, _ = fmt.Scanln()
}

func buildUserLinks(info runtimeInfo) userLinks {
	lanIP := info.Gateway.Host
	if lanIP == "" {
		lanIP = "127.0.0.1"
	}
	gwPort := info.Gateway.Port
	rtmpPort := info.ZLM.RTMPPort
	httpPort := info.ZLM.HTTPPort
	return userLinks{
		lanIP:            lanIP,
		gatewayURL:       fmt.Sprintf("http://%s:%d", lanIP, gwPort),
		healthURL:        fmt.Sprintf("http://%s:%d/healthz", lanIP, gwPort),
		startAPI:         fmt.Sprintf("http://%s:%d/api/v1/streams/start", lanIP, gwPort),
		statusAPIExample: fmt.Sprintf("http://%s:%d/api/v1/streams/<stream-id>/status", lanIP, gwPort),
		stopAPIExample:   fmt.Sprintf("http://%s:%d/api/v1/streams/<stream-id>/stop", lanIP, gwPort),
		rtmpPublishLocal: fmt.Sprintf("rtmp://127.0.0.1:%d/live/stream001", rtmpPort),
		rtmpPublishLAN:   fmt.Sprintf("rtmp://%s:%d/live/stream001", lanIP, rtmpPort),
		httpFlvPlayLocal: fmt.Sprintf("http://127.0.0.1:%d/live/stream001.flv", httpPort),
		httpFlvPlayLAN:   fmt.Sprintf("http://%s:%d/live/stream001.flv", lanIP, httpPort),
	}
}

func printAlignedPairs(pairs [][2]string) {
	maxLabelLen := 0
	for _, p := range pairs {
		if len(p[0]) > maxLabelLen {
			maxLabelLen = len(p[0])
		}
	}
	for _, p := range pairs {
		fmt.Printf("  %-*s : %s\n", maxLabelLen, p[0], p[1])
	}
}

func getLanIPv4() string {
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
			var ip net.IP
			switch v := addr.(type) {
			case *net.IPNet:
				ip = v.IP
			case *net.IPAddr:
				ip = v.IP
			}
			if ip == nil {
				continue
			}
			v4 := ip.To4()
			if v4 == nil {
				continue
			}
			if v4.IsLoopback() || strings.HasPrefix(v4.String(), "169.254.") {
				continue
			}
			return v4.String()
		}
	}
	return "127.0.0.1"
}
