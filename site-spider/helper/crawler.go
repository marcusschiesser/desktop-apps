package main

import (
	"bufio"
	"context"
	"encoding/csv"
	"fmt"
	"html"
	"io"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"
)

type CrawlConfig struct {
	StartURL  string
	MaxPages  int
	Delay     time.Duration
	OutputDir string
	Client    *http.Client
	Progress  io.Writer
}

type Page struct {
	URL               string
	FinalURL          string
	Status            int
	ContentType       string
	Title             string
	Description       string
	H1Count           int
	Canonical         string
	Robots            string
	NoIndex           bool
	NoFollow          bool
	InternalLinks     int
	ExternalLinks     int
	Images            int
	ImagesMissingAlt  int
	StructuredData    int
	WordCount         int
	Redirects         int
	ResponseTimeMS    int64
	FetchError        string
	DiscoveredFromURL string
}

type Issue struct {
	Severity string
	Code     string
	URL      string
	Evidence string
	Fix      string
}

type Audit struct {
	StartURL  string
	StartedAt time.Time
	Pages     []Page
	Issues    []Issue
	ReportDir string
	CSVPath   string
	HTMLPath  string
}

type linkRef struct {
	URL      string
	NoFollow bool
}

type robotRules struct {
	Allow    []string
	Disallow []string
}

var (
	titleRE       = regexp.MustCompile(`(?is)<title\b[^>]*>(.*?)</title>`)
	h1RE          = regexp.MustCompile(`(?is)<h1\b[^>]*>.*?</h1>`)
	metaRE        = regexp.MustCompile(`(?is)<meta\b[^>]*>`)
	linkTagRE     = regexp.MustCompile(`(?is)<a\b[^>]*>`)
	canonicalRE   = regexp.MustCompile(`(?is)<link\b[^>]*rel\s*=\s*["'][^"']*canonical[^"']*["'][^>]*>`)
	imgRE         = regexp.MustCompile(`(?is)<img\b[^>]*>`)
	jsonLDRE      = regexp.MustCompile(`(?is)<script\b[^>]*type\s*=\s*["']application/ld\+json["'][^>]*>`)
	tagRE         = regexp.MustCompile(`(?is)<[^>]+>`)
	scriptStyleRE = regexp.MustCompile(`(?is)<script\b[^>]*>.*?</script\s*>|<style\b[^>]*>.*?</style\s*>|<noscript\b[^>]*>.*?</noscript\s*>`)
	spaceRE       = regexp.MustCompile(`\s+`)
	attrRE        = regexp.MustCompile(`(?is)([a-zA-Z_:][-a-zA-Z0-9_:.]*)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))`)
)

func Crawl(ctx context.Context, cfg CrawlConfig) (*Audit, error) {
	if cfg.MaxPages < 1 || cfg.MaxPages > 5000 {
		return nil, fmt.Errorf("URL cap must be between 1 and 5000")
	}
	start, err := normalizeStartURL(cfg.StartURL)
	if err != nil {
		return nil, err
	}
	if cfg.Delay <= 0 {
		cfg.Delay = 250 * time.Millisecond
	}
	if cfg.OutputDir == "" {
		cfg.OutputDir = filepath.Join("data", "reports")
	}
	if cfg.Progress == nil {
		cfg.Progress = io.Discard
	}
	client := cfg.Client
	if client == nil {
		client = &http.Client{Timeout: 20 * time.Second}
	}
	client.CheckRedirect = func(req *http.Request, via []*http.Request) error {
		if len(via) >= 10 {
			return fmt.Errorf("stopped after 10 redirects")
		}
		if !sameOrigin(start, req.URL) {
			return http.ErrUseLastResponse
		}
		return nil
	}

	rules := fetchRobots(ctx, client, start, cfg.Progress)
	queue := []linkRef{{URL: start.String()}}
	queued := map[string]bool{start.String(): true}
	seen := map[string]bool{}
	pages := make([]Page, 0, cfg.MaxPages)

	for len(queue) > 0 && len(pages) < cfg.MaxPages {
		select {
		case <-ctx.Done():
			return nil, ctx.Err()
		default:
		}
		current := queue[0]
		queue = queue[1:]
		if seen[current.URL] {
			continue
		}
		seen[current.URL] = true
		u, parseErr := url.Parse(current.URL)
		if parseErr != nil || !allowedByRobots(rules, u.EscapedPath()) {
			continue
		}
		if len(pages) > 0 {
			timer := time.NewTimer(cfg.Delay)
			select {
			case <-ctx.Done():
				timer.Stop()
				return nil, ctx.Err()
			case <-timer.C:
			}
		}
		fmt.Fprintf(cfg.Progress, "Crawling %d/%d · %s\n", len(pages)+1, cfg.MaxPages, current.URL)
		page, links := fetchPage(ctx, client, start, current.URL)
		pages = append(pages, page)
		if page.FetchError != "" || page.NoFollow {
			continue
		}
		for _, link := range links {
			if link.NoFollow {
				continue
			}
			normalized, ok := normalizeDiscovered(start, page.FinalURL, link.URL)
			if !ok || queued[normalized] || seen[normalized] {
				continue
			}
			queued[normalized] = true
			queue = append(queue, linkRef{URL: normalized})
		}
	}

	audit := &Audit{StartURL: start.String(), StartedAt: time.Now().UTC(), Pages: pages}
	audit.Issues = detectIssues(pages)
	if err := writeAudit(audit, cfg.OutputDir); err != nil {
		return nil, err
	}
	fmt.Fprintf(cfg.Progress, "Complete · %d pages · %d issues · %s\n", len(audit.Pages), len(audit.Issues), audit.HTMLPath)
	return audit, nil
}

