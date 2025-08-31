# === variables ===
SUBSCRIPTION_ID="cc57cd42-dede-4674-b810-a0fbde41504a"
RG="funcapp-rg"
REGION="eastus"                    # use a Flex Consumption-supported region
STORAGE="func${RANDOM}sa"          # must be globally unique, lowercase
APP="func-${RANDOM}-python"        # must be globally unique
MI_NAME="func-host-storage-user"

# login + sub
az login
az account set --subscription "$SUBSCRIPTION_ID"

# resource group
az group create -n "$RG" -l "$REGION"

# storage (no shared key access; MI-based)
az storage account create \
  -n "$STORAGE" -g "$RG" -l "$REGION" \
  --sku Standard_LRS \
  --allow-blob-public-access false \
  --allow-shared-key-access false   # recommended with MI

# user-assigned managed identity (UAMI)
MI_JSON=$(az identity create -g "$RG" -n "$MI_NAME" -l "$REGION" -o json)
MI_CLIENT_ID=$(echo "$MI_JSON" | jq -r .clientId)
MI_PRINCIPAL_ID=$(echo "$MI_JSON" | jq -r .principalId)

# grant storage role to UAMI
STG_ID=$(az storage account show -n "$STORAGE" -g "$RG" --query id -o tsv)
az role assignment create \
  --assignee-object-id "$MI_PRINCIPAL_ID" \
  --assignee-principal-type ServicePrincipal \
  --role "Storage Blob Data Owner" \
  --scope "$STG_ID"

# create Function App (Flex Consumption, Python 3.11)
az functionapp create \
  --resource-group "$RG" \
  --name "$APP" \
  --flexconsumption-location "$REGION" \
  --runtime python \
  --runtime-version 3.11 \
  --storage-account "$STORAGE" \
  --deployment-storage-auth-type UserAssignedIdentity \
  --deployment-storage-auth-value "$MI_NAME"

# wire app settings to use MI for storage & insights
az functionapp config appsettings set -g "$RG" -n "$APP" --settings \
  AzureWebJobsStorage__accountName="$STORAGE" \
  AzureWebJobsStorage__credential="managedidentity" \
  AzureWebJobsStorage__clientId="$MI_CLIENT_ID" \
  APPLICATIONINSIGHTS_AUTHENTICATION_STRING="ClientId=$MI_CLIENT_ID;Authorization=AAD"

# remove legacy connection string if present
az functionapp config appsettings delete -g "$RG" -n "$APP" --setting-names AzureWebJobsStorage
