#!/bin/bash

# GLOBALS
G_AZURE_DEFAULT_ACR_SKU="Basic"
# The IP of Azure application gateway "aics-api.asus.com"
G_AICS_API_ALG_IP="20.43.170.132"
G_AICS_API_ALG_CIDR="${G_AICS_API_ALG_IP}/32"

# FUNCTIONS
function f_usage() {
  echo -e "USAGE: \n\t$0 ENV_FILE"
}

function f_usage_and_exit() {
  f_usage
  exit 1
}

function f_env_defined_or_exit() {
  env="$1"
  if [[ -z "${!env:-}" ]]; then
    echo >&2 "ERROR: $env is not defined, exit"
    exit 1
  fi
}

function f_verify_helm3_or_exit() {
  minimum_helm3_needed="v3.1.2"
  helm=$1
  f_program_exists_or_exit "$helm"
  IFS='+' # set as delimiter
  read -ra version <<< "$($helm version --short)" # str is read into an array as tokens separated by IFS
  # the version compare algorithm inspired by https://stackoverflow.com/a/48491786
  printf -v ver_comp '%s\n%s' "$version" "$minimum_helm3_needed"
  if [[ ver_comp = "$(sort -V <<< "$ver_comp")" ]]; then
    echo "helm3 version: $version, Need helm version $minimum_helm3_needed to proceed"
    exit 1
  fi
  echo "helm3 version: $version, verified ok"
}

function f_verify_helm2_or_exit() {
  helm2=$1
  f_program_exists_or_exit "$helm2"

  # sample output for helm2 as it prints out the version for both client and server
  # Client: &version.Version{SemVer:"v2.16.1", GitCommit:"bbdfe5e7803a12bbdf97e94cd847859890cf4050", GitTreeState:"clean"}
  # Server: &version.Version{SemVer:"v2.16.1", GitCommit:"bbdfe5e7803a12bbdf97e94cd847859890cf4050", GitTreeState:"clean"}
  versions=`$helm2 version | awk -F'SemVer:' '{print $2}' | awk -F',' '{print $1}' | sed 's/"//g'`
  # in this case versions should be "v2.16.1" and "v2.16.1"
  while IFS= read -r version; do
    [[ "$version" == v2.16.*  ]] || { echo >&2 "ERROR: we need helm2 to deploy, please check helm version ($version), exit"; exit 1;}
  done <<< "$versions"
}

function f_section_echo(){
  echo ""
  echo "###################################################################################################"
  echo "# $@"
  echo "###################################################################################################"
  echo ""
}

function f_load_env() {
  # '#' is used for comment like other bash configs
  # And here is to export variables after removing comments and empty lines
  source $1
}

function f_program_exists_or_exit() {
  command -v "$1" >/dev/null 2>&1 || { echo >&2 "ERROR: $1 is required but not installed, exit"; exit 1; }
}

function f_check_and_set_tag() {
  # check if tag exists
  f_env_defined_or_exit "AZURE_TAG_OWNER"
  f_env_defined_or_exit "AZURE_TAG_EM"
  f_env_defined_or_exit "AZURE_TAG_VERTICAL"

  NEED_CREATE_TAG=""
  META_USER=$(az tag list --resource-id $1 --query properties.tags.aics_meta_user -o tsv | sed 's/"//g')
  if [ -z "$META_USER" ]; then
    META_USER="$AZURE_TAG_OWNER;$AZURE_TAG_EM;$AZURE_TAG_VERTICAL"
    NEED_CREATE_TAG="true"
  fi
  META_CREATOR=$(az tag list --resource-id $1 --query properties.tags.aics_meta_creator -o tsv | sed 's/"//g')
  if [ -z "$META_CREATOR" ]; then
    META_CREATOR=`az ad signed-in-user show --query "userPrincipalName" | sed 's/"//g'`
    NEED_CREATE_TAG="true"
  fi

  if [ ! -z "$NEED_CREATE_TAG" ]; then
    echo "INFO: aics_meta_user or aics_meta_creator is not existed, create tags"
    az tag create --resource-id "$1" --subscription "$AZURE_SUBSCRIPTION" \
      --tags aics_meta_user="$META_USER" \
            aics_meta_creator="$META_CREATOR"
    retVal=$?
    if [ $retVal -ne 0 ]; then
      echo "ERROR: failed to create tag, please check!"
      exit $retVal
    else
      echo "INFO: successfully created tag: aics_meta_user=$META_USER, aics_meta_creator=$META_CREATOR"
    fi
  fi
}

