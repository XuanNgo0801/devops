package handler

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"time"
	
	"sms-devops-gateway/config"
)

// HandleAlert - Existing handler cho VictoriaMetrics/Alertmanager (GIỮ NGUYÊN)
func HandleAlert(cfg *config.Config, logFile *os.File) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		body, err := io.ReadAll(r.Body)
		if err != nil {
			http.Error(w, "cannot read request body", http.StatusBadRequest)
			return
		}
		defer r.Body.Close()

		logEntry := fmt.Sprintf("[%s] Received alert:\n%s\n\n", time.Now().Format(time.RFC3339), string(body))
		logFile.WriteString(logEntry)

		// Try K8s format
		var alertData AlertData
		if err := json.Unmarshal(body, &alertData); err == nil && len(alertData.Alerts) > 0 {
			if alertData.Alerts[0].Status == "" || alertData.Alerts[0].Labels["severity"] == "" {
				// thiếu status/severity, sẽ rơi xuống http.Error ở dưới
			} else {
				processAlert(alertData, cfg, w, logFile)
				return
			}
		}

		http.Error(w, "invalid alert format", http.StatusBadRequest)
	}
}

// HandleArgoCD - NEW handler cho ArgoCD notifications
func HandleArgoCD(cfg *config.Config, logFile *os.File) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		body, err := io.ReadAll(r.Body)
		if err != nil {
			http.Error(w, "cannot read request body", http.StatusBadRequest)
			return
		}
		defer r.Body.Close()

		logEntry := fmt.Sprintf("[%s] ArgoCD Webhook Received:\n%s\n\n", time.Now().Format(time.RFC3339), string(body))
		logFile.WriteString(logEntry)

		// Parse ArgoCD notification
		var notification ArgocdNotification
		if err := json.Unmarshal(body, &notification); err != nil {
			logFile.WriteString(fmt.Sprintf("[%s] ❌ Error parsing ArgoCD notification: %v\n", time.Now().Format(time.RFC3339), err))
			http.Error(w, "invalid ArgoCD notification format", http.StatusBadRequest)
			return
		}

		// Log parsed notification
		prettyJSON, _ := json.MarshalIndent(notification, "", "  ")
		logFile.WriteString(fmt.Sprintf("[%s] 📋 Parsed ArgoCD Notification:\n%s\n", time.Now().Format(time.RFC3339), string(prettyJSON)))

		// Process ArgoCD notification
		processArgocdNotification(notification, cfg, w, logFile)
	}
}

// Dispatcher - Router chính để phân luồng requests
func Dispatcher(cfg *config.Config, logFile *os.File) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		logFile.WriteString(fmt.Sprintf("[%s] 🌐 Request: %s %s from %s\n", 
			time.Now().Format(time.RFC3339), r.Method, r.URL.Path, r.RemoteAddr))

		// Health check endpoints
		if r.URL.Path == "/health" || r.URL.Path == "/healthz" {
			w.WriteHeader(http.StatusOK)
			w.Write([]byte("OK"))
			return
		}

		if r.URL.Path == "/ready" || r.URL.Path == "/readyz" {
			w.WriteHeader(http.StatusOK)
			w.Write([]byte("Ready"))
			return
		}

		// Route based on path
		switch r.URL.Path {
		case "/sms":
			// Existing handler cho Alertmanager/VictoriaMetrics
			HandleAlert(cfg, logFile)(w, r)

		case "/argocd", "/argocd/webhook":
			// NEW handler cho ArgoCD notifications
			HandleArgoCD(cfg, logFile)(w, r)

		default:
			logFile.WriteString(fmt.Sprintf("[%s] ❌ 404 Not Found: %s\n", time.Now().Format(time.RFC3339), r.URL.Path))
			http.Error(w, "Not Found", http.StatusNotFound)
		}
	}
}