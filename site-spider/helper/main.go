package main

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"time"
)

func main() {
	if len(os.Args) < 2 {
		fatal("usage: seo-spider-helper <crawl|open-latest|self-test>")
	}
	switch os.Args[1] {
	case "crawl":
		runCrawl()
	case "open-latest":
		if err := openLatest(); err != nil {
			fatal(err.Error())
		}
	case "self-test":
		if err := selfTest(); err != nil {
			fatal("self-test failed: " + err.Error())
		}
		fmt.Println("All SEO spider helper self-tests passed")
	default:
		fatal("unknown command: " + os.Args[1])
	}
}

func runCrawl() {
	if len(os.Args) != 5 || os.Args[4] != "--permission-acknowledged" {
		fatal("crawl requires: <url> <max-pages> --permission-acknowledged")
	}
	maxPages, err := strconv.Atoi(os.Args[3])
	if err != nil {
		fatal("max-pages must be a number")
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	_, err = Crawl(ctx, CrawlConfig{
		StartURL:  os.Args[2],
		MaxPages:  maxPages,
		Delay:     300 * time.Millisecond,
		OutputDir: filepath.Join("data", "reports"),
		Progress:  os.Stdout,
	})
	if err != nil {
		fatal(err.Error())
	}
}

func openLatest() error {
	pointer := filepath.Join("data", "reports", "latest.txt")
	body, err := os.ReadFile(pointer)
	if err != nil {
		return fmt.Errorf("no completed report found: %w", err)
	}
	path := strings.TrimSpace(string(body))
	if path == "" {
		return errors.New("latest report pointer is empty")
	}
	absolute, err := filepath.Abs(path)
	if err != nil {
		return err
	}
	var cmd *exec.Cmd
	switch runtime.GOOS {
	case "darwin":
		cmd = exec.Command("open", absolute)
	case "windows":
		cmd = exec.Command("rundll32", "url.dll,FileProtocolHandler", absolute)
	default:
		cmd = exec.Command("xdg-open", absolute)
	}
	if err := cmd.Start(); err != nil {
		return fmt.Errorf("open report: %w", err)
	}
	fmt.Println(absolute)
	return nil
}

func selfTest() error {
	mux := http.NewServeMux()
	mux.HandleFunc("/robots.txt", func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprintln(w, "User-agent: *\nDisallow: /private")
	})
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprintln(w, `<!doctype html><html><head><title>Home</title><meta name="description" content="Example home"><link rel="canonical" href="/"><script type="application/ld+json">{}</script></head><body><h1>Home</h1><a href="/about">About</a><a href="/missing">Missing</a><a rel="nofollow" href="/ignored">Ignored</a><img src="hero.png"></body></html>`)
	})
	mux.HandleFunc("/about", func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprintln(w, `<!doctype html><html><head><title>Home</title></head><body><p>About page without a heading.</p></body></html>`)
	})
	mux.HandleFunc("/missing", func(w http.ResponseWriter, r *http.Request) {
		http.NotFound(w, r)
	})
	mux.HandleFunc("/ignored", func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprintln(w, `<title>Should not be crawled</title>`)
	})
	server := httptest.NewServer(mux)
	defer server.Close()

	tmp, err := os.MkdirTemp("", "seo-spider-self-test-")
	if err != nil {
		return err
	}
	defer os.RemoveAll(tmp)
	audit, err := Crawl(context.Background(), CrawlConfig{
		StartURL:  server.URL,
		MaxPages:  10,
		Delay:     time.Millisecond,
		OutputDir: tmp,
		Client:    server.Client(),
		Progress:  os.Stdout,
	})
	if err != nil {
		return err
	}
	if len(audit.Pages) != 3 {
		return fmt.Errorf("expected 3 crawled pages, got %d", len(audit.Pages))
	}
	if len(audit.Issues) < 4 {
		return fmt.Errorf("expected at least 4 issues, got %d", len(audit.Issues))
	}
	for _, path := range []string{audit.CSVPath, audit.HTMLPath, filepath.Join(tmp, "latest.txt")} {
		info, statErr := os.Stat(path)
		if statErr != nil || info.Size() == 0 {
			return fmt.Errorf("expected non-empty output %s", path)
		}
	}
	return nil
}

func fatal(message string) {
	fmt.Fprintln(os.Stderr, message)
	os.Exit(1)
}
