# Hướng dẫn Update Code cho Repo Hiện Tại

## 📋 Tổng quan

Dựa trên cấu trúc code hiện tại của bạn, cần thực hiện các thay đổi sau:

### Files cần thay đổi:
1. ✏️ **handler/dispatcher.go** - REPLACE toàn bộ file
2. ➕ **handler/argocd_handler.go** - THÊM file mới
3. ✏️ **cmd/main.go** - UPDATE cách gọi handler
4. ✏️ **config.json** - OPTIONAL: thêm section argocd

### Files KHÔNG thay đổi:
- ✅ handler/handler.go - Giữ nguyên
- ✅ handler/types.go - Giữ nguyên  
- ✅ handler/utils.go - Giữ nguyên (nếu có)
- ✅ forwarder/forwarder.go - Giữ nguyên
- ✅ config/config.go - Giữ nguyên

---

## 🔧 Step-by-Step Update

### Step 1: Backup code hiện tại

```bash
cd /path/to/sms-devops-gateway

# Backup toàn bộ
cp -r . ../sms-devops-gateway.backup

# Hoặc chỉ backup files sẽ thay đổi
cp handler/dispatcher.go handler/dispatcher.go.backup
cp cmd/main.go cmd/main.go.backup
cp config.json config.json.backup
```

### Step 2: Thêm file mới - argocd_handler.go

```bash
# Tạo file mới trong handler/
cat > handler/argocd_handler.go << 'EOF'
[COPY NỘI DUNG TỪ ARTIFACT: argocd_handler.go]
EOF
```

**Hoặc dùng editor:**
```bash
nano handler/argocd_handler.go
# Paste nội dung từ artifact argocd_handler.go
```

### Step 3: Replace file dispatcher.go

```bash
# Backup file cũ (đã làm ở step 1)
# Replace với nội dung mới
cat > handler/dispatcher.go << 'EOF'
[COPY NỘI DUNG TỪ ARTIFACT: dispatcher.go mới]
EOF
```

**Key changes trong dispatcher.go:**
- ✅ Giữ nguyên function `HandleAlert()` - unchanged
- ➕ Thêm function `HandleArgoCD()` - new
- ➕ Thêm function `Dispatcher()` - new router

### Step 4: Update cmd/main.go

**TRƯỚC (main.go cũ):**
```go
package main

import (
	"log"
	"net/http"
	"os"
	"sms-devops-gateway/config"
	"sms-devops-gateway/handler"
)

func main() {
	cfg, err := config.LoadConfig("config.json")
	if err != nil {
		log.Fatalf("Failed to load config: %v", err)
	}

	logFile, err := os.OpenFile("/log/alerts.log", os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0644)
	if err != nil {
		log.Printf("Warning: Cannot open log file: %v", err)
		logFile = os.Stdout
	}
	defer logFile.Close()

	// CŨ: Chỉ có 1 endpoint
	http.HandleFunc("/sms", handler.HandleAlert(cfg, logFile))

	log.Println("Server starting on :8080")
	if err := http.ListenAndServe(":8080", nil); err != nil {
		log.Fatalf("Server failed: %v", err)
	}
}
```

**SAU (main.go mới):**
```go
package main

import (
	"log"
	"net/http"
	"os"
	"sms-devops-gateway/config"
	"sms-devops-gateway/handler"
)

func main() {
	cfg, err := config.LoadConfig("config.json")
	if err != nil {
		log.Fatalf("Failed to load config: %v", err)
	}

	logFile, err := os.OpenFile("/log/alerts.log", os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0644)
	if err != nil {
		log.Printf("Warning: Cannot open log file: %v", err)
		logFile = os.Stdout
	}
	defer logFile.Close()

	log.SetOutput(logFile)

	log.Println("🚀 SMS DevOps Gateway starting...")
	log.Println("📡 Endpoints:")
	log.Println("   - POST /sms     : VictoriaMetrics/Alertmanager")
	log.Println("   - POST /argocd  : ArgoCD notifications")
	log.Println("   - GET  /health  : Health check")

	// MỚI: Dùng Dispatcher để route nhiều endpoints
	http.HandleFunc("/", handler.Dispatcher(cfg, logFile))

	port := ":8080"
	log.Printf("✅ Server listening on %s", port)
	if err := http.ListenAndServe(port, nil); err != nil {
		log.Fatalf("Server failed: %v", err)
	}
}
```

