package app

import (
	"reflect"
	"testing"
)

func TestAppendUniqueURL(t *testing.T) {
	tests := []struct {
		name      string
		input     []string
		candidate string
		want      []string
	}{
		{
			name:      "append new URL",
			input:     []string{"https://music.apple.com/us/album/one/1"},
			candidate: "https://music.apple.com/us/album/two/2",
			want: []string{
				"https://music.apple.com/us/album/one/1",
				"https://music.apple.com/us/album/two/2",
			},
		},
		{
			name:      "ignore duplicate URL",
			input:     []string{"https://music.apple.com/us/album/one/1"},
			candidate: "https://music.apple.com/us/album/one/1",
			want:      []string{"https://music.apple.com/us/album/one/1"},
		},
		{
			name:      "preserve order across batch",
			input:     []string{"first", "second"},
			candidate: "third",
			want:      []string{"first", "second", "third"},
		},
		{
			name:      "empty input",
			candidate: "first",
			want:      []string{"first"},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := appendUniqueURL(tt.input, tt.candidate)
			if !reflect.DeepEqual(got, tt.want) {
				t.Fatalf("appendUniqueURL() = %#v, want %#v", got, tt.want)
			}
		})
	}
}

func TestBuildSearchQueries(t *testing.T) {
	tests := []struct {
		name, query string
		want        []string
	}{
		{name: "multiword catalogue query", query: "denon mastersonic", want: []string{"denon mastersonic", "mastersonic denon", "denon", "mastersonic"}},
		{name: "Chinese series query expands", query: "百代百年系列", want: []string{"百代百年系列", "百代百年", "百年系列"}},
		{name: "single word stays unchanged", query: "Radiohead", want: []string{"Radiohead"}},
		{name: "empty query", query: "  ", want: nil},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := buildSearchQueries(tt.query)
			for _, want := range tt.want {
				found := false
				for _, candidate := range got {
					if candidate == want {
						found = true
						break
					}
				}
				if !found {
					t.Fatalf("query variants %q do not contain %q", got, want)
				}
			}
			if tt.want == nil && got != nil {
				t.Fatalf("expected nil, got %q", got)
			}
			if len(got) > 8 {
				t.Fatalf("too many query variants: %d", len(got))
			}
		})
	}
}

func TestAppendUniqueSearchItem(t *testing.T) {
	first := SearchResultItem{ID: "123", URL: "https://music.apple.com/us/album/one/123", Name: "One"}
	duplicate := SearchResultItem{ID: "123", URL: "https://music.apple.com/gb/album/one/123", Name: "One (different storefront)"}
	second := SearchResultItem{ID: "456", URL: "https://music.apple.com/us/album/two/456", Name: "Two"}
	items := appendUniqueSearchItem(nil, first)
	items = appendUniqueSearchItem(items, duplicate)
	items = appendUniqueSearchItem(items, second)
	if len(items) != 2 {
		t.Fatalf("expected 2 unique items, got %d", len(items))
	}
	if items[0].Name != "One" || items[1].Name != "Two" {
		t.Fatalf("unexpected result order: %#v", items)
	}
}

func TestSearchStorefronts(t *testing.T) {
	tests := []struct {
		name, primary, searchType string
		want                      []string
	}{
		{name: "album search includes regional catalogs", primary: "us", searchType: "album", want: []string{"us", "hk", "tw", "sg"}},
		{name: "configured regional catalog is not duplicated", primary: "HK", searchType: "album", want: []string{"hk", "tw", "sg"}},
		{name: "song search stays in configured catalog", primary: "us", searchType: "song", want: []string{"us"}},
		{name: "empty storefront defaults safely", primary: "", searchType: "album", want: []string{"us", "hk", "tw", "sg"}},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := searchStorefronts(tt.primary, tt.searchType)
			if !reflect.DeepEqual(got, tt.want) {
				t.Fatalf("searchStorefronts() = %#v, want %#v", got, tt.want)
			}
		})
	}
}
