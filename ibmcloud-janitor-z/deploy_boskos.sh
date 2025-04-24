#!/bin/bash

set -e

CONFIG_NAME=$1
NAMESPACE="test-pods"
CONFIGMAP_FILE="boskos/boskos-configmap.yaml"
MAX_WAIT=300
INTERVAL=5

if [ -z "$CONFIG_NAME" ]; then
    echo "Error: VPC name is required."
    echo "Usage: ./deploy_boskos.sh <vpc-name>"
    exit 1
fi

echo "Checking for required CRDs..."
CRD_COUNT=$(kubectl get crds | grep -c "externalsecrets.external-secrets.io" || true)
if [ "$CRD_COUNT" -eq 0 ]; then
    echo "External Secrets CRDs not found. Installing..."
    helm repo add external-secrets https://charts.external-secrets.io
    helm repo update
    helm install external-secrets \
        external-secrets/external-secrets \
        -n external-secrets \
        --create-namespace \
        --set installCRDs=true \
        --wait \
        --timeout 5m

    echo "Waiting for external-secrets-webhook service to be ready..."
    for i in {1..60}; do
    if kubectl get svc external-secrets-webhook -n external-secrets &>/dev/null; then
        echo "external-secrets-webhook service is ready."
        break
    fi
    echo "Waiting for external-secrets-webhook service... ($i/60)"
    sleep 5
    done
else
    echo "External Secrets CRDs already installed."
fi

echo "Ensuring namespace '$NAMESPACE' exists..."
kubectl get namespace "$NAMESPACE" &>/dev/null || kubectl create namespace "$NAMESPACE"

echo "Deleting existing Boskos resources..."
kubectl delete -f boskos/ --ignore-not-found=true

echo "Writing new config to $CONFIGMAP_FILE..."
cat <<EOF > "$CONFIGMAP_FILE"
apiVersion: v1
kind: ConfigMap
metadata:
  name: resources
  namespace: $NAMESPACE
data:
  boskos-resources.yaml: |
    resources:
      - type: "vpc-service"
        state: free
        names:
          - "$CONFIG_NAME"
EOF

echo "Applying Boskos configuration..."
kubectl apply -f boskos/

echo "Waiting for resources to become ready (timeout: ${MAX_WAIT}s)..."
start_time=$(date +%s)
while true; do
    PODS=$(kubectl get pods -n "$NAMESPACE" --no-headers 2>/dev/null || true)
    PODS_READY=$(echo "$PODS" | grep -E 'Running' | wc -l)
    PODS_TOTAL=$(echo "$PODS" | wc -l)

    CS=$(kubectl get clustersecretstore -n "$NAMESPACE" --no-headers 2>/dev/null || true)
    ES=$(kubectl get externalsecrets -n "$NAMESPACE" --no-headers 2>/dev/null || true)

    CS_READY=$(echo "$CS" | awk '{print $5}')
    CS_STATUS=$(echo "$CS" | awk '{print $3}')
    ES_READY=$(echo "$ES" | awk '{print $5}')
    ES_STATUS=$(echo "$ES" | awk '{print $4}')

    if [[ "$PODS_READY" -eq "$PODS_TOTAL" && "$PODS_TOTAL" -gt 0 && "$CS_READY" == "True" && "$CS_STATUS" == "Valid" && "$ES_READY" == "True" && "$ES_STATUS" == "SecretSynced" ]]; then
        echo "All resources are ready."
        break
    fi

    elapsed=$(( $(date +%s) - start_time ))
    if [ "$elapsed" -ge "$MAX_WAIT" ]; then
        echo "Timeout reached. Resources not ready."
        break
    fi

    sleep "$INTERVAL"
done

echo "Final Resource Status:"
kubectl get pods -n "$NAMESPACE"
kubectl get deployments -n "$NAMESPACE"
kubectl get services -n "$NAMESPACE"
kubectl get clustersecretstore -n "$NAMESPACE"
kubectl get externalsecrets -n "$NAMESPACE"
