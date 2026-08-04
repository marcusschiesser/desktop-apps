package main

import (
	"context"
	"fmt"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

func TestParseRobotsLongestRuleWins(t *testing.T) {
	rules := parseRobots("User-agent: *\nDisallow: /private\nAllow: /private/public\n")
	if allowedByRobots(rules, "/private/file") {
		t.Fatal("private path should be blocked")
	}
	if !allowedByRobots(rules, "/private/public/page") {
		t.Fatal("more specific allow should win")
	}
}

func TestPermissionedSameOriginCrawlAndIssues(t *testing.T) {
	mux := http.NewServeMux()
	mux.HandleFunc("/robots.txt", func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprintln(w, "User-agent: *\nDisallow: /blocked")
	})
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprintln(w, `<title>Duplicate</title><meta name="description" content="same"><h1>Home</h1><a href="/two">Two</a><a href="/broken">Broken</a><a href="/blocked">Blocked</a><a rel="nofollow" href="/ignored">Ignored</a>`)
	})
	mux.HandleFunc("/two", func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprintln(w, `<title>Duplicate</title><meta name="description" content="same"><p>No h1</p>`)
	})
	mux.HandleFunc("/broken", func(w http.ResponseWriter, r *http.Request) {
		http.Error(w, "gone", http.StatusGone)
	})
	mux.HandleFunc("/blocked", func(w http.ResponseWriter, r *http.Request) { t.Error("robots-blocked URL was fetched") })
	mux.HandleFunc("/ignored", func(w http.ResponseWriter, r *http.Request) { t.Error("nofollow URL was fetched") })
	server := httptest.NewServer(mux)
	defer server.Close()

	audit, err := Crawl(context.Background(), CrawlConfig{
		StartURL:  server.URL,
		MaxPages:  10,
		Delay:     time.Millisecond,
		Client:    server.Client(),
		OutputDir: t.TempDir(),
	})
	if err != nil {
		t.Fatal(err)
	}
	if len(audit.Pages) != 3 {
		t.Fatalf("expected 3 pages, got %d", len(audit.Pages))
	}
	codes := map[string]int{}
	for _, issue := range audit.Issues {
		codes[issue.Code]++
	}
	for _, code := range []string{"broken-url", "duplicate-title", "duplicate-description", "missing-h1"} {
		if codes[code] == 0 {
			t.Errorf("expected issue %q", code)
		}
	}
}

func TestRejectsUnsupportedScheme(t *testing.T) {
	_, err := Crawl(context.Background(), CrawlConfig{StartURL: "file:///etc/passwd", MaxPages: 1})
	if err == nil {
		t.Fatal("expected unsupported scheme error")
	}
}
