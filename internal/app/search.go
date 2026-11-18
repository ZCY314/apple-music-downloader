package app

import (
	"fmt"
	"strings"
	"unicode"

	ampapi "amdl/internal/amp-api"
	"github.com/AlecAivazis/survey/v2"
)

type SearchResultItem struct {
	Type   string
	Name   string
	Detail string
	URL    string
	ID     string
}

type QualityOption struct {
	ID          string
	Description string
}

const (
	searchPageSize = 25
	searchMaxPages = 4
	searchUIPage   = 15
)

// buildSearchQueries retains the original phrase and adds token variants to improve catalogue recall.
func buildSearchQueries(query string) []string {
	query = strings.Join(strings.Fields(strings.TrimSpace(query)), " ")
	if query == "" {
		return nil
	}
	queries := []string{query}
	seen := map[string]bool{strings.ToLower(query): true}
	add := func(candidate string) {
		candidate = strings.Join(strings.Fields(strings.TrimSpace(candidate)), " ")
		key := strings.ToLower(candidate)
		if candidate != "" && !seen[key] {
			seen[key] = true
			queries = append(queries, candidate)
		}
	}
	words := strings.Fields(query)
	if len(words) >= 2 {
		reversed := make([]string, len(words))
		for i := range words {
			reversed[len(words)-1-i] = words[i]
		}
		add(strings.Join(reversed, " "))
		for _, word := range words {
			add(word)
		}
		for i := 0; i+1 < len(words); i++ {
			add(strings.Join(words[i:i+2], " "))
		}
	}
	// Chinese catalogue titles are often indexed as a continuous string.
	// Add overlapping four- and three-character windows so a long series
	// title can still match when the storefront indexes only part of it.
	for _, word := range words {
		runes := []rune(word)
		allHan := len(runes) >= 4
		for _, ch := range runes {
			if !unicode.Is(unicode.Han, ch) {
				allHan = false
				break
			}
		}
		if !allHan {
			continue
		}
		for width := 4; width >= 3; width-- {
			for start := 0; start+width <= len(runes); start++ {
				add(string(runes[start : start+width]))
			}
		}
	}
	if len(queries) > 8 {
		queries = queries[:8]
	}
	return queries
}

func appendUniqueSearchItem(items []SearchResultItem, item SearchResultItem) []SearchResultItem {
	for _, existing := range items {
		if (item.ID != "" && existing.ID == item.ID) || (item.ID == "" && item.URL != "" && existing.URL == item.URL) {
			return items
		}
	}
	return append(items, item)
}

func (r *Runner) setDlFlags(quality string) {
	r.Flags.Atmos = false
	r.Flags.AAC = false
	switch quality {
	case "atmos":
		r.Flags.Atmos = true
		fmt.Println("Quality set to: Dolby Atmos")
	case "aac":
		r.Flags.AAC = true
		r.Config.Media.AacType = "aac"
		fmt.Println("Quality set to: High-Quality (AAC)")
	case "alac":
		fmt.Println("Quality set to: Lossless (ALAC)")
	}
}

func (r *Runner) promptForQuality(item SearchResultItem, token string) (string, error) {
	if item.Type == "Artist" {
		fmt.Println("Artist selected. Proceeding to list all albums/videos.")
		return "default", nil
	}
	fmt.Printf("\nFetching available qualities for: %s\n", item.Name)
	qualities := []QualityOption{{ID: "alac", Description: "Lossless (ALAC)"}, {ID: "aac", Description: "High-Quality (AAC)"}, {ID: "atmos", Description: "Dolby Atmos"}}
	options := make([]string, 0, len(qualities))
	for _, q := range qualities {
		options = append(options, q.Description)
	}
	prompt := &survey.Select{Message: "Select a quality to download:", Options: options, PageSize: 5}
	selected := 0
	if err := survey.AskOne(prompt, &selected); err != nil {
		return "", nil
	}
	if selected < 0 || selected >= len(qualities) {
		return "", fmt.Errorf("invalid quality selection: %d", selected)
	}
	return qualities[selected].ID, nil
}