function f_create_resource_group_if_needed() {
  if [ $# -lt 4 ];
  then
    echo "ERROR: not enough arguments: f_create_resource_group_if_needed {SUBSCRIPTION} {LOCATION} {RESOURCE_GROUP} {META_USER_TAG}"
    exit 1
  fi
  SUBSCRIPTION=$1
  LOCATION=$2
  RESOURCE_GROUP=$3
  META_USER_TAG=$4

  # skip if group is already created
  existed=$(az group exists --name "$RESOURCE_GROUP" --subscription "$SUBSCRIPTION")
  if [ "$existed" == "true" ]; then
    echo "INFO: resource group $RESOURCE_GROUP is already created, skip"
    return 0
  fi

  # execute the command
  echo "INFO: creating resource group $RESOURCE_GROUP under $SUBSCRIPTION subscription now ..."
  az group create --name "$RESOURCE_GROUP" --location "$LOCATION" --subscription "$SUBSCRIPTION" --tags "aics_meta_user=$META_USER_TAG"

  # make sure command issued successfully
  retVal=$?
  if [ $retVal -ne 0 ]; then
    echo "ERROR: failed to create resource group $RESOURCE_GROUP, please check!"
    exit $retVal
  else
    echo "INFO: successfully created resource group $RESOURCE_GROUP"
  fi
}

function f_create_key_vaults_if_needed() {
  if [ $# -lt 4 ];
  then
    echo "ERROR: not enough arguments: f_create_key_vaults_if_needed {SUBSCRIPTION} {LOCATION} {RESOURCE_GROUP} {KEY_VAULTS_NAME}"
    exit 1
  fi
  SUBSCRIPTION=$1
  LOCATION=$2
  RESOURCE_GROUP=$3
  KEY_VAULTS_NAME=$4

  # skip if key vaults is already created
  az keyvault show --name "$KEY_VAULTS_NAME" --resource-group "$RESOURCE_GROUP" --subscription "$SUBSCRIPTION" > /dev/null 2>&1
  retVal=$?
  if [ $retVal -eq 0 ]; then
    echo "INFO: key vaults $KEY_VAULTS_NAME is already created, skip"
    return 0
  fi

  # execute the command
  echo "INFO: creating key vaults $KEY_VAULTS_NAME under $SUBSCRIPTION / $RESOURCE_GROUP now ..."
  az keyvault create --name "$KEY_VAULTS_NAME" --enable-purge-protection "true" --resource-group "$RESOURCE_GROUP" --location "$LOCATION" --subscription "$SUBSCRIPTION"

  # make sure command issued successfully
  retVal=$?
  if [ $retVal -ne 0 ]; then
    echo "ERROR: failed to create key vaults $KEY_VAULTS_NAME, please check!"
    exit $retVal
  else
    echo "INFO: successfully created key vaults $KEY_VAULTS_NAME"
  fi
}

function f_get_vault_secret_and_set_env(){
  if [ $# -lt 4 ];
  then
    echo "ERROR: not enough arguments: f_get_vault_secret_and_set_env {SUBSCRIPTION} {KEY_VAULT_NAME} {SECRET_NAME} {ENV_NAME}"
    exit 1
  fi

  SUBSCRIPTION=$1
  KEY_VAULTS_NAME=$2
  SECRET_NAME=$3
  ENV_NAME=$4

  echo "INFO: get secret ${SECRET_NAME} from keyvault ${KEY_VAULTS_NAME}"
  result=$(az keyvault secret show \
    --name "$SECRET_NAME" \
    --vault-name "$KEY_VAULTS_NAME" \
    --subscription "$SUBSCRIPTION" \
    --query "value")

  retVal=$?
  if [ $retVal -ne 0 ]; then
    echo "ERROR: failed to get secret ${SECRET_NAME} from ${KEY_VAULTS_NAME}"
    return 1
  else
    echo "INFO: sucessful get secret ${SECRET_NAME} from ${KEY_VAULTS_NAME}"
    export ${ENV_NAME}=$(echo "$result" | tr -d '"')
  fi
}


function f_set_key_vaults_access() {
  if [ $# -lt 5 ];
  then
    echo "ERROR: not enough arguments: f_set_key_vaults_access {SUBSCRIPTION} {RESOURCE_GROUP} {KEY_VAULTS_NAME} {SP} {PERMISSIONS}"
    exit 1
  fi
  SUBSCRIPTION=$1
  RESOURCE_GROUP=$2
  KEY_VAULTS_NAME=$3
  SP=$4
  PERMS=$5

  echo "INFO: grant READ access for $SP to $KEY_VAULTS_NAME"
  az keyvault set-policy \
    --name "$KEY_VAULTS_NAME" \
    --spn "$SP" \
    --resource-group "$RESOURCE_GROUP" \
    --subscription "$SUBSCRIPTION" \
    --key-permissions "$PERMS" \
    --secret-permissions "$PERMS"

  # make sure command issued successfully
  retVal=$?
  if [ $retVal -ne 0 ]; then
    echo "ERROR: failed to grant READ access for $SP to $KEY_VAULTS_NAME"
    exit $retVal
  else
    echo "INFO: successfully grant READ access for $SP to $KEY_VAULTS_NAME"
  fi
}

function f_set_key_vaults_value() {
  if [ $# -lt 4 ];
  then
    echo "ERROR: not enough arguments: f_set_key_vaults_value {SUBSCRIPTION} {KEY_VAULTS_NAME} {KEY} {SECRET}"
    exit 1
  fi
  SUBSCRIPTION=$1
  KEY_VAULTS_NAME=$2
  KEY=$3
  SECRET=$4

  # execute the command
  echo "INFO: set key vaults value - key: $KEY in $KEY_VAULTS_NAME"
  az keyvault secret set --vault-name "$KEY_VAULTS_NAME" --name "$KEY" --value "$SECRET" --subscription "$SUBSCRIPTION" > /dev/null

  # make sure command issued successfully
  retVal=$?
  if [ $retVal -ne 0 ]; then
    echo "ERROR: failed to set $KEY in key vaults $KEY_VAULTS_NAME, please check"
    exit $retVal
  else
    echo "INFO: successfully set $KEY in key vaults $KEY_VAULTS_NAME"
  fi
}

function f_enable_user_access_to_key_vaults() {
  if [ $# -lt 4 ];
  then
    echo "ERROR: not enough arguments: f_enable_user_access_to_key_vaults {SUBSCRIPTION} {RESOURCE_GROUP} {KEY_VAULTS_NAME} {UPN}"
    exit 1
  fi
  SUBSCRIPTION=$1
  RESOURCE_GROUP=$2
  KEY_VAULTS_NAME=$3
  UPN=$4

  echo "INFO: grant ALL access for $UPN to $KEY_VAULTS_NAME"
  az keyvault set-policy \
    --name "$KEY_VAULTS_NAME" \
    --upn "$UPN" \
    --resource-group "$RESOURCE_GROUP" \
    --subscription "$SUBSCRIPTION" \
    --certificate-permissions get list update create import delete recover backup restore \
    --key-permissions get list update create import delete recover backup restore \
    --secret-permissions get list set delete recover backup restore

  # make sure command issued successfully
  retVal=$?
  if [ $retVal -ne 0 ]; then
    echo "ERROR: failed to grant access for user $UPN to $KEY_VAULTS_NAME"
    exit $retVal
  else
    echo "INFO: successfully grant access for user $UPN to $KEY_VAULTS_NAME"
  fi
}

function f_enable_sp_access_to_key_vaults() {
  if [ $# -lt 4 ];
  then
    echo "ERROR: not enough arguments: f_enable_sp_access_to_key_vaults {SUBSCRIPTION} {RESOURCE_GROUP} {KEY_VAULTS_NAME} {OBJECT_ID}"
    exit 1
  fi
  SUBSCRIPTION=$1
  RESOURCE_GROUP=$2
  KEY_VAULTS_NAME=$3
  OBJECT_ID=$4

  echo "INFO: grant READ access for $OBJECT_ID to $KEY_VAULTS_NAME"
  az keyvault set-policy \
    --name "$KEY_VAULTS_NAME" \
    --object-id "$OBJECT_ID" \
    --resource-group "$RESOURCE_GROUP" \
    --subscription "$SUBSCRIPTION" \
    --certificate-permissions get list update create import delete recover backup restore \
    --key-permissions get list update create import delete recover backup restore \
    --secret-permissions get list set delete recover backup restore

  # make sure command issued successfully
  retVal=$?
  if [ $retVal -ne 0 ]; then
    echo "ERROR: failed to grant access for sp $OBJECT_ID to $KEY_VAULTS_NAME"
    exit $retVal
  else
    echo "INFO: successfully grant access for sp $OBJECT_ID to $KEY_VAULTS_NAME"
  fi
}

function f_disable_user_access_to_key_vaults() {
  if [ $# -lt 4 ];
  then
    echo "ERROR: not enough arguments: f_disable_user_to_key_vaults {SUBSCRIPTION} {RESOURCE_GROUP} {KEY_VAULTS_NAME} {UPN}"
    exit 1
  fi
  SUBSCRIPTION=$1
  RESOURCE_GROUP=$2
  KEY_VAULTS_NAME=$3
  UPN=$4

  echo "INFO: revoke access for $UPN to $KEY_VAULTS_NAME"
  az keyvault delete-policy \
    --name "$KEY_VAULTS_NAME" \
    --upn "$UPN" \
    --resource-group "$RESOURCE_GROUP" \
    --subscription "$SUBSCRIPTION"

  # make sure command issued successfully
  retVal=$?
  if [ $retVal -ne 0 ]; then
    echo "ERROR: failed to revoke access for user $UPN to $KEY_VAULTS_NAME"
    exit $retVal
  else
    echo "INFO: successfully revoke access for user $UPN to $KEY_VAULTS_NAME"
  fi
}

function f_disable_sp_access_to_key_vaults() {
  if [ $# -lt 4 ];
  then
    echo "ERROR: not enough arguments: f_disable_sp_access_to_key_vaults {SUBSCRIPTION} {RESOURCE_GROUP} {KEY_VAULTS_NAME} {OBJECT_ID}"
    exit 1
  fi
  SUBSCRIPTION=$1
  RESOURCE_GROUP=$2
  KEY_VAULTS_NAME=$3
  OBJECT_ID=$4

  echo "INFO: revoke access for $OBJECT_ID to $KEY_VAULTS_NAME"
  az keyvault delete-policy \
    --name "$KEY_VAULTS_NAME" \
    --object-id "$OBJECT_ID" \
    --resource-group "$RESOURCE_GROUP" \
    --subscription "$SUBSCRIPTION"

  # make sure command issued successfully
  retVal=$?
  if [ $retVal -ne 0 ]; then
    echo "ERROR: failed to revoke access for sp $OBJECT_ID to $KEY_VAULTS_NAME"
    exit $retVal
  else
    echo "INFO: successfully revoke access for sp $OBJECT_ID to $KEY_VAULTS_NAME"
  fi
}

# Check, create, and update the Azure cloud resources.
# $1: resource name
# $2: resource id
# $3: az command to check
# $4: az command to create
# $5: az command to update (optional)
function f_build_resource() {
  name="$1 ($2)"

  # check if the target resource exists
  st=`$3  2>/dev/null`
  if [ -z "$st" ]; then
  # create if not there
    echo "INFO: creating $name under $AZURE_SUBSCRIPTION / $AZURE_RESOURCE_GROUP now ..."
    eval $4
    retVal=$?
    if [ $retVal -ne 0 ]; then
      echo "ERROR: failed to create $name, please check."
      exit $retVal
    fi
  else
    echo "INFO: $name is already created, skip"
  fi

  # if anything to update, do it
  if [ ! -z "$5" ]; then
    eval $5
    retVal=$?
    if [ $retVal -ne 0 ]; then
      echo "ERROR: failed to update $name, please check."
      exit $retVal
    fi
  fi
}

function f_production_check() {
  if [[ -n "${SERVICE_PRINCIPAL_APPID:-}" ]]; then
    echo "Execute by pipeline, skip prod check."
    return 0
  fi

  if [ $# -lt 2 ];
  then
    echo "ERROR: not enough arguments: f_production_check {SUBSCRIPTION} {CHECK_STRING}"
    exit 1
  fi
  SUBSCRIPTION=$1
  CHECK_STRING=$2
  if [[ $SUBSCRIPTION == "bd26395a-031e-498b-acfe-4066c3b64edf" || $SUBSCRIPTION == "ASUS AICS Production Service" ]]; then
    read -p "WARNING: Are you sure to deploy to production? (re-type '$CHECK_STRING' to confirm): " -r
    if [[ $REPLY != $CHECK_STRING ]]; then
        echo "INFO: Input string doesn't match, bye."
        [[ "$0" = "$BASH_SOURCE" ]] && exit 1 || return 1 # handle exits from shell or function but don't exit interactive shell
    else
      echo "INFO: Input string match, continue deploy process"
    fi
  fi
}

function f_restart_check() {
  if [ $# -lt 3 ];
  then
    echo "ERROR: not enough arguments: f_restart_check {SUBSCRIPTION} {ACTION} {CHECK_STRING}"
    exit 1
  fi
  SUBSCRIPTION=$1
  ACTION=$2
  CHECK_STRING=$3
  if [[ $SUBSCRIPTION == "bd26395a-031e-498b-acfe-4066c3b64edf" || $SUBSCRIPTION == "ASUS AICS Production Service" ]]; then
    read -p "WARNING: '$ACTION' will cause server restart which might cause service downtime. Confirm to continue? (re-type '$CHECK_STRING' to confirm): " -r
    if [[ $REPLY != $CHECK_STRING ]]; then
        echo "INFO: Input string doesn't match, bye."
        [[ "$0" = "$BASH_SOURCE" ]] && exit 1 || return 1 # handle exits from shell or function but don't exit interactive shell
    else
      echo "INFO: Input string match, continue deploy process"
    fi
  fi
}

function f_export_vnet_env() {
  if [ $# -lt 3 ]; then
    echo "ERROR: not enough arguments: f_export_vnet_env {SUBSCRIPTION} {SUBNET_PREFIX} {IP_DOMAIN}"
    exit 1
  fi
  f_export_loc_vnet_env "$1" "$2" "$3" "southeastasia"
}

function f_export_loc_vnet_env() {
  if [ $# -lt 4 ]; then
    echo "ERROR: not enough arguments: f_export_loc_vnet_env {SUBSCRIPTION} {SUBNET_PREFIX} {IP_DOMAIN} {AZURE_LOCATION}"
    exit 1
  fi

  SUBSCRIPTION=$1
  SUBNET_PREFIX=$2
  IP_DOMAIN=$3
  AZURE_LOCATION=$4
  if [[ "$SUBSCRIPTION" == "bd26395a-031e-498b-acfe-4066c3b64edf" || "$SUBSCRIPTION" == "ASUS AICS Production Service" ]]; then
    if [[ $AZURE_LOCATION == "japaneast" ]]; then
        VNET_RESOURCE_GROUP="aicsapi-prod-general-jp"
        VNET_NAME="aics-vnet-jp-prod"
        echo "prod jp ${VNET_RESOURCE_GROUP}, ${VNET_NAME}"
    else
        VNET_RESOURCE_GROUP="aicsapi-prod-general"
        VNET_NAME="aics-vnet-prod"
        echo "prod sg ${VNET_RESOURCE_GROUP}, ${VNET_NAME}"
    fi
  elif [[ "$SUBSCRIPTION" == "0b8224a3-5cd4-4e80-be50-69a2f8266205" || "$SUBSCRIPTION" == "ASUS AICS Staging Service" ]]; then
    if [[ $AZURE_LOCATION == "japaneast" ]]; then
        VNET_RESOURCE_GROUP="aicsapi-staging-general-jp"
        VNET_NAME="aics-vnet-jp-stage"
        echo "stage jp ${VNET_RESOURCE_GROUP}, ${VNET_NAME}"
    else
        VNET_RESOURCE_GROUP="aicsapi-staging-general"
        VNET_NAME="aics-vnet-stage"
        echo "stage sg ${VNET_RESOURCE_GROUP}, ${VNET_NAME}"
    fi
  elif [[ "$SUBSCRIPTION" == "fd6d7d85-d986-401e-9103-ef07776cfe8b" || "$SUBSCRIPTION" == "ASUS AICS Production Service US" ]]; then
     VNET_RESOURCE_GROUP="aicsapi-prod-general"
     VNET_NAME="aics-vnet-prod-us"
  else
     echo "INFO: this subscription no need to integrate vnet, skip."
     return 0
  fi

  export AZURE_VNET_RESOURCE_GROUP="$VNET_RESOURCE_GROUP"
  export AZURE_VNET_NAME="$VNET_NAME"
  export AZURE_VNET_ADDR_SPACE="10.0.0.0/8"
  export SUBNET_NAME_AKS_NODES="${SUBNET_PREFIX}-node"
  export AZURE_SUBNET_ADDR_AKS_NODES="10.${IP_DOMAIN}.0.0/17"
  export SERVICE_IP_RANGE="10.${IP_DOMAIN}.128.0/24"
  export SERVICE_DNS_IP="10.${IP_DOMAIN}.128.10"
  export SUBNET_NAME_AKS_VNODES="${SUBNET_PREFIX}-vnode"
  export AZURE_SUBNET_ADDR_AKS_VNODES="10.${IP_DOMAIN}.129.0/24"
}
