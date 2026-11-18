package download

import (
	"crypto/tls"
	"fmt"
	"net/http"
	"net/http/httptrace"
	"sync"
	"time"
)

// RequestDiagnostics records HTTP transport phases without retaining or
// printing request URLs, headers, credentials, or response bodies.
type RequestDiagnostics struct {
	mu sync.Mutex

	started      time.Time
	dnsStarted   time.Time
	dnsDuration  time.Duration
	connectStart time.Time
	connectTime  time.Duration
	tlsStarted   time.Time
	tlsDuration  time.Duration
	gotConn      time.Time
	firstByte    time.Time
	wroteRequest time.Time
	reused       bool
	wasIdle      bool
}

func NewRequestDiagnostics() *RequestDiagnostics {
	return &RequestDiagnostics{started: time.Now()}
}

// TraceRequest attaches transport tracing to req and returns the diagnostics
// object that can be summarized after the response body has been consumed.
func TraceRequest(req *http.Request) (*http.Request, *RequestDiagnostics) {
	d := NewRequestDiagnostics()
	return req.WithContext(httptrace.WithClientTrace(req.Context(), d.ClientTrace())), d
}

func (d *RequestDiagnostics) ClientTrace() *httptrace.ClientTrace {
	return &httptrace.ClientTrace{
		DNSStart: func(httptrace.DNSStartInfo) {
			d.mu.Lock()
			d.dnsStarted = time.Now()
			d.mu.Unlock()
		},
		DNSDone: func(httptrace.DNSDoneInfo) {
			d.mu.Lock()
			if !d.dnsStarted.IsZero() {
				d.dnsDuration = time.Since(d.dnsStarted)
			}
			d.mu.Unlock()
		},
		ConnectStart: func(_, _ string) {
			d.mu.Lock()
			d.connectStart = time.Now()
			d.mu.Unlock()
		},
		ConnectDone: func(_, _ string, _ error) {
			d.mu.Lock()
			if !d.connectStart.IsZero() {
				d.connectTime += time.Since(d.connectStart)
			}
			d.mu.Unlock()
		},
		TLSHandshakeStart: func() {
			d.mu.Lock()
			d.tlsStarted = time.Now()
			d.mu.Unlock()
		},
		TLSHandshakeDone: func(_ tls.ConnectionState, _ error) {
			d.mu.Lock()
			if !d.tlsStarted.IsZero() {
				d.tlsDuration = time.Since(d.tlsStarted)
			}
			d.mu.Unlock()
		},
		GotConn: func(info httptrace.GotConnInfo) {
			d.mu.Lock()
			d.gotConn = time.Now()
			d.reused = info.Reused
			d.wasIdle = info.WasIdle
			d.mu.Unlock()
		},
		WroteRequest: func(httptrace.WroteRequestInfo) {
			d.mu.Lock()
			d.wroteRequest = time.Now()
			d.mu.Unlock()
		},
		GotFirstResponseByte: func() {
			d.mu.Lock()
			d.firstByte = time.Now()
			d.mu.Unlock()
		},
	}
}

func (d *RequestDiagnostics) HeaderLatency() string {
	d.mu.Lock()
	defer d.mu.Unlock()
	if d.firstByte.IsZero() {
		return "unknown"
	}
	return d.firstByte.Sub(d.started).Round(time.Millisecond).String()
}

func (d *RequestDiagnostics) Summary(total time.Duration) string {
	d.mu.Lock()
	defer d.mu.Unlock()
	firstByte := "n/a"
	if !d.firstByte.IsZero() {
		firstByte = d.firstByte.Sub(d.started).Round(time.Millisecond).String()
	}
	requestWrite := "n/a"
	if !d.gotConn.IsZero() && !d.wroteRequest.IsZero() {
		requestWrite = d.wroteRequest.Sub(d.gotConn).Round(time.Millisecond).String()
	}
	ttfbAfterWrite := "n/a"
	if !d.wroteRequest.IsZero() && !d.firstByte.IsZero() {
		ttfbAfterWrite = d.firstByte.Sub(d.wroteRequest).Round(time.Millisecond).String()
	}
	return fmt.Sprintf("total=%s dns=%s connect=%s tls=%s request-write=%s wait-first-byte=%s first-byte=%s reused-connection=%t idle-reused=%t",
		total.Round(time.Millisecond),
		optionalDuration(d.dnsDuration),
		optionalDuration(d.connectTime),
		optionalDuration(d.tlsDuration),
		requestWrite,
		ttfbAfterWrite,
		firstByte,
		d.reused,
		d.wasIdle,
	)
}

func optionalDuration(d time.Duration) string {
	if d == 0 {
		return "n/a"
	}
	return d.Round(time.Millisecond).String()
}
