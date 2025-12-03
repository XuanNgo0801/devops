package handler

import (
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"strings"
	"time"

	"sms-devops-gateway/config"
	"sms-devops-gateway/forwarder"
)

// ArgoCD Notification structures
type ArgocdNotification struct {
	Message     string                 `json:"message"`
	App         ArgocdApp              `json:"app"`
	Context     map[string]interface{} `json:"context"`
	ServiceType string                 `json:"serviceType"`
}

type ArgocdApp struct {
	Metadata ArgocdMetadata `json:"metadata"`
	Spec     ArgocdSpec     `json:"spec"`
	Status   ArgocdStatus   `json:"status"`
}

type ArgocdMetadata struct {
	Name      string `json:"name"`
	Namespace string `json:"namespace"`
}

type ArgocdSpec struct {
	Project     string      `json:"project"`
	Source      ArgocdSource `json:"source"`
	Destination ArgocdDest   `json:"destination"`
}

type ArgocdSource struct {
	RepoURL        string `json:"repoURL"`
	Path           string `json:"path"`
	TargetRevision string `json:"targetRevision"`
}

type ArgocdDest struct {
	Server    string `json:"server"`
	Namespace string `json:"namespace"`
}

type ArgocdStatus struct {
	Sync       ArgocdSync       `json:"sync"`
	Health     ArgocdHealth     `json:"health"`
	OperationState ArgocdOperation `json:"operationState"`
}

type ArgocdSync struct {
	Status   string `json:"status"`
	Revision string `json:"revision"`
}

type ArgocdHealth struct {
	Status  string `json:"status"`
	Message string `json:"message"`
}

type ArgocdOperation struct {
	Phase      string    `json:"phase"`
	Message    string    `json:"message"`
	StartedAt  time.Time `json:"startedAt"`
	FinishedAt time.Time `json:"finishedAt"`
}

// HandleArgocdWebhook xử lý webhook từ ArgoCD notifications
func HandleArgocdWebhook(w http.ResponseWriter, r *http.Request, cfg *config.Config) {
	logTime := time.Now().In(location).Format("2006-01-02T15:04:05-07:00")
	
	// Đọc request body
	body, err := io.ReadAll(r.Body)
	if err != nil {
		log.Printf("[%s] ❌ Error reading ArgoCD webhook body: %v\n", logTime, err)
		http.Error(w, "error reading request body", http.StatusBadRequest)
		return
	}
	defer r.Body.Close()

	// Log raw request
	log.Printf("[%s] 📥 ArgoCD Webhook Received:\n%s\n", logTime, string(body))

	// Parse ArgoCD notification
	var notification ArgocdNotification
	if err := json.Unmarshal(body, &notification); err != nil {
		log.Printf("[%s] ❌ Error parsing ArgoCD notification: %v\n", logTime, err)
		http.Error(w, "invalid ArgoCD notification format", http.StatusBadRequest)
		return
	}

	// Log parsed notification
	prettyJSON, _ := json.MarshalIndent(notification, "", "  ")
	log.Printf("[%s] 📋 Parsed ArgoCD Notification:\n%s\n", logTime, string(prettyJSON))

	// Build SMS message
	message := buildArgocdMessage(notification)
	if message == "" {
		log.Printf("[%s] ⚠️ ArgoCD notification ignored (no significant event)\n", logTime)
		w.WriteHeader(http.StatusOK)
		w.Write([]byte("ArgoCD notification ignored"))
		return
	}

	log.Printf("[%s] 📤 Built ArgoCD message: %s\n", logTime, message)

	// Determine receiver (từ annotations hoặc project)
	receiver := determineArgocdReceiver(notification, cfg)
	log.Printf("[%s] 🎯 Target receiver: %s\n", logTime, receiver.Name)

	// Forward SMS
	if err := forwarder.SendSMS(receiver.Mobile, message); err != nil {
		log.Printf("[%s] ❌ Error sending ArgoCD SMS: %v\n", logTime, err)
		http.Error(w, "error forwarding SMS", http.StatusInternalServerError)
		return
	}

	log.Printf("[%s] ✅ ArgoCD SMS sent to receiver: %s\n", logTime, receiver.Name)
	w.WriteHeader(http.StatusOK)
	w.Write([]byte("ArgoCD notification processed ✅"))
}

