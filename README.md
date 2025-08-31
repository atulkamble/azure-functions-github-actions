Awesome—let’s spin up an Azure Functions app and wire it to GitHub Actions CI/CD (secure OIDC, Flex Consumption, Python). I’ll give you a ready-to-push repo layout, CLI to provision Azure, and a drop-in workflow.

# 1) Repo layout (Python HTTP trigger)

```
azure-functions-github/
├─ .github/workflows/deploy.yml
├─ .gitignore
├─ host.json
├─ requirements.txt
├─ local.settings.json.example
└─ HttpExample/__init__.py
```

**Files**

**`host.json`**

```json
{
  "version": "2.0"
}
```

**`requirements.txt`**

```
azure-functions
```

**`local.settings.json.example`** (don’t commit secrets)

```json
{
  "IsEncrypted": false,
  "Values": {
    "AzureWebJobsStorage": "UseDevelopmentStorage=true",
    "FUNCTIONS_WORKER_RUNTIME": "python"
  }
}
```

**`HttpExample/__init__.py`**

```python
import azure.functions as func

app = func.FunctionApp(http_auth_level=func.AuthLevel.ANONYMOUS)

@app.function_name(name="HttpExample")
@app.route(route="hello", methods=[func.HttpMethod.GET, func.HttpMethod.POST])
def http_example(req: func.HttpRequest) -> func.HttpResponse:
    name = req.params.get("name") or (req.get_json().get("name") if req.method == "POST" else None)
    msg = f"Hello {name} 👋" if name else "Hello from Azure Functions!"
    return func.HttpResponse(msg, mimetype="text/plain")
```

> You can also scaffold this locally with **Functions Core Tools** (`func init`, `func new`) if you prefer. ([Microsoft Learn][1])

---

# 2) Provision Azure (Flex Consumption + OIDC-ready)

> Run once from your shell (replace values). This follows Microsoft’s current Flex Consumption + managed identity guidance. ([Microsoft Learn][1])

```bash
# === variables ===
SUBSCRIPTION_ID="<your-sub-id>"
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
```

---

# 3) Secure GitHub OIDC (recommended)

> OIDC is the current best practice for Azure auth in Actions; you don’t store secrets. Steps summarized from the official action docs. ([GitHub][2])

1. In Azure, create a **federated credential** on the **user-assigned managed identity** (`$MI_NAME`) targeting your GitHub repo/branch (Azure Portal → Managed Identity → Federated credentials → “GitHub Actions” template).
   Save these values as **Repo → Settings → Variables** (not secrets):

   * `AZURE_CLIENT_ID` = *UAMI* client ID
   * `AZURE_TENANT_ID` = your tenant ID
   * `AZURE_SUBSCRIPTION_ID` = your subscription ID

2. Also assign the UAMI **Website Contributor** role scoped to the Function App. ([GitHub][2])

---

# 4) GitHub Actions workflow

**`.github/workflows/deploy.yml`**

```yaml
name: Deploy Azure Functions (Python / Flex)

on:
  push:
    branches: [ "main" ]
  workflow_dispatch:

permissions:
  id-token: write   # required for OIDC
  contents: read

env:
  AZURE_FUNCTIONAPP_NAME: "${{ vars.AZURE_FUNCTIONAPP_NAME }}"   # set repo variable to your app name
  AZURE_FUNCTIONAPP_PROJECT_PATH: "."                            # project root

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Setup Python
        uses: actions/setup-python@v5
        with:
          python-version: "3.11"
      - name: Install deps
        run: |
          python -m pip install --upgrade pip
          pip install -r requirements.txt
      - name: Package (zip) artifact
        run: |
          zip -r functionapp.zip . -x ".git/*" ".github/*" "local.settings.json"
      - name: Upload artifact
        uses: actions/upload-artifact@v4
        with:
          name: functionapp
          path: functionapp.zip

  deploy:
    runs-on: ubuntu-latest
    needs: build
    steps:
      - uses: actions/download-artifact@v4
        with:
          name: functionapp
          path: .
      - name: Azure Login (OIDC)
        uses: azure/login@v2
        with:
          client-id: ${{ vars.AZURE_CLIENT_ID }}
          tenant-id: ${{ vars.AZURE_TENANT_ID }}
          subscription-id: ${{ vars.AZURE_SUBSCRIPTION_ID }}
      - name: Deploy to Azure Functions
        uses: Azure/functions-action@v1
        with:
          app-name: ${{ env.AZURE_FUNCTIONAPP_NAME }}
          package: functionapp.zip
```

Notes:

* The **Functions Action** supports Flex Consumption; OIDC is the recommended auth. If you ever use publish profiles or SPs, the action shows those patterns, but they’re not recommended. ([GitHub][2])
* If you’d rather let the **Azure Portal → Deployment Center** write this YAML for you, that’s also supported. ([GitHub][2], [Microsoft Learn][3])

---

# 5) Local run & test

```bash
# install Functions Core Tools v4 beforehand
# then from repo root:
func start
# → Now listening on: http://localhost:7071
# Test:
curl "http://localhost:7071/api/hello?name=Atul"
```

When deployed, your function URL will be:

```
https://<APP>.azurewebsites.net/api/hello?name=Atul
```

(You can list function URLs via CLI after a deploy.) ([Microsoft Learn][1])

---

## Why this setup

* **Flex Consumption** = latest platform, cold-start + scale improvements. ([Microsoft Learn][4])
* **OIDC → user-assigned managed identity** = secretless CI/CD, RBAC-controlled. ([GitHub][2])
* **Azure Functions Action** = first-party, maintained templates per language/OS. ([GitHub][2])

If you want this as a public repo, say the word and I’ll adapt names (e.g., `azure-functions-github`) and add a README with screenshots and common pitfalls.

[1]: https://learn.microsoft.com/en-us/azure/azure-functions/how-to-create-function-azure-cli "Create a function in Azure from the command line | Microsoft Learn"
[2]: https://github.com/Azure/functions-action "GitHub - Azure/functions-action: Enable GitHub developers to deploy to Azure Function Apps using GitHub Actions"
[3]: https://learn.microsoft.com/en-us/azure/azure-functions/functions-how-to-github-actions?utm_source=chatgpt.com "Use GitHub Actions to make code updates in Azure Functions"
[4]: https://learn.microsoft.com/en-us/azure/azure-functions/flex-consumption-how-to?utm_source=chatgpt.com "Create and manage function apps in a Flex Consumption ..."
