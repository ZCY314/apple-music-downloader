package app

import (
	"fmt"
	"os"
	"strings"
	"sync"
	"unicode"

	ampapi "amdl/internal/amp-api"
	"github.com/AlecAivazis/survey/v2"
)

type SearchResultItem struct {
	Type    string `json:"type"`
	Name    string `json:"name"`
	Detail  string `json:"detail"`
	URL     string `json:"url"`
	ID      string `json:"id"`
	Artwork string `json:"artwork"`
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
				items = append(items, SearchResultItem{Type: "Album", Name: item.Attributes.Name, Detail: detail, URL: item.Attributes.URL, ID: item.ID, Artwork: item.Attributes.Artwork.URL})
			}
		}
	case "song":
		if resp.Results.Songs != nil {
			for _, item := range resp.Results.Songs.Data {
				detail := fmt.Sprintf("%s (%s)", item.Attributes.ArtistName, item.Attributes.AlbumName)
				items = append(items, SearchResultItem{Type: "Song", Name: item.Attributes.Name, Detail: detail, URL: item.Attributes.URL, ID: item.ID, Artwork: item.Attributes.Artwork.URL})
			}
		}
	case "playlist", "record-labels", "curators":
		var collection *ampapi.GenericResults
		switch searchType {
		case "playlist":
			collection = resp.Results.Playlists
		case "record-labels":
			collection = resp.Results.RecordLabels
		case "curators":
			collection = resp.Results.Curators
		}
		if collection != nil {
			for _, item := range collection.Data {
				detail := item.Attributes.ArtistName
				if detail == "" {
					detail = item.Attributes.CuratorName
				}
				if detail == "" && item.Attributes.TrackCount > 0 {
					detail = fmt.Sprintf("%d tracks", item.Attributes.TrackCount)
				}
				items = append(items, SearchResultItem{Type: item.Type, Name: item.Attributes.Name, Detail: detail, URL: item.Attributes.URL, ID: item.ID, Artwork: item.Attributes.Artwork.URL})
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
	case "playlist":
		return resp.Results.Playlists != nil && resp.Results.Playlists.Next != ""
	case "record-labels":
		return resp.Results.RecordLabels != nil && resp.Results.RecordLabels.Next != ""
	case "curators":
		return resp.Results.Curators != nil && resp.Results.Curators.Next != ""
	}
	return false
}

func searchStorefronts(primary, searchType string) []string {
	primary = strings.ToLower(strings.TrimSpace(primary))
	if primary == "" {
		primary = "cn"
	}
	storefronts := []string{primary}
	if searchType == "playlist" {
		return []string{"tw", "hk", "us"}
	}
	if searchType == "record-labels" || searchType == "curators" {
		return []string{"cn", "hk", "tw", "us"}
	}
	if searchType == "album" {
		// Keep CN in the catalogue fallback set even when a user changes the
		// preferred storefront; CN remains first by default.
		for _, region := range []string{"cn", "hk", "tw", "sg", "us"} {
			if !contains(storefronts, region) {
				storefronts = append(storefronts, region)
			}
		}
	}
	return storefronts
}

func searchAPITypes(searchType string) string {
	switch searchType {
	case "record-labels":
		return "record-labels"
	case "curators":
		return "curators"
	default:
		return searchType + "s"
	}
}

func (r *Runner) fetchSearchResults(searchType, query, token string) ([]SearchResultItem, error) {
	queries := buildSearchQueries(query)
	if len(queries) == 0 {
		return nil, nil
	}
	if (searchType == "playlist" || searchType == "record-labels" || searchType == "curators") && len(queries) > 2 {
		queries = queries[:2]
	}
	storefronts := searchStorefronts(r.Config.General.Storefront, searchType)

	// The exact phrase is the highest-value request. Query all relevant
	// storefronts concurrently, but merge in storefront order for stable,
	// predictable ranking (CN-first where configured).
	fetchStorefront := func(storefront, searchQuery string) ([]SearchResultItem, error) {
		var found []SearchResultItem
		for page := 0; page < searchMaxPages; page++ {
			resp, err := ampapi.Search(storefront, searchQuery, searchAPITypes(searchType), r.Config.General.Language, token, searchPageSize, page*searchPageSize)
			if err != nil {
				return found, fmt.Errorf("%s %q page %d: %w", strings.ToUpper(storefront), searchQuery, page+1, err)
			}
			for _, item := range searchItems(resp, searchType) {
				found = appendUniqueSearchItem(found, item)
			}
			if !searchHasNext(resp, searchType) {
				break
			}
		}
		return found, nil
	}

	fetchAcrossRegions := func(searchQuery string) ([]SearchResultItem, []error) {
		resultsByRegion := make([][]SearchResultItem, len(storefronts))
		errorsByRegion := make([]error, len(storefronts))
		var wg sync.WaitGroup
		for i, storefront := range storefronts {
			wg.Add(1)
			go func(index int, region string) {
				defer wg.Done()
				fmt.Fprintf(os.Stderr, "Searching %s for %q\n", strings.ToUpper(region), searchQuery)
				resultsByRegion[index], errorsByRegion[index] = fetchStorefront(region, searchQuery)
			}(i, storefront)
		}
		wg.Wait()
		var merged []SearchResultItem
		for _, regional := range resultsByRegion {
			for _, item := range regional {
				merged = appendUniqueSearchItem(merged, item)
			}
		}
		var errs []error
		for _, err := range errorsByRegion {
			if err != nil {
				errs = append(errs, err)
			}
		}
		return merged, errs
	}

	results, errs := fetchAcrossRegions(queries[0])
	if len(results) > 0 {
		return results, nil
	}

	// Only broaden the query in the preferred storefront after the exact
	// cross-region pass returns no results. This avoids multiplying every
	// token/CJK fallback by five regions on the common path.
	primary := storefronts[0]
	for _, fallback := range queries[1:] {
		fmt.Fprintf(os.Stderr, "Retrying %s with a shorter query: %q\n", strings.ToUpper(primary), fallback)
		found, err := fetchStorefront(primary, fallback)
		if err != nil {
			errs = append(errs, err)
		}
		for _, item := range found {
			results = appendUniqueSearchItem(results, item)
		}
		if len(results) >= searchPageSize {
			break
		}
	}
	if len(results) == 0 && len(errs) > 0 {
		return nil, fmt.Errorf("all catalog search attempts failed: %w", errs[0])
	}
	return results, nil
}

func (r *Runner) handleSearch(searchType string, queryParts []string, token string) ([]string, error) {
	query := strings.Join(queryParts, " ")
	if searchType != "album" && searchType != "song" && searchType != "artist" && searchType != "playlist" && searchType != "record-labels" && searchType != "curators" {
		return nil, fmt.Errorf("invalid search type: %s. Use album, song, artist, playlist, record-labels, or curators", searchType)
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