// buildArgocdMessage tạo message từ ArgoCD notification
func buildArgocdMessage(notif ArgocdNotification) string {
	app := notif.App
	appName := app.Metadata.Name
	namespace := app.Spec.Destination.Namespace
	project := app.Spec.Project
	
	syncStatus := app.Status.Sync.Status
	healthStatus := app.Status.Health.Status
	phase := app.Status.OperationState.Phase
	
	// Chỉ alert các sự kiện quan trọng
	shouldAlert := false
	alertType := ""
	
	// Các trường hợp cần alert
	switch {
	case phase == "Failed":
		shouldAlert = true
		alertType = "DEPLOY FAILED"
	case phase == "Error":
		shouldAlert = true
		alertType = "DEPLOY ERROR"
	case syncStatus == "OutOfSync":
		shouldAlert = true
		alertType = "OUT OF SYNC"
	case healthStatus == "Degraded":
		shouldAlert = true
		alertType = "DEGRADED"
	case healthStatus == "Missing":
		shouldAlert = true
		alertType = "MISSING"
	case phase == "Succeeded" && strings.Contains(strings.ToLower(notif.Message), "deploy"):
		shouldAlert = true
		alertType = "DEPLOYED"
	case healthStatus == "Healthy" && syncStatus == "Synced" && phase == "Succeeded":
		shouldAlert = true
		alertType = "HEALTHY"
	}
	
	if !shouldAlert {
		return ""
	}
	
	// Format message
	var parts []string
	parts = append(parts, fmt.Sprintf("[%s]", alertType))
	parts = append(parts, fmt.Sprintf("App: %s", appName))
	
	if project != "" && project != "default" {
		parts = append(parts, fmt.Sprintf("Project: %s", project))
	}
	
	if namespace != "" {
		parts = append(parts, fmt.Sprintf("NS: %s", namespace))
	}
	
	// Thêm sync status nếu có vấn đề
	if syncStatus != "" && syncStatus != "Synced" {
		parts = append(parts, fmt.Sprintf("Sync: %s", syncStatus))
	}
	
	// Thêm health status nếu có vấn đề
	if healthStatus != "" && healthStatus != "Healthy" {
		parts = append(parts, fmt.Sprintf("Health: %s", healthStatus))
	}
	
	// Thêm message từ operation state
	if app.Status.OperationState.Message != "" {
		parts = append(parts, fmt.Sprintf("Msg: %s", truncateString(app.Status.OperationState.Message, 50)))
	}
	
	// Thêm custom message nếu có
	if notif.Message != "" && notif.Message != app.Status.OperationState.Message {
		parts = append(parts, truncateString(notif.Message, 50))
	}
	
	return strings.Join(parts, " | ")
}

// determineArgocdReceiver xác định receiver cho ArgoCD notification
func determineArgocdReceiver(notif ArgocdNotification, cfg *config.Config) config.Receiver {
	// Ưu tiên 1: Lấy từ context nếu có receiver được chỉ định
	if contextReceiver, ok := notif.Context["receiver"].(string); ok && contextReceiver != "" {
		for _, r := range cfg.Receiver {
			if r.Name == contextReceiver {
				return r
			}
		}
	}
	
	// Ưu tiên 2: Dựa vào project name
	project := notif.App.Spec.Project
	projectMapping := map[string]string{
		"infra":        "alert-infra",
		"devops":       "alert-devops",
		"ops":          "alert-ops",
		"d1-lgc":       "alert-d1-lgc-devops",
		"production":   "alert-ops",
		"staging":      "alert-devops",
	}
	
	if receiverName, ok := projectMapping[strings.ToLower(project)]; ok {
		for _, r := range cfg.Receiver {
			if r.Name == receiverName {
				return r
			}
		}
	}
	
	// Ưu tiên 3: Dựa vào namespace
	namespace := notif.App.Spec.Destination.Namespace
	if strings.Contains(namespace, "infra") {
		for _, r := range cfg.Receiver {
			if r.Name == "alert-infra" {
				return r
			}
		}
	}
	if strings.Contains(namespace, "monitoring") {
		for _, r := range cfg.Receiver {
			if r.Name == "alert-devops" {
				return r
			}
		}
	}
	
	// Default: trả về default receiver
	return config.Receiver{
		Name:   "default",
		Mobile: cfg.DefaultReceiver.Mobile,
	}
}

// truncateString cắt string nếu quá dài
func truncateString(s string, maxLen int) string {
	if len(s) <= maxLen {
		return s
	}
	return s[:maxLen-3] + "..."
}