func normalizeStartURL(raw string) (*url.URL, error) {
	raw = strings.TrimSpace(raw)
	u, err := url.Parse(raw)
	if err != nil {
		return nil, fmt.Errorf("invalid URL: %w", err)
	}
	if u.Scheme != "http" && u.Scheme != "https" {
		return nil, fmt.Errorf("URL must use http or https")
	}
	if u.Hostname() == "" {
		return nil, fmt.Errorf("URL must include a hostname")
	}
	u.Fragment = ""
	u.RawFragment = ""
	if u.Path == "" {
		u.Path = "/"
	}
	return u, nil
}

func sameOrigin(root, candidate *url.URL) bool {
	return strings.EqualFold(root.Scheme, candidate.Scheme) && strings.EqualFold(root.Host, candidate.Host)
}

func normalizeDiscovered(root *url.URL, baseRaw, href string) (string, bool) {
	href = strings.TrimSpace(html.UnescapeString(href))
	if href == "" || strings.HasPrefix(href, "#") || strings.HasPrefix(strings.ToLower(href), "mailto:") || strings.HasPrefix(strings.ToLower(href), "tel:") || strings.HasPrefix(strings.ToLower(href), "javascript:") {
		return "", false
	}
	base, err := url.Parse(baseRaw)
	if err != nil {
		return "", false
	}
	rel, err := url.Parse(href)
	if err != nil {
		return "", false
	}
	u := base.ResolveReference(rel)
	u.Fragment = ""
	u.RawFragment = ""
	if u.Scheme != "http" && u.Scheme != "https" {
		return "", false
	}
	if !sameOrigin(root, u) {
		return "", false
	}
	if u.Path == "" {
		u.Path = "/"
	}
	return u.String(), true
}

func fetchRobots(ctx context.Context, client *http.Client, root *url.URL, progress io.Writer) robotRules {
	u := *root
	u.Path = "/robots.txt"
	u.RawQuery = ""
	u.Fragment = ""
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u.String(), nil)
	if err != nil {
		return robotRules{}
	}
	req.Header.Set("User-Agent", "Local-SEO-Spider/0.1 permissioned-audit")
	resp, err := client.Do(req)
	if err != nil {
		fmt.Fprintln(progress, "robots.txt unavailable; continuing with conservative rate limiting")
		return robotRules{}
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return robotRules{}
	}
	body, err := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if err != nil {
		return robotRules{}
	}
	return parseRobots(string(body))
}

func parseRobots(body string) robotRules {
	var rules robotRules
	active := false
	for _, line := range strings.Split(body, "\n") {
		if i := strings.Index(line, "#"); i >= 0 {
			line = line[:i]
		}
		parts := strings.SplitN(line, ":", 2)
		if len(parts) != 2 {
			continue
		}
		key := strings.ToLower(strings.TrimSpace(parts[0]))
		value := strings.TrimSpace(parts[1])
		switch key {
		case "user-agent":
			active = value == "*" || strings.EqualFold(value, "Local-SEO-Spider")
		case "allow":
			if active && value != "" {
				rules.Allow = append(rules.Allow, value)
			}
		case "disallow":
			if active && value != "" {
				rules.Disallow = append(rules.Disallow, value)
			}
		}
	}
	return rules
}