func searchItems(resp *ampapi.SearchResp, searchType string) []SearchResultItem {
	var items []SearchResultItem
	switch searchType {
	case "album":
		if resp.Results.Albums != nil {
			for _, item := range resp.Results.Albums.Data {
				year := ""
				if len(item.Attributes.ReleaseDate) >= 4 {
					year = item.Attributes.ReleaseDate[:4]
				}
				detail := fmt.Sprintf("%s (%s, %d tracks)", item.Attributes.ArtistName, year, item.Attributes.TrackCount)
				items = append(items, SearchResultItem{Type: "Album", Name: item.Attributes.Name, Detail: detail, URL: item.Attributes.URL, ID: item.ID})
			}
		}
	case "song":
		if resp.Results.Songs != nil {
			for _, item := range resp.Results.Songs.Data {
				detail := fmt.Sprintf("%s (%s)", item.Attributes.ArtistName, item.Attributes.AlbumName)
				items = append(items, SearchResultItem{Type: "Song", Name: item.Attributes.Name, Detail: detail, URL: item.Attributes.URL, ID: item.ID})
			}
		}
	case "artist":
		if resp.Results.Artists != nil {
			for _, item := range resp.Results.Artists.Data {
				detail := strings.Join(item.Attributes.GenreNames, ", ")
				items = append(items, SearchResultItem{Type: "Artist", Name: item.Attributes.Name, Detail: detail, URL: item.Attributes.URL, ID: item.ID})
			}
		}
	}
	return items
}

func searchHasNext(resp *ampapi.SearchResp, searchType string) bool {
	switch searchType {
	case "album":
		return resp.Results.Albums != nil && resp.Results.Albums.Next != ""
	case "song":
		return resp.Results.Songs != nil && resp.Results.Songs.Next != ""
	case "artist":
		return resp.Results.Artists != nil && resp.Results.Artists.Next != ""
	}
	return false
}

func searchStorefronts(primary, searchType string) []string {
	primary = strings.ToLower(strings.TrimSpace(primary))
	if primary == "" {
		primary = "us"
	}
	storefronts := []string{primary}
	if searchType == "album" {
		// Regional catalogue searches are important for Hong Kong/Taiwan
		// releases that may not be indexed in the user's default storefront.
		for _, region := range []string{"hk", "tw", "sg"} {
			if !contains(storefronts, region) {
				storefronts = append(storefronts, region)
			}
		}
	}
	return storefronts
}

func (r *Runner) fetchSearchResults(searchType, query, token string) ([]SearchResultItem, error) {
	queries := buildSearchQueries(query)
	storefronts := searchStorefronts(r.Config.General.Storefront, searchType)
	var results []SearchResultItem
	var firstErr error

	fetch := func(storefront, searchQuery string) {
		fmt.Printf("Searching %s for %q\n", strings.ToUpper(storefront), searchQuery)
		for page := 0; page < searchMaxPages; page++ {
			resp, err := ampapi.Search(storefront, searchQuery, searchType+"s", r.Config.General.Language, token, searchPageSize, page*searchPageSize)
			if err != nil {
				if firstErr == nil {
					firstErr = err
				}
				fmt.Printf("Warning: search pass %q in %s page %d failed: %v\n", searchQuery, strings.ToUpper(storefront), page+1, err)
				break
			}
			for _, item := range searchItems(resp, searchType) {
				results = appendUniqueSearchItem(results, item)
			}
			if !searchHasNext(resp, searchType) {
				break
			}
		}
	}

	// Search the exact phrase in every relevant storefront first. This keeps
	// high-confidence regional matches ahead of looser token-based matches.
	for _, storefront := range storefronts {
		fetch(storefront, queries[0])
	}
	// Then broaden recall with word-order, token and CJK-fragment variants in
	// the configured storefront, avoiding an excessive cross-region query fanout.
	for _, searchQuery := range queries[1:] {
		fetch(storefronts[0], searchQuery)
	}
	if len(results) == 0 && firstErr != nil {
		return nil, fmt.Errorf("all catalog search attempts failed: %w", firstErr)
	}
	return results, nil
}

