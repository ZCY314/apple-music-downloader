package download

import (
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestTraceRequestCapturesHTTPPhases(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = io.WriteString(w, "ok")
	}))
	defer server.Close()

	original, err := http.NewRequest(http.MethodGet, server.URL, nil)
	if err != nil {
		t.Fatal(err)
	}
	req, diagnostics := TraceRequest(original)
	started := time.Now()
	resp, err := server.Client().Do(req)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := io.Copy(io.Discard, resp.Body); err != nil {
		t.Fatal(err)
	}
	_ = resp.Body.Close()

	summary := diagnostics.Summary(time.Since(started))
	for _, expected := range []string{"total=", "first-byte=", "reused-connection="} {
		if !strings.Contains(summary, expected) {
			t.Errorf("summary %q does not contain %q", summary, expected)
		}
	}
}
