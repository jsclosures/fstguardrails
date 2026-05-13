// Azure Container Apps deployment for FST Guard Rails (Java Text Tagger).
// Provisions: Log Analytics, Container Apps Environment, ACR (optional),
// and a Container App with public HTTPS ingress and a /health probe.

@description('Base name used for all resources.')
param name string = 'fst-guardrails'

@description('Azure region.')
param location string = resourceGroup().location

@description('Full container image reference, e.g. myacr.azurecr.io/fst-guardrails:latest')
param image string

@description('TCP port the container listens on.')
param targetPort int = 8080

@description('vCPU per replica. 0.5 is the smallest sensible size for the JVM.')
param cpu string = '0.5'

@description('Memory per replica. Must pair with cpu per Container Apps rules (e.g. 0.5 vCPU -> 1Gi).')
param memory string = '1Gi'

@description('Minimum replicas. Set to 0 to scale to zero between requests (cold-start trade-off).')
param minReplicas int = 1

@description('Maximum replicas (HTTP-concurrency-based autoscale).')
param maxReplicas int = 5

@description('Path to dictionary CSVs inside the container.')
param dataPath string = '/app/data'

@description('If using a private ACR for the image, set this to the ACR resource ID to grant pull.')
param acrResourceId string = ''

@description('If true, mount an Azure Files share at /data so dictionaries can be hot-swapped without rebuilding the image.')
param enableAzureFiles bool = false

@description('Storage account name for the Azure Files share (3-24 lowercase alphanumeric). Required when enableAzureFiles=true; auto-generated if left blank.')
param storageAccountName string = ''

@description('File share name to hold CSV dictionaries.')
param fileShareName string = 'dictionaries'

var logAnalyticsName = '${name}-logs'
var envName = '${name}-env'
var appName = name
var effectiveStorageAccountName = empty(storageAccountName)
  ? toLower(replace('${name}sa${uniqueString(resourceGroup().id)}', '-', ''))
  : storageAccountName
var storageMountName = 'dictionaries'
var effectiveDataPath = enableAzureFiles ? '/data' : dataPath

resource logs 'Microsoft.OperationalInsights/workspaces@2022-10-01' = {
  name: logAnalyticsName
  location: location
  properties: {
    sku: { name: 'PerGB2018' }
    retentionInDays: 30
  }
}

resource env 'Microsoft.App/managedEnvironments@2024-03-01' = {
  name: envName
  location: location
  properties: {
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsConfiguration: {
        customerId: logs.properties.customerId
        sharedKey: logs.listKeys().primarySharedKey
      }
    }
  }
}

// ── Azure Files for hot-swappable dictionaries (only when enableAzureFiles) ──
resource storage 'Microsoft.Storage/storageAccounts@2023-05-01' = if (enableAzureFiles) {
  name: effectiveStorageAccountName
  location: location
  sku: { name: 'Standard_LRS' }
  kind: 'StorageV2'
  properties: {
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
    publicNetworkAccess: 'Enabled'
  }
}

resource fileServices 'Microsoft.Storage/storageAccounts/fileServices@2023-05-01' = if (enableAzureFiles) {
  parent: storage
  name: 'default'
}

resource share 'Microsoft.Storage/storageAccounts/fileServices/shares@2023-05-01' = if (enableAzureFiles) {
  parent: fileServices
  name: fileShareName
  properties: {
    accessTier: 'TransactionOptimized'
    shareQuota: 5
  }
}

resource envStorage 'Microsoft.App/managedEnvironments/storages@2024-03-01' = if (enableAzureFiles) {
  parent: env
  name: storageMountName
  properties: {
    azureFile: {
      accountName: effectiveStorageAccountName
      accountKey: enableAzureFiles ? storage.listKeys().keys[0].value : ''
      shareName: fileShareName
      accessMode: 'ReadWrite'
    }
  }
}

resource app 'Microsoft.App/containerApps@2024-03-01' = {
  name: appName
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  dependsOn: enableAzureFiles ? [ envStorage ] : []
  properties: {
    managedEnvironmentId: env.id
    configuration: {
      ingress: {
        external: true
        targetPort: targetPort
        transport: 'auto'
        allowInsecure: false
        traffic: [
          { latestRevision: true, weight: 100 }
        ]
      }
      registries: empty(acrResourceId) ? [] : [
        {
          server: '${last(split(acrResourceId, '/'))}.azurecr.io'
          identity: 'system'
        }
      ]
    }
    template: {
      containers: [
        {
          name: 'tagger'
          image: image
          resources: {
            cpu: json(cpu)
            memory: memory
          }
          env: [
            { name: 'PORT', value: string(targetPort) }
            { name: 'DATA', value: effectiveDataPath }
          ]
          volumeMounts: enableAzureFiles ? [
            { volumeName: 'data', mountPath: '/data' }
          ] : []
          probes: [
            {
              type: 'Liveness'
              httpGet: { path: '/health', port: targetPort }
              initialDelaySeconds: 20
              periodSeconds: 15
              failureThreshold: 3
            }
            {
              type: 'Readiness'
              httpGet: { path: '/health', port: targetPort }
              initialDelaySeconds: 10
              periodSeconds: 10
              failureThreshold: 3
            }
            {
              type: 'Startup'
              httpGet: { path: '/health', port: targetPort }
              initialDelaySeconds: 5
              periodSeconds: 5
              failureThreshold: 30
            }
          ]
        }
      ]
      volumes: enableAzureFiles ? [
        {
          name: 'data'
          storageType: 'AzureFile'
          storageName: storageMountName
        }
      ] : []
      scale: {
        minReplicas: minReplicas
        maxReplicas: maxReplicas
        rules: [
          {
            name: 'http-concurrency'
            http: {
              metadata: {
                concurrentRequests: '50'
              }
            }
          }
        ]
      }
    }
  }
}

// Grant the app's managed identity AcrPull on the provided ACR (if any).
resource acrPullRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(acrResourceId)) {
  name: guid(acrResourceId, app.id, 'acrpull')
  scope: tenantResourceId('Microsoft.Resources/resourceGroups', resourceGroup().name)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '7f951dda-4ed3-4680-a7ca-43fe172d538d')
    principalId: app.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

output appUrl string = 'https://${app.properties.configuration.ingress.fqdn}'
output healthUrl string = 'https://${app.properties.configuration.ingress.fqdn}/health'
output logAnalyticsName string = logs.name
output storageAccountName string = enableAzureFiles ? effectiveStorageAccountName : ''
output fileShareName string = enableAzureFiles ? fileShareName : ''
