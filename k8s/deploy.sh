#!/bin/bash
# Kubernetes deployment script for Videre application
# This script deploys the entire backend stack to Kubernetes

set -e

echo "🚀 Starting Videre Kubernetes Deployment..."

# Create namespace
echo "📦 Creating Kubernetes namespace..."
kubectl apply -f k8s/namespace.yaml

# Apply configurations
echo "⚙️  Applying ConfigMap..."
kubectl apply -f k8s/configmap.yaml

# Apply secrets (update with actual values first!)
echo "🔐 Applying Secrets..."
echo "⚠️  Make sure to update k8s/secret.yaml with your actual credentials before deploying!"
# kubectl apply -f k8s/secret.yaml  # Uncomment after updating values

# Apply service account
echo "👤 Applying ServiceAccount..."
kubectl apply -f k8s/serviceaccount.yaml

# Apply deployment
echo "🚀 Deploying Backend..."
kubectl apply -f k8s/deployment.yaml

# Apply service
echo "📡 Exposing Service..."
kubectl apply -f k8s/service.yaml

# Apply network policy
echo "🔒 Applying Network Policy..."
kubectl apply -f k8s/networkpolicy.yaml

# Apply HPA
echo "📊 Applying HorizontalPodAutoscaler..."
kubectl apply -f k8s/hpa.yaml

# Apply ingress
echo "🌐 Applying Ingress..."
kubectl apply -f k8s/ingress.yaml

echo ""
echo "✅ Deployment complete!"
echo ""
echo "📋 Deployment Status:"
kubectl get deployments -n default
kubectl get services -n default
kubectl get pods -n default

echo ""
echo "🎯 Next steps:"
echo "1. Update k8s/secret.yaml with your actual credentials"
echo "2. Apply the secret: kubectl apply -f k8s/secret.yaml"
echo "3. Monitor logs: kubectl logs -f deployment/videre-backend"
echo "4. Port forward for testing: kubectl port-forward svc/videre-backend 3000:80"
