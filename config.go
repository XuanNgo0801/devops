package config

import (
	"encoding/json"
	"fmt"
	"os"
	"strings"
	"time"
)

type SMSSchedule struct {
	Enabled   bool   `json:"enabled"`
	StartTime string `json:"start_time"` // danh sách số điện thoại đã tách
	EndTime   string `json:"end_time"`   // chuỗi raw từ json
	Timezone  string `json:"timezone"`
}

type Receiver struct {
	Name     string            `json:"name"`
	Mobiles  []string          `json:"-"`              // danh sách số điện thoại đã tách
	Mobile   string            `json:"mobile"`         // chuỗi raw từ json
	Schedule *SMSSchedule      `json:"schedule"`
	Match    map[string]string `json:"match,omitempty"`
}

type DefaultReceiver struct {
	Mobiles  []string     `json:"-"`
	Mobile   string       `json:"mobile"`
	Schedule *SMSSchedule `json:"schedule"`
}

// ArgocdConfig cấu hình cho ArgoCD (NEW)
type ArgocdConfig struct {
	Enabled          bool              `json:"enabled"`
	ProjectMapping   map[string]string `json:"project_mapping,omitempty"`
	NamespaceMapping map[string]string `json:"namespace_mapping,omitempty"`
}

type Config struct {
	Receivers       []Receiver      `json:"receiver"`
	Receiver        []Receiver      `json:"-"` // Alias để tương thích với code mới
	DefaultReceiver DefaultReceiver `json:"default_receiver"`
	ArgoCD          *ArgocdConfig   `json:"argocd,omitempty"` // NEW: ArgoCD config
}

// LoadConfig loads the json config file
func LoadConfig(path string) (*Config, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var cfg Config
	if err := json.Unmarshal(data, &cfg); err != nil {
		return nil, err
	}
	cfg.Normalize()
	return &cfg, nil
}

// Normalize parses raw mobile strings into string slices
func (c *Config) Normalize() {
	for i := range c.Receivers {
		c.Receivers[i].Mobiles = parseMobiles(c.Receivers[i].Mobile)
	}
	c.DefaultReceiver.Mobiles = parseMobiles(c.DefaultReceiver.Mobile)
	
	// NEW: Tạo alias để tương thích với code mới
	c.Receiver = c.Receivers
}

// parseMobiles splits and trims a comma-separated mobile string
func parseMobiles(mobileString string) []string {
	parts := strings.Split(mobileString, ",")
	var mobiles []string
	for _, p := range parts {
		trimmed := strings.TrimSpace(p)
		if trimmed != "" {
			mobiles = append(mobiles, trimmed)
		}
	}
	return mobiles
}

// AllMobiles returns all unique mobile numbers (from all receivers and default)
func (c *Config) AllMobiles() []string {
	mobileSet := make(map[string]struct{})

	for _, r := range c.Receivers {
		for _, p := range r.Mobiles {
			mobileSet[p] = struct{}{}
		}
	}

	for _, p := range c.DefaultReceiver.Mobiles {
		mobileSet[p] = struct{}{}
	}

	var mobiles []string
	for p := range mobileSet {
		mobiles = append(mobiles, p)
	}
	return mobiles
}

func (s *SMSSchedule) ParseTimeRange() (start, end time.Time, err error) {
	if s == nil {
		return time.Time{}, time.Time{}, fmt.Errorf("schedule is nil")
	}

	loc, err := time.LoadLocation(s.Timezone)
	if err != nil {
		return time.Time{}, time.Time{}, fmt.Errorf("invalid timezone: %v", err)
	}

	now := time.Now().In(loc)
	startParts, err := time.ParseInLocation("15:04:05", s.StartTime, loc)
	if err != nil {
		return time.Time{}, time.Time{}, fmt.Errorf("invalid start_time format, expected HH:MM:SS: %v", err)
	}
	endParts, err := time.ParseInLocation("15:04:05", s.EndTime, loc)
	if err != nil {
		return time.Time{}, time.Time{}, fmt.Errorf("invalid end_time format, expected HH:MM:SS: %v", err)
	}

	start = time.Date(now.Year(), now.Month(), now.Day(),
		startParts.Hour(), startParts.Minute(), startParts.Second(), 0, loc)
	end = time.Date(now.Year(), now.Month(), now.Day(),
		endParts.Hour(), endParts.Minute(), endParts.Second(), 0, loc)

	return start, end, nil
}