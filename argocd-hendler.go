package handler

import (
	"fmt"
	"net/http"
	"os"
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
	Sync           ArgocdSync       `json:"sync"`
	Health         ArgocdHealth     `json:"health"`
	OperationState ArgocdOperation  `json:"operationState"`
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

// processArgocdNotification xử lý ArgoCD notification và gửi SMS
func processArgocdNotification(notif ArgocdNotification, cfg *config.Config, w http.ResponseWriter, logFile *os.File) {
	// Build SMS message
	message := buildArgocdMessage(notif)
	if message == "" {
		logFile.WriteString(fmt.Sprintf("[%s] ⚠️ ArgoCD notification ignored (no significant event)\n", time.Now().Format(time.RFC3339)))
		w.WriteHeader(http.StatusOK)
		w.Write([]byte("ArgoCD notification ignored"))
		return
	}

	logFile.WriteString(fmt.Sprintf("[%s] 📤 Built ArgoCD message: %s\n", time.Now().Format(time.RFC3339), message))

	// Determine receiver
	receiver := determineArgocdReceiver(notif, cfg)
	logFile.WriteString(fmt.Sprintf("[%s] 🎯 Target receiver: %s\n", time.Now().Format(time.RFC3339), receiver.Name))

	// Forward SMS
	if err := forwarder.SendSMS(receiver.Mobile, message); err != nil {
		logFile.WriteString(fmt.Sprintf("[%s] ❌ Error sending ArgoCD SMS: %v\n", time.Now().Format(time.RFC3339), err))
		http.Error(w, "error forwarding SMS", http.StatusInternalServerError)
		return
	}

	logFile.WriteString(fmt.Sprintf("[%s] ✅ ArgoCD SMS sent to receiver: %s\n", time.Now().Format(time.RFC3339), receiver.Name))
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
	
	// Chỉ alert 2 trường hợp sync status
	shouldAlert := false
	alertType := ""
	
	// Các trường hợp cần alert
	switch {
	case syncStatus == "OutOfSync":
		shouldAlert = true
		alertType = "OUT OF SYNC"
	case syncStatus == "Unknown":
		shouldAlert = true
		alertType = "SYNC UNKNOWN"
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