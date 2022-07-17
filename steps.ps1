################################
# Create a private App Service #
################################

# Variables
RESOURCE_GROUP="az-dns-resolver-demo"
LOCATION="northeurope"
APP_SERVICE_PLAN_NAME="az-dns-resolver-demo-plan"
APP_SERVICE_NAME="internalweb"
VNET_NAME="vnet"
WEBAPP_SUBNET="frontend"
VNET_CIDR=10.10.0.0/16
WEBAPP_SUBNET_CIDR=10.10.1.0/24

# Create a resource group
az group create --name $RESOURCE_GROUP --location $LOCATION

# Create App Service Plan
az appservice plan create \
--name $APP_SERVICE_PLAN_NAME \
--resource-group $RESOURCE_GROUP \
--location $LOCATION --sku S1

# Create App Service
az webapp create \
--name $APP_SERVICE_NAME \
--resource-group $RESOURCE_GROUP \
--plan $APP_SERVICE_PLAN_NAME

# Create a vnet
az network vnet create \
--name $VNET_NAME \
--resource-group $RESOURCE_GROUP \
--location $LOCATION \
--address-prefixes $VNET_CIDR \
--subnet-name $WEBAPP_SUBNET \
--subnet-prefixes $WEBAPP_SUBNET_CIDR

# You need to update the subnet to disable private endpoint network policies. 
az network vnet subnet update \
--name $WEBAPP_SUBNET \
--resource-group $RESOURCE_GROUP \
--vnet-name $VNET_NAME \
--disable-private-endpoint-network-policies true

# 6. Create a Private Endpoint for the Web App
# 6. 1 Get the web app ID
WEBAPP_ID=$(az webapp show --name $APP_SERVICE_NAME --resource-group $RESOURCE_GROUP --query id --output tsv)
WEB_APP_PRIVATE_ENDPOINT="webapp-private-endpoint"
# 6. 2 Create a Private Endpoint
az network private-endpoint create \
--name $WEB_APP_PRIVATE_ENDPOINT \
--resource-group $RESOURCE_GROUP \
--vnet-name $VNET_NAME \
--subnet $WEBAPP_SUBNET \
--connection-name "webapp-connection" \
--private-connection-resource-id $WEBAPP_ID \
--group-id sites

# Create Private DNS Zone
az network private-dns zone create \
--name privatelink.azurewebsites.net \
--resource-group $RESOURCE_GROUP

# Link between my VNET and the Private DNS Zone
az network private-dns link vnet create \
--name "${VNET_NAME}-link" \
--resource-group $RESOURCE_GROUP \
--registration-enabled false \
--virtual-network $VNET_NAME \
--zone-name privatelink.azurewebsites.net

# Create a DNS zone group
az network private-endpoint dns-zone-group create \
--name "webapp-group" \
--resource-group $RESOURCE_GROUP \
--endpoint-name $WEB_APP_PRIVATE_ENDPOINT \
--private-dns-zone privatelink.azurewebsites.net \
--zone-name privatelink.azurewebsites.net

# Create a VPN Gateway to connect wit my machine
VPN_GATEWAY_NAME="gateway"
VPN_GATEWAY_CIDR=10.10.2.0/24

# Create a subnet for the VPN Gateway
az network vnet subnet create \
  --vnet-name $VNET_NAME \
  --name GatewaySubnet \
  --resource-group $RESOURCE_GROUP \
  --address-prefix $VPN_GATEWAY_CIDR

# Create a public IP for the VPN Gateway
az network public-ip create \
  --name "${VPN_GATEWAY_NAME}-ip" \
  --resource-group $RESOURCE_GROUP \
  --allocation-method Dynamic

# Define CIDR block for the VPN clients
ADDRESS_POOL_FOR_VPN_CLIENTS=10.20.0.0/16

# Get tenant ID 
TENANT_ID=$(az account show --query tenantId --output tsv)
AZURE_VPN_CLIENT_ID="41b23e61-6c1e-4545-b367-cd054e0ed4b4"