**Thay đổi chính:**
```diff
- http.HandleFunc("/sms", handler.HandleAlert(cfg, logFile))
+ http.HandleFunc("/", handler.Dispatcher(cfg, logFile))
```

### Step 5: Update config.json (Optional)

```bash
# Backup
cp config.json config.json.backup

# Edit
nano config.json
```

**Thêm section argocd (optional, không bắt buộc):**
```json
{
  "receiver": [
    {
      "name": "alert-ops",
      "mobile": "0901234567, 0912345678"
    },
    {
      "name": "alert-devops",
      "mobile": "0923456789"
    }
  ],
  "default_receiver": {
    "mobile": "0978901234"
  },
  "argocd": {
    "enabled": true,
    "project_mapping": {
      "production": "alert-ops",
      "staging": "alert-devops"
    }
  }
}
```

**Lưu ý:** Section `argocd` là optional vì logic routing đã được hardcode trong `determineArgocdReceiver()`.

---

## 🧪 Test Local

### 1. Build và run

```bash
# Build
go mod tidy
go build -o sms-gateway cmd/main.go

# Run
./sms-gateway
```

**Expected output:**
```
🚀 SMS DevOps Gateway starting...
📡 Endpoints:
   - POST /sms     : VictoriaMetrics/Alertmanager
   - POST /argocd  : ArgoCD notifications
   - GET  /health  : Health check
✅ Server listening on :8080
```

### 2. Test health check

```bash
curl http://localhost:8080/health
# Expected: OK

curl http://localhost:8080/ready
# Expected: Ready
```

### 3. Test VictoriaMetrics endpoint (existing - KHÔNG ĐỔI)

```bash
# Test với alert cũ - phải vẫn work
curl -X POST http://localhost:8080/sms \
  -H "Content-Type: application/json" \
  -d '{
    "receiver": "alert-ops",
    "status": "firing",
    "alerts": [{
      "status": "firing",
      "labels": {
        "severity": "critical",
        "alertname": "TestAlert"
      },
      "annotations": {
        "summary": "Test alert"
      }
    }]
  }'

# Expected: HTTP 200
# Check logs: tail -f /log/alerts.log
```

### 4. Test ArgoCD endpoint (new)

```bash
curl -X POST http://localhost:8080/argocd \
  -H "Content-Type: application/json" \
  -d '{
    "message": "Application deployment FAILED",
    "app": {
      "metadata": {
        "name": "test-app",
        "namespace": "argocd"
      },
      "spec": {
        "project": "production",
        "destination": {
          "namespace": "prod"
        }
      },
      "status": {
        "sync": {
          "status": "OutOfSync"
        },
        "health": {
          "status": "Degraded"
        },
        "operationState": {
          "phase": "Failed",
          "message": "deployment failed"
        }
      }
    },
    "context": {
      "receiver": "alert-ops"
    }
  }'

# Expected: HTTP 200 OK
# Message: ArgoCD notification processed ✅
```

### 5. Verify logs

```bash
tail -f /log/alerts.log

# Phải thấy:
# [timestamp] 🌐 Request: POST /argocd from ...
# [timestamp] ArgoCD Webhook Received: {...}
# [timestamp] 📋 Parsed ArgoCD Notification: {...}
# [timestamp] 📤 Built ArgoCD message: [DEPLOY FAILED] App: test-app...
# [timestamp] 🎯 Target receiver: alert-ops
# [timestamp] ✅ ArgoCD SMS sent to receiver: alert-ops
```

---

## 🐳 Build Docker Image

```bash
# Build
docker build -t sms-devops-gateway:v2.0 .

# Test local
docker run -d \
  --name sms-gateway-test \
  -p 8080:8080 \
  -v $(pwd)/config.json:/config.json \
  sms-devops-gateway:v2.0

# Test
curl http://localhost:8080/health

# Check logs
docker logs -f sms-gateway-test

# Cleanup
docker stop sms-gateway-test
docker rm sms-gateway-test
```

---

