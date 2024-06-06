#!/bin/bash

# get current dir and load global functions
DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
ACTION_DIR="$DIR/action"
source "$ACTION_DIR/.functions-and-globals.sh"

# load env
ENV_FILE=$1
if [ -z "$ENV_FILE" ];
then
  f_usage_and_exit 
fi
f_load_env $ENV_FILE

f_section_echo "Creating Azure container registry"
"$ACTION_DIR/acr-create.sh" "$ENV_FILE"