func allowedByRobots(rules robotRules, path string) bool {
	bestLen := -1
	allowed := true
	for _, prefix := range rules.Disallow {
		if strings.HasPrefix(path, prefix) && len(prefix) > bestLen {
			bestLen = len(prefix)
			allowed = false
		}
	}
	for _, prefix := range rules.Allow {
		if strings.HasPrefix(path, prefix) && len(prefix) >= bestLen {
			bestLen = len(prefix)
			allowed = true
		}
	}
	return allowed
}

func fetchPage(ctx context.Context, client *http.Client, root *url.URL, rawURL string) (Page, []linkRef) {
	page := Page{URL: rawURL, FinalURL: rawURL}
	started := time.Now()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, rawURL, nil)
	if err != nil {
		page.FetchError = err.Error()
		return page, nil
	}
	req.Header.Set("User-Agent", "Local-SEO-Spider/0.1 permissioned-audit")
	req.Header.Set("Accept", "text/html,application/xhtml+xml;q=0.9,*/*;q=0.1")
	resp, err := client.Do(req)
	page.ResponseTimeMS = time.Since(started).Milliseconds()
	if err != nil {
		page.FetchError = err.Error()
		return page, nil
	}
	defer resp.Body.Close()
	page.Status = resp.StatusCode
	page.FinalURL = resp.Request.URL.String()
	page.ContentType = resp.Header.Get("Content-Type")
	if resp.Request.Response != nil {
		for r := resp.Request.Response; r != nil; r = r.Request.Response {
			page.Redirects++
		}
	}
	if !strings.Contains(strings.ToLower(page.ContentType), "text/html") {
		return page, nil
	}
	body, err := io.ReadAll(io.LimitReader(resp.Body, 5<<20))
	if err != nil {
		page.FetchError = err.Error()
		return page, nil
	}
	return inspectHTML(page, string(body), root)
}

func inspectHTML(page Page, body string, root *url.URL) (Page, []linkRef) {
	if m := titleRE.FindStringSubmatch(body); len(m) > 1 {
		page.Title = cleanText(m[1])
	}
	page.H1Count = len(h1RE.FindAllString(body, -1))
	for _, tag := range metaRE.FindAllString(body, -1) {
		attrs := parseAttrs(tag)
		name := strings.ToLower(attrs["name"])
		property := strings.ToLower(attrs["property"])
		if name == "description" || property == "og:description" && page.Description == "" {
			page.Description = strings.TrimSpace(attrs["content"])
		}
		if name == "robots" {
			page.Robots = strings.TrimSpace(attrs["content"])
			low := strings.ToLower(page.Robots)
			page.NoIndex = containsDirective(low, "noindex")
			page.NoFollow = containsDirective(low, "nofollow")
		}
	}
	if tag := canonicalRE.FindString(body); tag != "" {
		page.Canonical = strings.TrimSpace(parseAttrs(tag)["href"])
	}
	links := make([]linkRef, 0)
	for _, tag := range linkTagRE.FindAllString(body, -1) {
		attrs := parseAttrs(tag)
		href := attrs["href"]
		if href == "" {
			continue
		}
		rel := strings.ToLower(attrs["rel"])
		ref := linkRef{URL: href, NoFollow: containsDirective(rel, "nofollow")}
		links = append(links, ref)
		base, _ := url.Parse(page.FinalURL)
		u, err := url.Parse(html.UnescapeString(href))
		if err == nil && base != nil {
			u = base.ResolveReference(u)
			if sameOrigin(root, u) {
				page.InternalLinks++
			} else if u.Scheme == "http" || u.Scheme == "https" {
				page.ExternalLinks++
			}
		}
	}
	for _, tag := range imgRE.FindAllString(body, -1) {
		page.Images++
		attrs := parseAttrs(tag)
		if _, ok := attrs["alt"]; !ok || strings.TrimSpace(attrs["alt"]) == "" {
			page.ImagesMissingAlt++
		}
	}
	page.StructuredData = len(jsonLDRE.FindAllString(body, -1))
	page.WordCount = wordCount(body)
	return page, links
}

