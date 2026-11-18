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