func (r *Runner) handleSearch(searchType string, queryParts []string, token string) ([]string, error) {
	query := strings.Join(queryParts, " ")
	if searchType != "album" && searchType != "song" && searchType != "artist" {
		return nil, fmt.Errorf("invalid search type: %s. Use 'album', 'song', or 'artist'", searchType)
	}
	fmt.Printf("Searching for %ss: %q in storefront %q\n", searchType, query, r.Config.General.Storefront)
	items, err := r.fetchSearchResults(searchType, query, token)
	if err != nil {
		return nil, err
	}
	fmt.Printf("Found %d unique results across expanded searches.\n", len(items))
	if len(items) == 0 {
		fmt.Println("No results found.")
		return nil, nil
	}

	var selectedURLs []string
	pageStart := 0
	for {
		pageEnd := pageStart + searchUIPage
		if pageEnd > len(items) {
			pageEnd = len(items)
		}
		pageItems := items[pageStart:pageEnd]
		options := make([]string, 0, len(pageItems)+2)
		const prev = "⬅️  Previous Page"
		const next = "➡️  Next Page"
		const finish = "✓  Finish selection"
		if pageStart > 0 {
			options = append(options, prev)
		}
		for _, item := range pageItems {
			options = append(options, fmt.Sprintf("%s - %s", item.Name, item.Detail))
		}
		if pageEnd < len(items) {
			options = append(options, next)
		}
		if r.Flags.Select {
			multiOptions := append([]string(nil), options...)
			multiOptions = append(multiOptions, finish)
			prompt := &survey.MultiSelect{Message: fmt.Sprintf("Select results (%d-%d of %d; Space to toggle):", pageStart+1, pageEnd, len(items)), Options: multiOptions, PageSize: searchUIPage}
			var indices []int
			if err := survey.AskOne(prompt, &indices); err != nil {
				return nil, nil
			}
			goNext, goPrev, done := false, false, false
			prevOffset := 0
			if pageStart > 0 {
				prevOffset = 1
			}
			for _, idx := range indices {
				if idx < 0 || idx >= len(multiOptions) {
					continue
				}
				switch multiOptions[idx] {
				case prev:
					goPrev = true
				case next:
					goNext = true
				case finish:
					done = true
				default:
					itemIndex := idx - prevOffset
					if itemIndex >= 0 && itemIndex < len(pageItems) {
						selectedURLs = appendUniqueURL(selectedURLs, pageItems[itemIndex].URL)
					}
				}
			}
			if done {
				break
			}
			if goNext {
				pageStart = pageEnd
				continue
			}
			if goPrev {
				pageStart -= searchUIPage
				if pageStart < 0 {
					pageStart = 0
				}
				continue
			}
			break
		}
		prompt := &survey.Select{Message: "Use arrow keys to navigate, Enter to select:", Options: options, PageSize: searchUIPage}
		selected := 0
		if err := survey.AskOne(prompt, &selected); err != nil {
			return nil, nil
		}
		if selected < 0 || selected >= len(options) {
			return nil, fmt.Errorf("invalid search result selection: %d", selected)
		}
		switch options[selected] {
		case next:
			pageStart = pageEnd
			continue
		case prev:
			pageStart -= searchUIPage
			if pageStart < 0 {
				pageStart = 0
			}
			continue
		}
		itemIndex := selected
		if pageStart > 0 {
			itemIndex--
		}
		if itemIndex < 0 || itemIndex >= len(pageItems) {
			return nil, fmt.Errorf("search result index out of range")
		}
		item := pageItems[itemIndex]
		quality, err := r.promptForQuality(item, token)
		if err != nil {
			return nil, fmt.Errorf("could not process quality selection: %w", err)
		}
		if quality == "" {
			fmt.Println("Selection cancelled.")
			return nil, nil
		}
		if quality != "default" {
			r.setDlFlags(quality)
		}
		return []string{item.URL}, nil
	}
	if len(selectedURLs) == 0 {
		return nil, nil
	}
	item := SearchResultItem{Type: strings.ToUpper(searchType[:1]) + searchType[1:], Name: query}
	quality, err := r.promptForQuality(item, token)
	if err != nil {
		return nil, fmt.Errorf("could not process quality selection: %w", err)
	}
	if quality == "" {
		fmt.Println("Selection cancelled.")
		return nil, nil
	}
	if quality != "default" {
		r.setDlFlags(quality)
	}
	return selectedURLs, nil
}

func appendUniqueURL(urls []string, candidate string) []string {
	for _, existing := range urls {
		if existing == candidate {
			return urls
		}
	}
	return append(urls, candidate)
}