func parseAttrs(tag string) map[string]string {
	attrs := map[string]string{}
	for _, m := range attrRE.FindAllStringSubmatch(tag, -1) {
		value := ""
		for i := 2; i < len(m); i++ {
			if m[i] != "" {
				value = m[i]
				break
			}
		}
		attrs[strings.ToLower(m[1])] = html.UnescapeString(value)
	}
	return attrs
}

func containsDirective(value, needle string) bool {
	for _, part := range strings.FieldsFunc(value, func(r rune) bool {
		return r == ',' || r == ';' || r == ' ' || r == '\t' || r == '\n'
	}) {
		if strings.EqualFold(strings.TrimSpace(part), needle) {
			return true
		}
	}
	return false
}

func cleanText(raw string) string {
	return strings.TrimSpace(spaceRE.ReplaceAllString(html.UnescapeString(tagRE.ReplaceAllString(raw, " ")), " "))
}

func wordCount(body string) int {
	body = scriptStyleRE.ReplaceAllString(body, " ")
	text := cleanText(body)
	if text == "" {
		return 0
	}
	return len(strings.Fields(text))
}

func detectIssues(pages []Page) []Issue {
	issues := make([]Issue, 0)
	titles := map[string][]string{}
	descriptions := map[string][]string{}
	for _, p := range pages {
		if p.FetchError != "" {
			issues = append(issues, Issue{"high", "fetch-error", p.URL, p.FetchError, "Verify the URL, TLS setup, DNS, and server availability."})
			continue
		}
		if p.Status >= 400 {
			issues = append(issues, Issue{"high", "broken-url", p.URL, fmt.Sprintf("HTTP %d", p.Status), "Restore the page, correct incoming links, or redirect it to the most relevant live URL."})
		} else if p.Status >= 300 {
			issues = append(issues, Issue{"medium", "redirect", p.URL, fmt.Sprintf("HTTP %d", p.Status), "Link directly to the final canonical URL where possible."})
		}
		if p.Redirects > 1 {
			issues = append(issues, Issue{"medium", "redirect-chain", p.URL, fmt.Sprintf("%d redirects", p.Redirects), "Collapse the chain to a single redirect."})
		}
		if p.Status >= 200 && p.Status < 400 && strings.Contains(strings.ToLower(p.ContentType), "text/html") {
			if p.Title == "" {
				issues = append(issues, Issue{"high", "missing-title", p.URL, "No <title> element", "Add a concise, unique title that describes the page."})
			} else {
				titles[strings.ToLower(strings.TrimSpace(p.Title))] = append(titles[strings.ToLower(strings.TrimSpace(p.Title))], p.URL)
				if len([]rune(p.Title)) > 65 {
					issues = append(issues, Issue{"low", "long-title", p.URL, fmt.Sprintf("%d characters", len([]rune(p.Title))), "Shorten the title while keeping the primary topic clear."})
				}
			}
			if p.Description == "" {
				issues = append(issues, Issue{"medium", "missing-description", p.URL, "No meta description", "Add a useful, page-specific meta description."})
			} else {
				descriptions[strings.ToLower(strings.TrimSpace(p.Description))] = append(descriptions[strings.ToLower(strings.TrimSpace(p.Description))], p.URL)
			}
			if p.H1Count == 0 {
				issues = append(issues, Issue{"medium", "missing-h1", p.URL, "No H1 heading", "Add one clear primary heading."})
			} else if p.H1Count > 1 {
				issues = append(issues, Issue{"low", "multiple-h1", p.URL, fmt.Sprintf("%d H1 elements", p.H1Count), "Use one primary H1 unless the document structure clearly requires otherwise."})
			}
			if p.Canonical == "" {
				issues = append(issues, Issue{"low", "missing-canonical", p.URL, "No canonical link", "Add a self-referencing canonical URL for indexable pages."})
			}
			if p.NoIndex && p.Canonical != "" && !sameCanonical(p.FinalURL, p.Canonical) {
				issues = append(issues, Issue{"high", "indexability-conflict", p.URL, "noindex combined with a canonical to another URL", "Choose one clear indexing signal and remove the conflict."})
			}
			if p.ImagesMissingAlt > 0 {
				issues = append(issues, Issue{"low", "missing-image-alt", p.URL, fmt.Sprintf("%d of %d images have empty or missing alt text", p.ImagesMissingAlt, p.Images), "Add meaningful alt text to informative images; keep decorative images explicitly empty."})
			}
		}
	}
	for title, urls := range titles {
		if title == "" || len(urls) < 2 {
			continue
		}
		for _, u := range urls {
			issues = append(issues, Issue{"medium", "duplicate-title", u, fmt.Sprintf("Shared by %d pages", len(urls)), "Write a unique title aligned with this page's search intent."})
		}
	}
	for description, urls := range descriptions {
		if description == "" || len(urls) < 2 {
			continue
		}
		for _, u := range urls {
			issues = append(issues, Issue{"low", "duplicate-description", u, fmt.Sprintf("Shared by %d pages", len(urls)), "Write a unique description for this page."})
		}
	}
	sort.SliceStable(issues, func(i, j int) bool {
		rank := map[string]int{"high": 0, "medium": 1, "low": 2}
		if rank[issues[i].Severity] != rank[issues[j].Severity] {
			return rank[issues[i].Severity] < rank[issues[j].Severity]
		}
		if issues[i].Code != issues[j].Code {
			return issues[i].Code < issues[j].Code
		}
		return issues[i].URL < issues[j].URL
	})
	return issues
}