#You have to consent Azure VPN application in your tenant first:
https://login.microsoftonline.com/common/oauth2/authorize?client_id=41b23e61-6c1e-4545-b367-cd054e0ed4b4&response_type=code&redirect_uri=https://portal.azure.com&nonce=1234&prompt=admin_consent

# Create a VPN Gateway
az network vnet-gateway create \
  --name $VPN_GATEWAY_NAME \
  --location $LOCATION \
  --public-ip-address "${VPN_GATEWAY_NAME}-ip" \
  --resource-group $RESOURCE_GROUP \
  --vnet $VNET_NAME \
  --gateway-type Vpn \
  --sku VpnGw2 \
  --vpn-type RouteBased \
  --address-prefixes $ADDRESS_POOL_FOR_VPN_CLIENTS \
  --client-protocol OpenVPN \
  --vpn-auth-type AAD \
  --aad-tenant "https://login.microsoftonline.com/${TENANT_ID}" \
  --aad-audience $AZURE_VPN_CLIENT_ID \
  --aad-issuer "https://sts.windows.net/${TENANT_ID}/"


# Get VPN client configuration
az network vnet-gateway vpn-client generate \
--resource-group $RESOURCE_GROUP \
--name $VPN_GATEWAY_NAME


# Install Az.DnsResolver module
Install-Module Az.DnsResolver

# Confirm that the module is installed
Get-InstalledModule -Name Az.DnsResolver

# Connect PowerShell to the Azure Cloud
Connect-AzAccount -Environment AzureCloud

####################################
## Create a DNS resolver instance ##
####################################

# Variables
$RESOURCE_GROUP = "az-dns-resolver-demo"
$LOCATION = "northeurope"
$VNET_NAME = "vnet"
$DNS_RESOLVER_NAME = "dnsresolver"

# Get subscription id
$SUBSCRIPTION_ID = (Get-AzContext).Subscription.Id

# Create a DNS resolver in the virtual network that you created.
New-AzDnsResolver -Name $DNS_RESOLVER_NAME `
-ResourceGroupName $RESOURCE_GROUP -Location $LOCATION `
-VirtualNetworkId "/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.Network/virtualNetworks/$VNET_NAME"

# Create a subnet in the virtual network
# The subnet needs to be at least /28 in size (16 IP addresses).
$SUBNET_NAME = "inbound-subnet"

$virtualNetwork = Get-AzVirtualNetwork -Name $VNET_NAME -ResourceGroupName $RESOURCE_GROUP
Add-AzVirtualNetworkSubnetConfig -Name $SUBNET_NAME -VirtualNetwork $virtualNetwork -AddressPrefix "10.10.3.0/28"
$virtualNetwork | Set-AzVirtualNetwork

# Create an inbound endpoint to enable name resolution from on-premises or another private location using an IP address 
# that is part of your private virtual network address space.
$INBOUND_ENDPOINT_NAME = "inbound-endpoint"

$IP_CONFIG = New-AzDnsResolverIPConfigurationObject -PrivateIPAllocationMethod Dynamic -SubnetId /subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.Network/virtualNetworks/$VNET_NAME/subnets/$SUBNET_NAME
New-AzDnsResolverInboundEndpoint -DnsResolverName $DNS_RESOLVER_NAME `
-Name $INBOUND_ENDPOINT_NAME -ResourceGroupName `
$RESOURCE_GROUP -Location $LOCATION -IpConfiguration $IP_CONFIG

# Get Inbound Endpoint IP
$inboundEndpoint = Get-AzDnsResolverInboundEndpoint -Name $INBOUND_ENDPOINT_NAME -DnsResolverName $DNS_RESOLVER_NAME -ResourceGroupName $RESOURCE_GROUP
$inboundEndpoint.ToJsonString() | jq .properties.ipConfigurations[0].privateIpAddress
