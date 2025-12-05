package handler

import (
	"fmt"
	"net/http"
	"os"
	"strings"

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
	Phase      string `json:"phase"`
	Message    string `json:"message"`
}

// processArgocdNotification xử lý ArgoCD notification và gửi SMS
func processArgocdNotification(notif ArgocdNotification, cfg *config.Config, w http.ResponseWriter, logFile *os.File) {
	// Build SMS message
	message := buildArgocdMessage(notif)
	if message == "" {
		logFile.WriteString(fmt.Sprintf("⚠️ ArgoCD notification ignored (no significant event)\n"))
		w.WriteHeader(http.StatusOK)
		w.Write([]byte("ArgoCD notification ignored"))
		return
	}

	logFile.WriteString(fmt.Sprintf("📤 Built ArgoCD message: %s\n", message))

	// Determine receiver
	receiver := determineArgocdReceiver(notif, cfg)
	logFile.WriteString(fmt.Sprintf("🎯 Target receiver: %s\n", receiver.Name))

	// Forward SMS
	if err := forwarder.SendSMS(receiver.Mobile, message); err != nil {
		logFile.WriteString(fmt.Sprintf("❌ Error sending ArgoCD SMS: %v\n", err))
		http.Error(w, "error forwarding SMS", http.StatusInternalServerError)
		return
	}

	logFile.WriteString(fmt.Sprintf("✅ ArgoCD SMS sent to receiver: %s\n", receiver.Name))
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
	
	// Thêm sync status
	if syncStatus != "" {
		parts = append(parts, fmt.Sprintf("Sync: %s", syncStatus))
	}
	
	// Thêm message từ operation state nếu có
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
	appName := notif.App.Metadata.Name
	
	// Ưu tiên 1: Lấy từ context nếu có receiver được chỉ định (từ annotation)
	if contextReceiver, ok := notif.Context["receiver"].(string); ok && contextReceiver != "" {
		for _, r := range cfg.Receiver {
			if r.Name == contextReceiver {
				return r
			}
		}
	}
	
	// Ưu tiên 2: Exact match - Dựa vào tên application (từ config.json)
	if cfg.ArgoCD != nil && cfg.ArgoCD.AppMapping != nil {
		if receiverName, ok := cfg.ArgoCD.AppMapping[appName]; ok {
			for _, r := range cfg.Receiver {
				if r.Name == receiverName {
					return r
				}
			}
		}
	}
	
	// Ưu tiên 3: Prefix matching - Dựa vào prefix của app name (từ config.json)
	if cfg.ArgoCD != nil && cfg.ArgoCD.AppPrefixMapping != nil {
		for prefix, receiverName := range cfg.ArgoCD.AppPrefixMapping {
			if strings.HasPrefix(appName, prefix) {
				for _, r := range cfg.Receiver {
					if r.Name == receiverName {
						return r
					}
				}
			}
		}
	}
	
	// Ưu tiên 4: Project mapping (fallback)
	if cfg.ArgoCD != nil && cfg.ArgoCD.ProjectMapping != nil {
		project := notif.App.Spec.Project
		if receiverName, ok := cfg.ArgoCD.ProjectMapping[strings.ToLower(project)]; ok {
			for _, r := range cfg.Receiver {
				if r.Name == receiverName {
					return r
				}
			}
		}
	}
	
	// Ưu tiên 5: Namespace mapping (fallback)
	if cfg.ArgoCD != nil && cfg.ArgoCD.NamespaceMapping != nil {
		namespace := notif.App.Spec.Destination.Namespace
		for nsPattern, receiverName := range cfg.ArgoCD.NamespaceMapping {
			if strings.Contains(namespace, nsPattern) {
				for _, r := range cfg.Receiver {
					if r.Name == receiverName {
						return r
					}
				}
			}
		}
	}
	
	// Default: Dùng default_receiver từ ArgoCD config hoặc alert-devops
	defaultReceiverName := "alert-devops"
	if cfg.ArgoCD != nil && cfg.ArgoCD.DefaultReceiver != "" {
		defaultReceiverName = cfg.ArgoCD.DefaultReceiver
	}
	
	for _, r := range cfg.Receiver {
		if r.Name == defaultReceiverName {
			return r
		}
	}
	
	// Last fallback: default receiver từ config
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