func sameCanonical(pageURL, canonical string) bool {
	base, err := url.Parse(pageURL)
	if err != nil {
		return false
	}
	ref, err := url.Parse(canonical)
	if err != nil {
		return false
	}
	resolved := base.ResolveReference(ref)
	base.Fragment = ""
	resolved.Fragment = ""
	return base.String() == resolved.String()
}

func writeAudit(audit *Audit, root string) error {
	stamp := audit.StartedAt.Format("20060102-150405")
	dir := filepath.Join(root, stamp)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return fmt.Errorf("create report directory: %w", err)
	}
	audit.ReportDir = dir
	audit.CSVPath = filepath.Join(dir, "crawl.csv")
	audit.HTMLPath = filepath.Join(dir, "report.html")
	if err := writeCSV(audit.CSVPath, audit.Pages); err != nil {
		return err
	}
	if err := writeHTML(audit.HTMLPath, audit); err != nil {
		return err
	}
	latest := filepath.Join(root, "latest.txt")
	if err := os.WriteFile(latest, []byte(audit.HTMLPath+"\n"), 0o644); err != nil {
		return fmt.Errorf("write latest report pointer: %w", err)
	}
	return nil
}

func writeCSV(path string, pages []Page) error {
	f, err := os.Create(path)
	if err != nil {
		return fmt.Errorf("create CSV: %w", err)
	}
	defer f.Close()
	w := csv.NewWriter(f)
	defer w.Flush()
	if err := w.Write([]string{"url", "final_url", "status", "content_type", "title", "description", "h1_count", "canonical", "robots", "noindex", "nofollow", "internal_links", "external_links", "images", "images_missing_alt", "structured_data", "word_count", "redirects", "response_time_ms", "fetch_error"}); err != nil {
		return err
	}
	for _, p := range pages {
		row := []string{
			p.URL, p.FinalURL, strconv.Itoa(p.Status), p.ContentType, p.Title, p.Description,
			strconv.Itoa(p.H1Count), p.Canonical, p.Robots, strconv.FormatBool(p.NoIndex),
			strconv.FormatBool(p.NoFollow), strconv.Itoa(p.InternalLinks), strconv.Itoa(p.ExternalLinks),
			strconv.Itoa(p.Images), strconv.Itoa(p.ImagesMissingAlt), strconv.Itoa(p.StructuredData),
			strconv.Itoa(p.WordCount), strconv.Itoa(p.Redirects), strconv.FormatInt(p.ResponseTimeMS, 10), p.FetchError,
		}
		if err := w.Write(row); err != nil {
			return err
		}
	}
	if err := w.Error(); err != nil {
		return fmt.Errorf("write CSV: %w", err)
	}
	return nil
}

