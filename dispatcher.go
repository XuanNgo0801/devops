package handler

import (
	"log"
	"net/http"
	"time"

	"sms-devops-gateway/config"
)

var location *time.Location

func init() {
	loc, err := time.LoadLocation("Asia/Ho_Chi_Minh")
	if err != nil {
		log.Printf("⚠️ Warning: Cannot load timezone Asia/Ho_Chi_Minh, using UTC")
		location = time.UTC
	} else {
		location = loc
	}
}

// Dispatcher routes các request đến handler tương ứng
func Dispatcher(cfg *config.Config) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		logTime := time.Now().In(location).Format("2006-01-02T15:04:05-07:00")
		
		// Log request info
		log.Printf("[%s] 🌐 Request: %s %s from %s\n", 
			logTime, r.Method, r.URL.Path, r.RemoteAddr)
		
		// Health check endpoint
		if r.URL.Path == "/health" || r.URL.Path == "/healthz" {
			w.WriteHeader(http.StatusOK)
			w.Write([]byte("OK"))
			return
		}
		
		// Ready check endpoint
		if r.URL.Path == "/ready" || r.URL.Path == "/readyz" {
			w.WriteHeader(http.StatusOK)
			w.Write([]byte("Ready"))
			return
		}
		
		// Route based on path
		switch r.URL.Path {
		case "/sms":
			// Existing handler cho Alertmanager/VictoriaMetrics
			HandleAlertWebhook(w, r, cfg)
			
		case "/argocd", "/argocd/webhook":
			// New handler cho ArgoCD notifications
			HandleArgocdWebhook(w, r, cfg)
			
		case "/argocd/test":
			// Test endpoint cho ArgoCD
			if r.Method != http.MethodPost {
				http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
				return
			}
			HandleArgocdWebhook(w, r, cfg)
			
		default:
			log.Printf("[%s] ❌ 404 Not Found: %s\n", logTime, r.URL.Path)
			http.Error(w, "Not Found", http.StatusNotFound)
		}
	}
}