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
		logFile.Sync()

		var alertData AlertData
		if err := json.Unmarshal(body, &alertData); err == nil && len(alertData.Alerts) > 0 {
			if alertData.Alerts[0].Status == "" || alertData.Alerts[0].Labels["severity"] == "" {
			} else {
				processAlert(alertData, cfg, w, logFile)
				return
			}
		}

		http.Error(w, "invalid alert format", http.StatusBadRequest)
	}
}

func HandleArgoCD(cfg *config.Config, logFile *os.File) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		logFile.WriteString(fmt.Sprintf("[%s] ✅ HandleArgoCD CALLED!\n", time.Now().Format(time.RFC3339)))
		logFile.Sync()
		
		body, err := io.ReadAll(r.Body)
		if err != nil {
			http.Error(w, "cannot read request body", http.StatusBadRequest)
			return
		}
		defer r.Body.Close()

		logEntry := fmt.Sprintf("[%s] ArgoCD Webhook Received:\n%s\n\n", time.Now().Format(time.RFC3339), string(body))
		logFile.WriteString(logEntry)
		logFile.Sync()

		var notification ArgocdNotification
		if err := json.Unmarshal(body, &notification); err != nil {
			logFile.WriteString(fmt.Sprintf("[%s] ❌ Error parsing: %v\n", time.Now().Format(time.RFC3339), err))
			logFile.Sync()
			http.Error(w, "invalid ArgoCD notification format", http.StatusBadRequest)
			return
		}

		prettyJSON, _ := json.MarshalIndent(notification, "", "  ")
		logFile.WriteString(fmt.Sprintf("[%s] 📋 Parsed:\n%s\n", time.Now().Format(time.RFC3339), string(prettyJSON)))
		logFile.Sync()

		processArgocdNotification(notification, cfg, w, logFile)
	}
}

func Dispatcher(cfg *config.Config, logFile *os.File) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		logFile.WriteString(fmt.Sprintf("[%s] 🌐 Request: %s %s from %s\n", 
			time.Now().Format(time.RFC3339), r.Method, r.URL.Path, r.RemoteAddr))
		logFile.Sync()

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

		logFile.WriteString(fmt.Sprintf("[%s] 🔍 Path: '%s'\n", time.Now().Format(time.RFC3339), r.URL.Path))
		logFile.Sync()

		switch r.URL.Path {
		case "/sms":
			logFile.WriteString(fmt.Sprintf("[%s] ➡️ /sms handler\n", time.Now().Format(time.RFC3339)))
			logFile.Sync()
			HandleAlert(cfg, logFile)(w, r)

		case "/argocd", "/argocd/webhook":
			logFile.WriteString(fmt.Sprintf("[%s] ➡️ /argocd handler\n", time.Now().Format(time.RFC3339)))
			logFile.Sync()
			HandleArgoCD(cfg, logFile)(w, r)

		default:
			logFile.WriteString(fmt.Sprintf("[%s] ❌ 404: %s\n", time.Now().Format(time.RFC3339), r.URL.Path))
			logFile.Sync()
			http.Error(w, "Not Found", http.StatusNotFound)
		}
	}
}