## 🚀 Deploy to Kubernetes

```bash
# Tag và push
docker tag sms-devops-gateway:v2.0 your-registry.com/sms-devops-gateway:v2.0
docker push your-registry.com/sms-devops-gateway:v2.0

# Update deployment
kubectl set image deployment/sms-gateway \
  sms-gateway=your-registry.com/sms-devops-gateway:v2.0 \
  -n sms-devops-gateway

# Watch rollout
kubectl rollout status deployment/sms-gateway -n sms-devops-gateway

# Verify
kubectl get pods -n sms-devops-gateway
kubectl logs -f deployment/sms-gateway -n sms-devops-gateway
```

---

## ✅ Verification Checklist

### Functional Tests:

- [ ] Health endpoint: `curl http://service:8080/health` → OK
- [ ] Old VictoriaMetrics alerts still work: POST /sms → SMS sent
- [ ] Old Alertmanager alerts still work: POST /sms → SMS sent  
- [ ] New ArgoCD endpoint works: POST /argocd → SMS sent
- [ ] 404 for unknown paths: POST /unknown → 404
- [ ] Logs showing requests correctly

### Code Quality:

- [ ] `go build` không có errors
- [ ] `go vet ./...` pass
- [ ] No breaking changes to existing functionality
- [ ] All existing test files still pass (if any)

### Deployment:

- [ ] Docker image builds successfully
- [ ] K8s pods running and healthy
- [ ] Service endpoints accessible
- [ ] ConfigMap updated (if needed)
- [ ] No errors in pod logs

---

## 🔄 Rollback Plan

Nếu có vấn đề:

```bash
# Restore backup files
cp handler/dispatcher.go.backup handler/dispatcher.go
cp cmd/main.go.backup cmd/main.go
rm handler/argocd_handler.go

# Rebuild
go build -o sms-gateway cmd/main.go

# Or rollback K8s deployment
kubectl rollout undo deployment/sms-gateway -n sms-devops-gateway

# Or restore from backup
kubectl set image deployment/sms-gateway \
  sms-gateway=your-registry.com/sms-devops-gateway:v1.0 \
  -n sms-devops-gateway
```

---

## 📊 Comparison: Before vs After

### BEFORE:
```
Endpoints:
  POST /sms  → HandleAlert() → VictoriaMetrics/Alertmanager only
```

### AFTER:
```
Endpoints:
  POST /sms    → Dispatcher → HandleAlert() → VictoriaMetrics/Alertmanager
  POST /argocd → Dispatcher → HandleArgoCD() → ArgoCD notifications
  GET  /health → Dispatcher → Health check
  GET  /ready  → Dispatcher → Readiness check
```

**Key Points:**
- ✅ `/sms` endpoint vẫn hoạt động EXACTLY như cũ
- ✅ Không breaking changes
- ✅ Thêm `/argocd` endpoint mới
- ✅ Thêm health checks

---

## 🆘 Troubleshooting

### Issue 1: Build errors

```bash
# Check imports
go mod tidy

# Verify all files exist
ls -la handler/
# Phải có: dispatcher.go, handler.go, argocd_handler.go, types.go

# Check syntax
go fmt ./...
go vet ./...
```

### Issue 2: Dispatcher not routing correctly

```bash
# Check logs
tail -f /log/alerts.log

# Test each endpoint
curl -v http://localhost:8080/sms     # Should work
curl -v http://localhost:8080/argocd  # Should work  
curl -v http://localhost:8080/health  # Should work
curl -v http://localhost:8080/unknown # Should 404
```

### Issue 3: Old alerts stopped working

```bash
# Verify HandleAlert không bị thay đổi
diff handler/dispatcher.go.backup handler/dispatcher.go

# Hàm HandleAlert() phải giống y nguyên
# Chỉ thêm HandleArgoCD() và Dispatcher()
```

---

## 📞 Support

Nếu gặp vấn đề:
1. Check logs: `kubectl logs -f deployment/sms-gateway -n sms-devops-gateway`
2. Verify endpoints: `kubectl exec -it deployment/sms-gateway -- curl localhost:8080/health`
3. Compare with backup files
4. Rollback if needed

---

**Version:** 2.0  
**Updated:** December 2025