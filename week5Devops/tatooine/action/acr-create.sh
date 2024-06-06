#!/bin/bash
# This action is to create Azure Container Registry (ACR) if not exist.
# Exits with 0 on success, 1 otherwise.

# get current dir and load global functions
DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
source "$DIR/.functions-and-globals.sh"

# ensure az is installed
f_program_exists_or_exit "az"

# load env
ENV_FILE=$1
if [ -z "$ENV_FILE" ];
then
  f_usage_and_exit
fi
f_load_env $ENV_FILE

# ensure required variables are in place
f_env_defined_or_exit "AZURE_SUBSCRIPTION"
f_env_defined_or_exit "AZURE_RESOURCE_GROUP"
f_env_defined_or_exit "AZURE_LOCATION"
f_env_defined_or_exit "AZURE_ACR_NAME"
f_env_defined_or_exit "AZURE_ACR_SKU"

# skip if acr is already created
az acr show --name "$AZURE_ACR_NAME" --resource-group "$AZURE_RESOURCE_GROUP" --subscription "$AZURE_SUBSCRIPTION" >/dev/null 2>&1
retVal=$?
if [ $retVal -eq 0 ]; then
  echo "INFO: acr $AZURE_ACR_NAME is already created, skip"
  exit 0
fi

# execute the command
echo "INFO: creating acr $AZURE_ACR_NAME under $AZURE_SUBSCRIPTION / $AZURE_RESOURCE_GROUP now ..."
az acr create --name "$AZURE_ACR_NAME" --resource-group "$AZURE_RESOURCE_GROUP" --location "$AZURE_LOCATION" --subscription "$AZURE_SUBSCRIPTION" --sku "$AZURE_ACR_SKU"

# make sure command issued successfully
retVal=$?
if [ $retVal -ne 0 ]; then
  echo "ERROR: failed to create acr $AZURE_ACR_NAME, please check!"
  exit $retVal
else
  echo "INFO: successfully created acr $AZURE_ACR_NAME"
fi
