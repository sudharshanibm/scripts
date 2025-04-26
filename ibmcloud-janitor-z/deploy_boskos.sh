#!/bin/bash

set -e

CONFIG_NAME=$1
NAMESPACE="test-pods"
CONFIGMAP_FILE="boskos/boskos-configmap.yaml"
MAX_WAIT=300  
INTERVAL=5    

if [ -z "$CONFIG_NAME" ]; then
    echo "Error: Config name is required."
    echo "Usage: ./deploy_boskos.sh <config-name>"
    exit 1
fi

# Handle External Secrets CRDs
echo "Setting up External Secrets..."

# Check and delete existing installation
if helm list -n external-secrets | grep -q external-secrets; then
    echo "Uninstalling existing External Secrets..."
    helm uninstall external-secrets -n external-secrets
fi

# Clean up any existing External Secrets CRDs
echo "Cleaning up any existing External Secrets CRDs..."
kubectl get crd | grep 'external-secrets.io' | awk '{print $1}' | xargs -r kubectl delete crd || true

echo "Adding External Secrets helm repo..."
helm repo add external-secrets https://charts.external-secrets.io
helm repo update

echo "Installing External Secrets with CRDs..."
helm install external-secrets \
    external-secrets/external-secrets \
    -n external-secrets \
    --create-namespace \
    --set installCRDs=true \
    --set webhook.port=10250 \
    --set webhook.service.port=10250 \
    --set webhook.service.targetPort=10250 \
    --set webhook.validatingWebhook.name=externalsecret-validate \
    --set webhook.validatingWebhook.webhooks[0].name=validate.externalsecret.external-secrets.io \
    --set webhook.validatingWebhook.webhooks[1].name=validate.clustersecretstore.external-secrets.io

echo "Waiting for External Secrets webhook to become ready..."
kubectl wait --for=condition=ready pod \
  -l app.kubernetes.io/component=webhook \
  -n external-secrets \
  --timeout=120s

echo "Waiting for External Secrets webhook endpoints to become available..."
timeout=120
elapsed=0
while true; do
  ready=$(kubectl get endpoints external-secrets-webhook -n external-secrets -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null)
  if [[ -n "$ready" ]]; then
    echo "Webhook endpoint is ready."
    break
  fi
  if (( elapsed >= timeout )); then
    echo "Timed out waiting for webhook endpoints."
    exit 1
  fi
  sleep 5
  elapsed=$((elapsed + 5))
done

# Proceed with Boskos resources
echo "Checking if namespace '$NAMESPACE' exists..."
if ! kubectl get namespace "$NAMESPACE" &>/dev/null; then
    echo "Namespace '$NAMESPACE' does not exist. Creating..."
    kubectl create namespace "$NAMESPACE"
else
    echo "Namespace '$NAMESPACE' already exists."
fi

echo "Deleting existing Boskos resources..."
kubectl delete -f boskos/ --ignore-not-found=true

echo "Updating $CONFIGMAP_FILE with new config name: $CONFIG_NAME"
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

echo "Waiting for resources to become ready..."
start_time=$(date +%s)
while true; do
    PODS=$(kubectl get pods -n "$NAMESPACE" --no-headers || true)
    CLUSTER_SECRET=$(kubectl get clustersecretstore -n "$NAMESPACE" --no-headers || true)
    EXTERNAL_SECRET=$(kubectl get externalsecrets -n "$NAMESPACE" --no-headers || true)

    PODS_READY=$(echo "$PODS" | grep -E 'Running' | wc -l)
    PODS_TOTAL=$(echo "$PODS" | wc -l)
    CLUSTER_SECRET_READY=$(echo "$CLUSTER_SECRET" | awk '{print $5}')
    CLUSTER_SECRET_STATUS=$(echo "$CLUSTER_SECRET" | awk '{print $3}')
    EXTERNAL_SECRET_READY=$(echo "$EXTERNAL_SECRET" | awk '{print $5}')
    EXTERNAL_SECRET_STATUS=$(echo "$EXTERNAL_SECRET" | awk '{print $4}')

    echo "Current status:"
    echo "Pods: $PODS_READY/$PODS_TOTAL ready"
    echo "ClusterSecretStore: Ready=$CLUSTER_SECRET_READY, Status=$CLUSTER_SECRET_STATUS"
    echo "ExternalSecrets: Ready=$EXTERNAL_SECRET_READY, Status=$EXTERNAL_SECRET_STATUS"

    if [[ "$PODS_READY" -eq "$PODS_TOTAL" && "$CLUSTER_SECRET_READY" == "True" && "$CLUSTER_SECRET_STATUS" == "Valid" && "$EXTERNAL_SECRET_READY" == "True" && "$EXTERNAL_SECRET_STATUS" == "SecretSynced" ]]; then
        echo "All resources are successfully initialized!"
        break
    fi

    current_time=$(date +%s)
    elapsed_time=$((current_time - start_time))
    if [ "$elapsed_time" -ge "$MAX_WAIT" ]; then
        echo "Timeout: Resources did not become ready within $MAX_WAIT seconds."
        break
    fi

    sleep "$INTERVAL"
done

echo "Final Resource Status:"
echo "Pods:"
kubectl get pods -n "$NAMESPACE"
echo "Deployments:"
kubectl get deployments -n "$NAMESPACE"
echo "Services:"
kubectl get services -n "$NAMESPACE"
echo "ClusterSecretStore:"
kubectl get clustersecretstore -n "$NAMESPACE"
echo "ExternalSecrets:"
kubectl get externalsecrets -n "$NAMESPACE"
