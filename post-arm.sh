#!/bin/bash
source .env

# Ensure correct cluster context
az account set --subscription "${AZ_SUBSCRIPTION}"
az aks get-credentials -g "${AZ_GROUP}"  -n "${AZ_GROUP}-k8s" --overwrite-existing

# Create the helm service account
echo
echo " Creating Helm Tiller service account"
kubectl create -f manifests/tiller-service-account.yml > /dev/null || true

# Deploys the helm service on the cluster
echo
echo " Initialising Helm"
helm init --service-account tiller

echo
echo " Creating namespaces"
kubectl create -f manifests/namespaces.yaml > /dev/null || true

# Fetch Azure ID's from Keyvault (Created in pre-arm.sh)
AZ_SUBSCRIPTION_ID=$(az account show --query "id"  -o tsv)
AZ_TENANT_ID=$(az account show --query "tenantId"  -o tsv)
AZ_DNS_SP_NAME="${AZ_GROUP}-dns-sp"
AZ_DNS_SP_PASSWORD=$(az keyvault secret show --name "${AZ_DNS_SP_NAME}-password" --vault-name SDPVault --query value -o tsv)
AZ_DNS_SP_ID=$(az keyvault secret show --name "${AZ_DNS_SP_NAME}-app-id" --vault-name SDPVault --query value -o tsv)
AZ_BACKUP_SP_NAME="sdpaks-common-velero-sp"
AZ_BACKUP_SP_PASSWORD=$(az keyvault secret show --name "${AZ_BACKUP_SP_NAME}-password" --vault-name SDPVault --query value -o tsv)
AZ_BACKUP_SP_ID=$(az keyvault secret show --name "${AZ_BACKUP_SP_NAME}-app-id" --vault-name SDPVault --query value -o tsv)
AZ_CLUSTER_GROUP=$(az aks show --resource-group $AZ_GROUP --name "${AZ_GROUP}-k8s" --query nodeResourceGroup -o tsv)

#
# Create external dns secret
#

# Use custom configuration file
echo
echo " Creating azure.json file with DNS service principal information"
cat << EOF > azure.json
{
  "tenantId": "$AZ_TENANT_ID",
  "subscriptionId": "$AZ_SUBSCRIPTION_ID",
  "aadClientId": "$AZ_DNS_SP_ID",
  "aadClientSecret": "$AZ_DNS_SP_PASSWORD",
  "resourceGroup": "$AZ_DNS_GROUP"
}
EOF

# Create a secret so that external-dns can connect to the DNS zone
echo
echo " Creating Kubernetes secret (infrastructure/azure-dns-config-file) from azure.json file"
kubectl create secret generic azure-dns-config-file --from-file=azure.json -n external-dns --dry-run -o yaml | kubectl apply -f - > /dev/null || true
rm -f azure.json

#
# Create sealed secrets secret
#

az keyvault secret show --name "sealed-secrets-key" --vault-name SDPVault --query value -o tsv > tmp.key
az keyvault secret show --name "sealed-secrets-cert" --vault-name SDPVault --query value -o tsv > tmp.crt
kubectl create secret tls -n sealed-secrets sealed-secret-custom-key --cert=tmp.crt --key=tmp.key --dry-run -o yaml | kubectl apply -f - > /dev/null || true
rm -f tmp.key tmp.crt

function key_exists {
  az keyvault secret show --name $1 --vault-name SDPVault > /dev/null
}

# Create ssh-key
FLUX_KEY_NAME="${AZ_GROUP}-flux-key"
if ! key_exists $FLUX_KEY_NAME; then
    echo
    echo " Creating flux ssh key"
    ssh-keygen -q -N "" -C "flux@${PREFIX}sdpaks.equinor.com" -f ./identity
    az keyvault secret set --vault-name SDPVault -n $FLUX_KEY_NAME -f './identity' > /dev/null
    echo
    echo "Add flux public key to flux git repo:"
    echo
    cat identity.pub
    rm -f identity identity.pub
fi

FLUX_KEY="$(az keyvault secret show --name "$FLUX_KEY_NAME" --vault-name SDPVault --query value -o tsv)"

kubectl -n flux create secret generic flux-ssh --from-literal=identity="$FLUX_KEY" --dry-run -o yaml | kubectl apply -f - > /dev/null || true

# Add flux repo to helm
echo
echo " Adding fluxcd/flux repository to Helm"
helm repo add fluxcd https://fluxcd.github.io/flux > /dev/null

# Install flux with helmoperator
echo
echo " Installing or upgrading Flux with Helm operator in the flux namespace"
helm upgrade --install flux \
    --namespace flux \
    --set rbac.create=true \
    --set helmOperator.create=true \
    --set helmOperator.createCRD=true \
    --set git.url="$FLUX_GITOPS_REPO" \
    --set git.branch=$FLUX_GITOPS_BRANCH \
    --set git.path=$FLUX_GITOPS_PATH \
    --set additionalArgs={--manifest-generation=true} \
    --set git.secretName="flux-ssh" \
    fluxcd/flux > /dev/null

# Create cluster secret for velero

echo
echo " Generating velero credentials..."

cat << EOF > cloud
AZURE_SUBSCRIPTION_ID=${AZ_SUBSCRIPTION_ID}
AZURE_TENANT_ID=${AZ_TENANT_ID} 
AZURE_CLIENT_ID=${AZ_BACKUP_SP_ID} 
AZURE_CLIENT_SECRET=${AZ_BACKUP_SP_PASSWORD} 
AZURE_RESOURCE_GROUP=${AZ_CLUSTER_GROUP} 
EOF

kubectl create secret generic velero-credentials --from-file=cloud -n velero --dry-run -o yaml | kubectl apply -f - > /dev/null || true
rm -f azure.json & rm -f cloud

echo " Script completed."