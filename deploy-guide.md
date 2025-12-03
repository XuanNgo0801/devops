# Hướng dẫn Deploy ArgoCD Integration - Step by Step

## 📋 Prerequisites

- [ ] Kubernetes cluster đang chạy
- [ ] ArgoCD đã được cài đặt
- [ ] SMS Gateway service đang hoạt động
- [ ] kubectl access với quyền admin
- [ ] Docker registry để push images

## 🚀 Deployment Steps

### Step 1: Backup Current Config

```bash
# Backup configmap hiện tại
kubectl get configmap sms-gateway-config -n sms-devops-gateway -o yaml > backup-config.yaml

# Backup ArgoCD notifications config (nếu có)
kubectl get configmap argocd-notifications-cm -n argocd -o yaml > backup-argocd-notif.yaml 2>/dev/null || echo "No existing config"
```

### Step 2: Update Source Code

```bash
cd sms-devops-gateway/

# Tạo file mới
cat > handler/argocd_handler.go << 'EOF'
[... paste argocd_handler.go content ...]
EOF

# Update dispatcher
cat > handler/dispatcher.go << 'EOF'
[... paste dispatcher.go content ...]
EOF
```

### Step 3: Update Config File

```bash
# Backup config hiện tại
cp config.json config.json.backup

# Update config với ArgoCD settings
cat > config.json << 'EOF'
{
  "receiver": [
    {
      "name": "alert-ops",
      "mobile": "0901234567, 0912345678",
      "description": "Production operations team"
    },
    {
      "name": "alert-devops",
      "mobile": "0923456789, 0934567890",
      "description": "DevOps team"
    },
    {
      "name": "alert-infra",
      "mobile": "0945678901",
      "description": "Infrastructure team"
    }
  ],
  "default_receiver": {
    "mobile": "0978901234"
  },
  "argocd": {
    "enabled": true,
    "project_mapping": {
      "production": "alert-ops",
      "staging": "alert-devops",
      "infra": "alert-infra"
    }
  }
}
EOF
```

### Step 4: Build và Push Docker Image

```bash
# Build image mới với tag version 2.0
docker build -t sms-devops-gateway:v2.0 .

# Tag cho registry
docker tag sms-devops-gateway:v2.0 your-registry.com/sms-devops-gateway:v2.0

# Push to registry
docker push your-registry.com/sms-devops-gateway:v2.0

# Verify image
docker images | grep sms-devops-gateway
```

### Step 5: Update Kubernetes ConfigMap

```bash
# Update configmap với config mới
kubectl create configmap sms-gateway-config \
  --from-file=config.json=config.json \
  -n sms-devops-gateway \
  --dry-run=client -o yaml | kubectl apply -f -

# Verify configmap
kubectl get configmap sms-gateway-config -n sms-devops-gateway -o yaml
```

### Step 6: Update Deployment

```bash
# Update image trong deployment
kubectl set image deployment/sms-gateway \
  sms-gateway=your-registry.com/sms-devops-gateway:v2.0 \
  -n sms-devops-gateway

# Hoặc edit deployment manifest
kubectl edit deployment sms-gateway -n sms-devops-gateway
# Thay đổi image: your-registry.com/sms-devops-gateway:v2.0

# Watch rollout status
kubectl rollout status deployment/sms-gateway -n sms-devops-gateway
```

### Step 7: Verify SMS Gateway

```bash
# Check pods are running
kubectl get pods -n sms-devops-gateway

# Check logs
kubectl logs -f deployment/sms-gateway -n sms-devops-gateway

# Test health endpoint
kubectl exec -it deployment/sms-gateway -n sms-devops-gateway -- \
  curl http://localhost:8080/health

# Test ArgoCD endpoint exists
kubectl exec -it deployment/sms-gateway -n sms-devops-gateway -- \
  curl -X POST http://localhost:8080/argocd \
  -H "Content-Type: application/json" \
  -d '{"message":"test"}'
```

### Step 8: Create ArgoCD Notifications ConfigMap

