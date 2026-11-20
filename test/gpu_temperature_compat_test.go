package gpucompat

import (
	"encoding/json"
	"testing"
)

// Decoder projections of komari protocol/v2.GPUDeviceInfo before/after #710.
// This verifies wire compatibility, not a live server/storage end-to-end test.
func TestTemperatureWireCompatibility(t *testing.T) {
	for _, tc := range []struct {
		token string
		want  float64
		oldOK bool
	}{
		{"60", 60, true}, {"0", 0, true},
		{"76.3", 76.3, false}, {"86.65", 86.65, false},
		{"7.63e1", 76.3, false}, {"60.0", 60, false}, {"6e1", 60, false},
	} {
		t.Run(tc.token, func(t *testing.T) {
			wire := []byte(`{"temperature":` + tc.token + `}`)
			var old struct {
				Temperature int `json:"temperature"`
			}
			err := json.Unmarshal(wire, &old)
			if (err == nil) != tc.oldOK {
				t.Fatalf("old server: error=%v, want acceptance=%v", err, tc.oldOK)
			}
			var current struct {
				Temperature float64 `json:"temperature"`
			}
			if err := json.Unmarshal(wire, &current); err != nil || current.Temperature != tc.want {
				t.Fatalf("new server: temperature=%v error=%v, want %v", current.Temperature, err, tc.want)
			}
		})
	}
}