func writeHTML(path string, audit *Audit) error {
	f, err := os.Create(path)
	if err != nil {
		return fmt.Errorf("create HTML report: %w", err)
	}
	defer f.Close()
	bw := bufio.NewWriter(f)
	defer bw.Flush()
	high, medium, low := 0, 0, 0
	for _, issue := range audit.Issues {
		switch issue.Severity {
		case "high":
			high++
		case "medium":
			medium++
		default:
			low++
		}
	}
	fmt.Fprintf(bw, `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Local SEO Audit</title><style>
:root{font-family:Inter,ui-sans-serif,system-ui,-apple-system,sans-serif;color:#172033;background:#f5f7fb}body{margin:0}.wrap{max-width:1180px;margin:auto;padding:32px}h1{margin:.2rem 0}.muted{color:#657089}.cards{display:grid;grid-template-columns:repeat(4,minmax(0,1fr));gap:12px;margin:24px 0}.card{background:#fff;border:1px solid #e2e7ef;border-radius:14px;padding:18px;box-shadow:0 4px 18px rgba(20,32,54,.04)}.n{font-size:28px;font-weight:750}.high{color:#b42318}.medium{color:#b54708}.low{color:#475467}table{width:100%%;border-collapse:collapse;background:#fff;border:1px solid #e2e7ef;border-radius:14px;overflow:hidden;margin:12px 0 28px;display:block;overflow-x:auto}th,td{text-align:left;padding:10px 12px;border-bottom:1px solid #edf0f5;vertical-align:top;font-size:13px}th{background:#f8fafc;position:sticky;top:0}.pill{display:inline-block;border-radius:999px;padding:2px 8px;font-size:11px;font-weight:700;text-transform:uppercase}.pill.high{background:#fee4e2}.pill.medium{background:#fef0c7}.pill.low{background:#eaecf0}a{color:#175cd3}.url{max-width:420px;word-break:break-all}@media(max-width:760px){.cards{grid-template-columns:repeat(2,1fr)}.wrap{padding:18px}}
</style></head><body><main class="wrap">`)
	fmt.Fprintf(bw, "<p class=muted>Local SEO Spider · permissioned audit</p><h1>Technical SEO audit</h1><p class=muted>%s · generated %s UTC</p>", html.EscapeString(audit.StartURL), audit.StartedAt.Format(time.RFC3339))
	fmt.Fprintf(bw, "<section class=cards><div class=card><div class=n>%d</div><div class=muted>pages crawled</div></div><div class=card><div class=\"n high\">%d</div><div class=muted>high severity</div></div><div class=card><div class=\"n medium\">%d</div><div class=muted>medium severity</div></div><div class=card><div class=\"n low\">%d</div><div class=muted>low severity</div></div></section>", len(audit.Pages), high, medium, low)
	fmt.Fprintln(bw, "<h2>Prioritized issues</h2><table><thead><tr><th>Severity</th><th>Issue</th><th>URL</th><th>Evidence</th><th>Recommended fix</th></tr></thead><tbody>")
	if len(audit.Issues) == 0 {
		fmt.Fprintln(bw, "<tr><td colspan=5>No issues detected by this focused audit.</td></tr>")
	}
	for _, issue := range audit.Issues {
		fmt.Fprintf(bw, "<tr><td><span class=\"pill %s\">%s</span></td><td>%s</td><td class=url><a href=\"%s\">%s</a></td><td>%s</td><td>%s</td></tr>", html.EscapeString(issue.Severity), html.EscapeString(issue.Severity), html.EscapeString(issue.Code), html.EscapeString(issue.URL), html.EscapeString(issue.URL), html.EscapeString(issue.Evidence), html.EscapeString(issue.Fix))
	}
	fmt.Fprintln(bw, "</tbody></table><h2>Crawl inventory</h2><table><thead><tr><th>Status</th><th>URL</th><th>Title</th><th>H1</th><th>Canonical</th><th>Links</th><th>Images missing alt</th><th>Words</th></tr></thead><tbody>")
	for _, p := range audit.Pages {
		fmt.Fprintf(bw, "<tr><td>%d</td><td class=url><a href=\"%s\">%s</a></td><td>%s</td><td>%d</td><td class=url>%s</td><td>%d internal / %d external</td><td>%d</td><td>%d</td></tr>", p.Status, html.EscapeString(p.URL), html.EscapeString(p.URL), html.EscapeString(p.Title), p.H1Count, html.EscapeString(p.Canonical), p.InternalLinks, p.ExternalLinks, p.ImagesMissingAlt, p.WordCount)
	}
	fmt.Fprintln(bw, "</tbody></table><p class=muted>Scope: same-origin HTML crawl, robots.txt, nofollow, rate limiting, metadata, links, images, structured-data presence, duplicate metadata, redirects, and indexability signals. This report does not execute JavaScript or use web-scale backlink/keyword datasets.</p></main></body></html>")
	return nil
}