```bash
# Create file
cat > argocd-notifications-cm.yaml << 'EOF'
[... paste argocd-notifications-cm.yaml content ...]
EOF

# Apply configmap
kubectl apply -f argocd-notifications-cm.yaml

# Verify
kubectl get configmap argocd-notifications-cm -n argocd -o yaml
```

### Step 9: Restart ArgoCD Notifications Controller

```bash
# Restart controller để load config mới
kubectl rollout restart deployment/argocd-notifications-controller -n argocd

# Wait for ready
kubectl rollout status deployment/argocd-notifications-controller -n argocd

# Check logs
kubectl logs -f deployment/argocd-notifications-controller -n argocd
```

### Step 10: Test Connectivity

```bash
# Test từ ArgoCD namespace đến SMS Gateway
kubectl run test-curl --rm -it --restart=Never \
  --image=curlimages/curl:latest \
  -n argocd -- \
  curl -v http://sms-gateway.sms-devops-gateway.svc.cluster.local:8080/health

# Expected: HTTP/1.1 200 OK
```

### Step 11: Apply Test Application

```bash
# Create test application với annotations
cat > test-app.yaml << 'EOF'
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: test-sms-notification
  namespace: argocd
  annotations:
    notifications.argoproj.io/subscribe.on-deployed.sms-gateway: "alert-devops"
    notifications.argoproj.io/subscribe.on-deploy-failed.sms-gateway: "alert-devops"
spec:
  project: default
  source:
    repoURL: https://github.com/argoproj/argocd-example-apps
    targetRevision: HEAD
    path: guestbook
  destination:
    server: https://kubernetes.default.svc
    namespace: test-notifications
  syncPolicy:
    automated:
      prune: true
      selfHeal: false
    syncOptions:
    - CreateNamespace=true
EOF

kubectl apply -f test-app.yaml

# Wait for sync
kubectl wait --for=condition=Synced app/test-sms-notification -n argocd --timeout=300s
```

### Step 12: Verify SMS Sent

```bash
# Check SMS Gateway logs
kubectl logs -f deployment/sms-gateway -n sms-devops-gateway | grep ArgoCD

# Should see:
# [2025-12-03T...] 📥 ArgoCD Webhook Received
# [2025-12-03T...] 📤 Built ArgoCD message: [DEPLOYED] App: test-sms-notification...
# [2025-12-03T...] ✅ ArgoCD SMS sent to receiver: alert-devops

# Check ArgoCD notifications logs
kubectl logs deployment/argocd-notifications-controller -n argocd | grep test-sms-notification
```

### Step 13: Test Failed Deployment

```bash
# Tạo app sẽ fail để test notification
cat > test-fail-app.yaml << 'EOF'
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: test-fail-notification
  namespace: argocd
  annotations:
    notifications.argoproj.io/subscribe.on-deploy-failed.sms-gateway: "alert-devops"
spec:
  project: default
  source:
    repoURL: https://github.com/invalid/invalid-repo
    targetRevision: HEAD
    path: invalid
  destination:
    server: https://kubernetes.default.svc
    namespace: test-fail
EOF

kubectl apply -f test-fail-app.yaml

# Monitor logs
kubectl logs -f deployment/sms-gateway -n sms-devops-gateway
```

### Step 14: Apply to Production Apps

```bash
# List all applications
kubectl get applications -n argocd

# Add annotations to production apps
kubectl annotate app production-app-1 -n argocd \
  notifications.argoproj.io/subscribe.on-deploy-failed.sms-gateway=alert-ops \
  notifications.argoproj.io/subscribe.on-health-degraded.sms-gateway=alert-ops

kubectl annotate app production-app-2 -n argocd \
  notifications.argoproj.io/subscribe.on-deploy-failed.sms-gateway=alert-ops \
  notifications.argoproj.io/subscribe.on-health-degraded.sms-gateway=alert-ops

# Hoặc update hàng loạt
kubectl get app -n argocd -o name | xargs -I {} kubectl annotate {} \
  notifications.argoproj.io/subscribe.on-deploy-failed.sms-gateway=alert-ops
```

### Step 15: Cleanup Test Resources

```bash
# Remove test applications
kubectl delete app test-sms-notification -n argocd
kubectl delete app test-fail-notification -n argocd

# Remove test namespaces
kubectl delete namespace test-notifications
kubectl delete namespace test-fail
```

## ✅ Verification Checklist

- [ ] SMS Gateway pods are running
- [ ] New image version deployed (v2.0)
- [ ] ConfigMap updated with ArgoCD config
- [ ] ArgoCD notifications ConfigMap applied
- [ ] ArgoCD notifications controller restarted
- [ ] Connectivity test passed
- [ ] Test application received SMS
- [ ] Failed deployment test received SMS
- [ ] Production apps annotated
- [ ] Logs showing successful SMS sending

## 🔍 Quick Health Check

```bash
#!/bin/bash
echo "=== SMS Gateway Health Check ==="

echo "1. Check pods status:"
kubectl get pods -n sms-devops-gateway

echo -e "\n2. Check service:"
kubectl get svc -n sms-devops-gateway

echo -e "\n3. Check recent logs:"
kubectl logs --tail=20 deployment/sms-gateway -n sms-devops-gateway

echo -e "\n4. Test health endpoint:"
kubectl exec deployment/sms-gateway -n sms-devops-gateway -- \
  curl -s http://localhost:8080/health

echo -e "\n5. Check ArgoCD notifications controller:"
kubectl get pods -n argocd | grep notifications

echo -e "\n6. Check ArgoCD notifications config:"
kubectl get configmap argocd-notifications-cm -n argocd -o jsonpath='{.data.service\.webhook\.sms-gateway}'

echo -e "\n=== Health Check Complete ==="
```

## 🐛 Troubleshooting

### Issue: Pods not starting

```bash
# Check pod events
kubectl describe pod -n sms-devops-gateway -l app=sms-gateway

# Check image pull
kubectl get events -n sms-devops-gateway --sort-by='.lastTimestamp' | grep -i pull

# Verify image exists
docker pull your-registry.com/sms-devops-gateway:v2.0
```

### Issue: ConfigMap not loading

```bash
# Check configmap exists
kubectl get configmap sms-gateway-config -n sms-devops-gateway

# Check mount in pod
kubectl exec deployment/sms-gateway -n sms-devops-gateway -- cat /config.json

# Force reload
kubectl rollout restart deployment/sms-gateway -n sms-devops-gateway
```

### Issue: ArgoCD not sending webhooks

```bash
# Check ArgoCD notifications controller logs
kubectl logs -f deployment/argocd-notifications-controller -n argocd

# Verify service exists
kubectl get svc -n argocd | grep notifications

# Test webhook manually
kubectl exec -it deployment/argocd-notifications-controller -n argocd -- sh
curl -X POST http://sms-gateway.sms-devops-gateway.svc.cluster.local:8080/argocd \
  -H "Content-Type: application/json" \
  -d '{"message":"test","app":{"metadata":{"name":"test"}}}'
```

## 🔄 Rollback Plan

Nếu có vấn đề, rollback ngay:

```bash
# Rollback deployment
kubectl rollout undo deployment/sms-gateway -n sms-devops-gateway

# Restore old configmap
kubectl apply -f backup-config.yaml

# Restore ArgoCD config
kubectl apply -f backup-argocd-notif.yaml

# Verify rollback
kubectl rollout status deployment/sms-gateway -n sms-devops-gateway
```

## 📝 Post-Deployment Tasks

1. **Monitor logs** trong 24h đầu:
```bash
kubectl logs -f deployment/sms-gateway -n sms-devops-gateway
```

2. **Check SMS delivery** với team members

3. **Adjust routing** nếu cần:
```bash
kubectl edit configmap sms-gateway-config -n sms-devops-gateway
kubectl rollout restart deployment/sms-gateway -n sms-devops-gateway
```

4. **Document** receivers và routing logic

5. **Setup monitoring** cho SMS Gateway:
   - Prometheus metrics (nếu có)
   - Alert cho pod restarts
   - Alert cho failed SMS sends

## 📞 Support Contacts

- DevOps Team: devops@company.com
- On-call: +84-xxx-xxx-xxx
- Slack: #devops-alerts

---

**Deployment Date**: ___________  
**Deployed By**: ___________  
**Verified By**: ___________