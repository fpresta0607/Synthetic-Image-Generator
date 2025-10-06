#!/usr/bin/env bash

# ecs-deploy (embedded copy with added -C/--container-name option)
# Upstream: https://github.com/silinternational/ecs-deploy
# Added capability:
#   -C | --container-name  Only update the image for the named container in a multi-container task definition.
# Limitations of -C:
#   * Only supported when not using --tag-only or --tag-env-var (those still update all containers like upstream behavior)
#   * Health/rollback logic preserved.

VERSION="3.10.22+container-name"
CLUSTER=false
SERVICE=false
TASK_DEFINITION=false
TASK_DEFINITION_FILE=false
MAX_DEFINITIONS=0
AWS_ASSUME_ROLE=false
IMAGE=false
MIN=false
MAX=false
TIMEOUT=90
VERBOSE=false
TAGVAR=false
TAGONLY=""
ENABLE_ROLLBACK=false
USE_MOST_RECENT_TASK_DEFINITION=false
AWS_CLI=$(which aws)
AWS_ECS="$AWS_CLI --output json ecs"
FORCE_NEW_DEPLOYMENT=false
SKIP_DEPLOYMENTS_CHECK=false
RUN_TASK=false
RUN_TASK_LAUNCH_TYPE=false
RUN_TASK_PLATFORM_VERSION=false
RUN_TASK_NETWORK_CONFIGURATION=false
RUN_TASK_WAIT_FOR_SUCCESS=false
TASK_DEFINITION_TAGS=false
COPY_TASK_DEFINITION_TAGS=false
CONTAINER_NAME=false

function usage() {
    cat <<EOM
##### ecs-deploy (with container targeting) #####
Added option:
    -C | --container-name      Only replace image for the named container (ignored for --tag-only mode)
Refer to upstream usage for remaining arguments.
EOM
    exit 3
}

function require() { command -v "$1" >/dev/null 2>&1 || { echo "Missing required binary: $1" >&2; exit 4; }; }

function assumeRole() {
  temp_role=$(aws sts assume-role --role-arn "${AWS_ASSUME_ROLE}" --role-session-name "$(date +"%s")")
  export AWS_ACCESS_KEY_ID=$(echo "$temp_role" | jq -r .Credentials.AccessKeyId)
  export AWS_SECRET_ACCESS_KEY=$(echo "$temp_role" | jq -r .Credentials.SecretAccessKey)
  export AWS_SESSION_TOKEN=$(echo "$temp_role" | jq -r .Credentials.SessionToken)
}

function assumeRoleClean() { unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN || true; }

function assertRequiredArgumentsSet() {
  if [ -z ${AWS_ACCESS_KEY_ID+x} ]; then unset AWS_ACCESS_KEY_ID; fi
  if [ -z ${AWS_SECRET_ACCESS_KEY+x} ]; then unset AWS_SECRET_ACCESS_KEY; fi
  if [ -z ${AWS_DEFAULT_REGION+x} ]; then unset AWS_DEFAULT_REGION; else AWS_ECS="$AWS_ECS --region $AWS_DEFAULT_REGION"; fi
  if [ -z ${AWS_PROFILE+x} ]; then unset AWS_PROFILE; else AWS_ECS="$AWS_ECS --profile $AWS_PROFILE"; fi
  if [ $SERVICE == false ] && [ $TASK_DEFINITION == false ]; then echo "SERVICE or TASK DEFINITION required"; exit 5; fi
  if [ $SERVICE != false ] && [ $TASK_DEFINITION != false ]; then echo "Specify only one of service or task"; exit 6; fi
  if [ $SERVICE != false ] && [ $CLUSTER == false ]; then echo "CLUSTER required"; exit 7; fi
  if [ $IMAGE == false ] && [ $FORCE_NEW_DEPLOYMENT == false ]; then echo "IMAGE required"; exit 8; fi
  if ! [[ $MAX_DEFINITIONS =~ ^-?[0-9]+$ ]]; then echo "MAX_DEFINITIONS must be numeric"; exit 9; fi
  if [ $RUN_TASK == false ] && [ $RUN_TASK_LAUNCH_TYPE != false ]; then echo 'LAUNCH TYPE requires --run-task'; exit 10; fi
  if [ $RUN_TASK == false ] && [ $RUN_TASK_NETWORK_CONFIGURATION != false ]; then echo 'NETWORK CONFIGURATION requires --run-task'; exit 11; fi
  if [ $RUN_TASK == false ] && [ $RUN_TASK_WAIT_FOR_SUCCESS != false ]; then echo 'WAIT FOR SUCCESS requires --run-task'; exit 11; fi
  if [ $RUN_TASK == false ] && [ $RUN_TASK_PLATFORM_VERSION != false ]; then echo 'PLATFORM VERSION requires --run-task'; exit 12; fi
}

function parseImageName() {
  if [[ "x$TAGONLY" == "x" ]]; then
    imageRegex="^([a-zA-Z0-9\.\-]+):?([0-9]+)?/([a-zA-Z0-9\._\-]+)(/[\/a-zA-Z0-9\._\-]+)?:?((@sha256:)?[a-zA-Z0-9\._\-]+)?$"
  else
    imageRegex="^:?([a-zA-Z0-9\._-]+)?$"
  fi
  if [[ $IMAGE =~ $imageRegex ]]; then
    if [[ "x$TAGONLY" == "x" ]]; then
      domain=${BASH_REMATCH[1]}; port=${BASH_REMATCH[2]}; repo=${BASH_REMATCH[3]}; img=${BASH_REMATCH[4]/#/}; tagOrDigest=${BASH_REMATCH[5]}; emptyOrSha=${BASH_REMATCH[6]}
      if [[ "x$emptyOrSha" == "x" ]]; then tag=${tagOrDigest}; else digest=${tagOrDigest}; fi
      if [[ -z "$domain" ]]; then echo "Invalid image (missing domain/repo)"; exit 10; fi
      if [[ -z "$repo" ]]; then echo "Invalid image (missing name)"; exit 11; fi
      if [[ -z "$img" ]]; then img=$repo; repo=""; fi
    else
      tag=${BASH_REMATCH[1]}; domain=""; port=""; repo=""; img=""
    fi
  else
    rootRepoRegex="^([a-zA-Z0-9\-]+):?((@sha256:)?[a-zA-Z0-9\.\-_]+)?$"
    if [[ $IMAGE =~ $rootRepoRegex ]]; then
      img=${BASH_REMATCH[1]}; if [[ -z "$img" ]]; then echo "Invalid image"; exit 12; fi
      tagOrDigest=${BASH_REMATCH[2]}; emptyOrSha=${BASH_REMATCH[3]}
      if [[ -z "$emptyOrSha" ]]; then tag=${tagOrDigest}; else digest=${tagOrDigest}; fi
      domain=""; port=""; repo=""
    else
      echo "Unable to parse image: $IMAGE"; exit 13
    fi
  fi
  if [[ -z $tag ]]; then
    if [[ $TAGVAR == false ]]; then tag="latest"; else tag=${!TAGVAR}; [[ -z $tag ]] && tag="latest" || emptyOrSha=""; fi
  fi
  useImage=""
  if [[ "x$TAGONLY" == "x" ]]; then
    [[ -n $domain ]] && useImage="$domain"
    [[ -n $port ]] && useImage="$useImage:$port"
    [[ -n $repo ]] && useImage="$useImage/$repo"
    if [[ -n $img ]]; then
      if [[ -z $useImage ]]; then useImage="$img"; else useImage="$useImage/$img"; fi
    fi
    imageWithoutTag="$useImage"
    if [[ -n $emptyOrSha ]]; then useImage="$useImage$digest"; else useImage="$useImage:$tag"; fi
  else
    useImage="$TAGONLY"
  fi
}

function getCurrentTaskDefinition() {
  if [ $SERVICE != false ]; then
    TASK_DEFINITION_ARN=`$AWS_ECS describe-services --services $SERVICE --cluster $CLUSTER | jq -r .services[0].taskDefinition`
    TASK_DEFINITION=`$AWS_ECS describe-task-definition --task-def $TASK_DEFINITION_ARN`
    LAST_USED_TASK_DEFINITION_ARN=$TASK_DEFINITION_ARN
    if [ $USE_MOST_RECENT_TASK_DEFINITION != false ]; then
      TASK_DEFINITION_FAMILY=`$AWS_ECS describe-task-definition --task-def $TASK_DEFINITION_ARN | jq -r .taskDefinition.family`
      TASK_DEFINITION=`$AWS_ECS describe-task-definition --task-def $TASK_DEFINITION_FAMILY`
      TASK_DEFINITION_ARN=`$AWS_ECS describe-task-definition --task-def $TASK_DEFINITION_FAMILY | jq -r .taskDefinition.taskDefinitionArn`
    fi
  elif [ $TASK_DEFINITION != false ]; then
    TASK_DEFINITION_ARN=`$AWS_ECS describe-task-definition --task-def $TASK_DEFINITION | jq -r .taskDefinition.taskDefinitionArn`
  fi
  if [[ "$COPY_TASK_DEFINITION_TAGS" == true ]]; then
    TASK_DEFINITION=`$AWS_ECS describe-task-definition --task-def $TASK_DEFINITION_ARN --include TAGS`
    TASK_DEFINITION_TAGS=$( echo "$TASK_DEFINITION" | jq ".tags" )
  else
    TASK_DEFINITION=`$AWS_ECS describe-task-definition --task-def $TASK_DEFINITION_ARN`
  fi
}

function createNewTaskDefJson() {
  if [ $TASK_DEFINITION_FILE == false ]; then taskDefinition="$TASK_DEFINITION"; else taskDefinition="$(cat $TASK_DEFINITION_FILE)"; fi
  DEF=$( echo "$taskDefinition" | jq '.taskDefinition')
  if [[ "x$TAGONLY" == "x" ]]; then
    if [[ $CONTAINER_NAME != false ]]; then
      DEF=$( echo "$DEF" | jq --arg c "$CONTAINER_NAME" --arg newimg "$useImage" --arg base "$imageWithoutTag" '
        .containerDefinitions = (.containerDefinitions | map( if .name==$c then .image=$newimg else . end))')
    else
      DEF=$( echo "$DEF" | jq --arg newimg "$useImage" --arg base "$imageWithoutTag" '
        .containerDefinitions = (.containerDefinitions | map( if (.image|startswith($base+":")) or (.image|startswith($base+"@sha256:")) then .image=$newimg else . end))')
    fi
  else
    if [[ $CONTAINER_NAME != false ]]; then echo "WARNING: --container-name ignored in --tag-only mode" >&2; fi
    # TAGONLY: let upstream sed logic have replaced images implicitly (not implemented here)
    # We simply append new tag to all non-digest images.
    DEF=$( echo "$DEF" | jq --arg tag "$useImage" ' .containerDefinitions = (.containerDefinitions | map( if (.image|contains("@sha256:")) then . else .image=( (.image | split(":"))[0] + ":" + $tag ) end))')
  fi
  NEW_DEF_JQ_FILTER="family: .family, volumes: .volumes, containerDefinitions: .containerDefinitions, placementConstraints: .placementConstraints"
  CONDITIONAL_OPTIONS=(networkMode taskRoleArn placementConstraints executionRoleArn runtimePlatform ephemeralStorage proxyConfiguration)
  for i in "${CONDITIONAL_OPTIONS[@]}"; do
    if echo "$DEF" | grep -q "$i"; then NEW_DEF_JQ_FILTER="${NEW_DEF_JQ_FILTER}, ${i}: .${i}"; fi
  done
  REQUIRES_COMPATIBILITIES=$(echo "${DEF}" | jq -r '. | select(.requiresCompatibilities != null) | .requiresCompatibilities[]') || true
  if echo ${REQUIRES_COMPATIBILITIES[@]} | grep -q FARGATE; then
    FARGATE_JQ_FILTER='requiresCompatibilities: .requiresCompatibilities, cpu: .cpu, memory: .memory'
    if [[ ! "$NEW_DEF_JQ_FILTER" =~ .*executionRoleArn.* ]]; then FARGATE_JQ_FILTER="${FARGATE_JQ_FILTER}, executionRoleArn: .executionRoleArn"; fi
    NEW_DEF_JQ_FILTER="${NEW_DEF_JQ_FILTER}, ${FARGATE_JQ_FILTER}"
  fi
  NEW_DEF=$(echo "$DEF" | jq "{${NEW_DEF_JQ_FILTER}}")
}

function registerNewTaskDefinition() {
  if [[ "$COPY_TASK_DEFINITION_TAGS" == true && "$TASK_DEFINITION_TAGS" != false && "$TASK_DEFINITION_TAGS" != "[]" ]]; then
    NEW_TASKDEF=`$AWS_ECS register-task-definition --cli-input-json "$NEW_DEF" --tags "$TASK_DEFINITION_TAGS" | jq -r .taskDefinition.taskDefinitionArn`
  else
    NEW_TASKDEF=`$AWS_ECS register-task-definition --cli-input-json "$NEW_DEF" | jq -r .taskDefinition.taskDefinitionArn`
  fi
}

function rollback() { echo "Rolling back to ${LAST_USED_TASK_DEFINITION_ARN}"; $AWS_ECS update-service --cluster $CLUSTER --service $SERVICE --task-definition $LAST_USED_TASK_DEFINITION_ARN >/dev/null; }
function updateServiceForceNewDeployment() { echo 'Force new deployment'; $AWS_ECS update-service --cluster $CLUSTER --service $SERVICE --force-new-deployment >/dev/null; }

function updateService() {
  if [[ $(echo ${NEW_DEF} | jq ".containerDefinitions[0].healthCheck != null") == true ]]; then checkFieldName="healthStatus"; checkFieldValue='"HEALTHY"'; else checkFieldName="lastStatus"; checkFieldValue='"RUNNING"'; fi
  UPDATE_SERVICE_SUCCESS="false"
  DEPLOYMENT_CONFIG=""
  [[ $MAX != false ]] && DEPLOYMENT_CONFIG=",maximumPercent=$MAX"
  [[ $MIN != false ]] && DEPLOYMENT_CONFIG="$DEPLOYMENT_CONFIG,minimumHealthyPercent=$MIN"
  [[ -n "$DEPLOYMENT_CONFIG" ]] && DEPLOYMENT_CONFIG="--deployment-configuration ${DEPLOYMENT_CONFIG:1}"
  DESIRED_COUNT=""; [ ! -z ${DESIRED+guard} ] && DESIRED_COUNT="--desired-count $DESIRED"
  $AWS_ECS update-service --cluster $CLUSTER --service $SERVICE $DESIRED_COUNT --task-definition $NEW_TASKDEF $DEPLOYMENT_CONFIG >/dev/null
  SERVICE_DESIREDCOUNT=`$AWS_ECS describe-services --cluster $CLUSTER --service $SERVICE | jq '.services[]|.desiredCount'`
  if [ $SERVICE_DESIREDCOUNT -gt 0 ]; then
    every=10; i=0
    while [ $i -lt $TIMEOUT ]; do
      RUNNING_TASKS=$($AWS_ECS list-tasks --cluster "$CLUSTER"  --service-name "$SERVICE" --desired-status RUNNING | jq -r '.taskArns[]' 2>/dev/null || true)
      if [[ -n $RUNNING_TASKS ]]; then
        RUNNING=$($AWS_ECS describe-tasks --cluster "$CLUSTER" --tasks $RUNNING_TASKS | jq ".tasks[]| if .taskDefinitionArn == \"$NEW_TASKDEF\" then . else empty end|.${checkFieldName}" | grep -e ${checkFieldValue} || true)
        if [[ -n $RUNNING ]]; then
          echo "Service updated; new task definition running."
          if [[ $MAX_DEFINITIONS -gt 0 ]]; then
            FAMILY_PREFIX=${TASK_DEFINITION_ARN##*:task-definition/}; FAMILY_PREFIX=${FAMILY_PREFIX%*:[0-9]*}
            TASK_REVISIONS=`$AWS_ECS list-task-definitions --family-prefix $FAMILY_PREFIX --status ACTIVE --sort ASC`
            NUM_ACTIVE_REVISIONS=$(echo "$TASK_REVISIONS" | jq ".taskDefinitionArns|length")
            if [[ $NUM_ACTIVE_REVISIONS -gt $MAX_DEFINITIONS ]]; then
              LAST_OUTDATED_INDEX=$(($NUM_ACTIVE_REVISIONS - $MAX_DEFINITIONS - 1))
              for j in $(seq 0 $LAST_OUTDATED_INDEX); do
                OUTDATED_REVISION_ARN=$(echo "$TASK_REVISIONS" | jq -r ".taskDefinitionArns[$j]")
                echo "Deregistering outdated revision: $OUTDATED_REVISION_ARN"
                $AWS_ECS deregister-task-definition --task-definition "$OUTDATED_REVISION_ARN" >/dev/null
              done
            fi
          fi
          UPDATE_SERVICE_SUCCESS="true"; break
        fi
      fi
      sleep $every; i=$(( i + every ))
    done
    if [[ "${UPDATE_SERVICE_SUCCESS}" != "true" ]]; then
      echo "ERROR: New task definition not running within $TIMEOUT seconds"
      [[ "${ENABLE_ROLLBACK}" != "false" ]] && rollback
      exit 1
    fi
  else
    echo "Skipping running check (desired-count <= 0)"
  fi
}

function waitForGreenDeployment() {
  DEPLOYMENT_SUCCESS="false"; every=2; i=0; echo "Waiting for service deployment to stabilize..."
  while [ $i -lt $TIMEOUT ]; do
    NUM_DEPLOYMENTS=$($AWS_ECS describe-services --services $SERVICE --cluster $CLUSTER | jq "[.services[].deployments[]] | length")
    if [ $NUM_DEPLOYMENTS -eq 1 ]; then echo "Deployment stabilized."; DEPLOYMENT_SUCCESS="true"; break; fi
    sleep $every; i=$(( i + every ))
  done
  if [[ "$DEPLOYMENT_SUCCESS" != "true" ]]; then
    [[ "${ENABLE_ROLLBACK}" != "false" ]] && rollback
    exit 1
  fi
}

function runTask() {
  echo "Run task: $NEW_TASKDEF"; AWS_ECS_RUN_TASK="$AWS_ECS run-task --cluster $CLUSTER --task-definition $NEW_TASKDEF"
  [ $RUN_TASK_LAUNCH_TYPE != false ] && AWS_ECS_RUN_TASK="$AWS_ECS_RUN_TASK --launch-type $RUN_TASK_LAUNCH_TYPE"
  [ $RUN_TASK_PLATFORM_VERSION != false ] && AWS_ECS_RUN_TASK="$AWS_ECS_RUN_TASK --platform-version $RUN_TASK_PLATFORM_VERSION"
  [ $RUN_TASK_NETWORK_CONFIGURATION != false ] && AWS_ECS_RUN_TASK="$AWS_ECS_RUN_TASK --network-configuration \"$RUN_TASK_NETWORK_CONFIGURATION\""
  TASK_ARN=$(eval $AWS_ECS_RUN_TASK | jq -r '.tasks[0].taskArn'); echo "Executed task: $TASK_ARN"
  if [ $RUN_TASK_WAIT_FOR_SUCCESS == true ]; then
    RUN_TASK_SUCCESS=false; every=10; i=0
    while [ $i -lt $TIMEOUT ]; do
      TASK_JSON=$($AWS_ECS describe-tasks --cluster "$CLUSTER"  --tasks "$TASK_ARN")
      TASK_STATUS=$(echo $TASK_JSON | jq -r  '.tasks[0].lastStatus'); TASK_EXIT_CODE=$(echo $TASK_JSON | jq -r  '.tasks[0].containers[0].exitCode')
      if [ $TASK_STATUS == "STOPPED" ]; then
        echo "Task finished with status: $TASK_STATUS"
        if [ $TASK_EXIT_CODE != 0 ]; then echo "Task failed with exit code: $TASK_EXIT_CODE"; exit 1; fi
        RUN_TASK_SUCCESS=true; break
      fi
      echo "Task status: $TASK_STATUS (checking every $every s)"; sleep $every; i=$(( i + every ))
    done
    if [ $RUN_TASK_SUCCESS == false ]; then echo "ERROR: Task run exceeded $TIMEOUT seconds"; exit 1; fi
  fi
  echo "Task $TASK_ARN executed successfully!"; exit 0
}

if [ "$BASH_SOURCE" == "$0" ]; then
  set -o errexit -o pipefail -o nounset
  if [ $# == 0 ]; then usage; fi
  require aws; require jq
  while [[ $# -gt 0 ]]; do
    key="$1"; case $key in
      -k|--aws-access-key) AWS_ACCESS_KEY_ID="$2"; shift;;
      -s|--aws-secret-key) AWS_SECRET_ACCESS_KEY="$2"; shift;;
      -r|--region) AWS_DEFAULT_REGION="$2"; shift;;
      -p|--profile) AWS_PROFILE="$2"; shift;;
      --aws-instance-profile) AWS_IAM_ROLE=true;;
      -a|--aws-assume-role) AWS_ASSUME_ROLE="$2"; shift;;
      -c|--cluster) CLUSTER="$2"; shift;;
      -n|--service-name) SERVICE="$2"; shift;;
      -d|--task-definition) TASK_DEFINITION="$2"; shift;;
      -i|--image) IMAGE="$2"; shift;;
      -t|--timeout) TIMEOUT="$2"; shift;;
      -m|--min) MIN="$2"; shift;;
      -M|--max) MAX="$2"; shift;;
      -D|--desired-count) DESIRED="$2"; shift;;
      -e|--tag-env-var) TAGVAR="$2"; shift;;
      -to|--tag-only) TAGONLY="$2"; shift;;
      --max-definitions) MAX_DEFINITIONS="$2"; shift;;
      --task-definition-file) TASK_DEFINITION_FILE="$2"; shift;;
      --enable-rollback) ENABLE_ROLLBACK=true;;
      --use-latest-task-def) USE_MOST_RECENT_TASK_DEFINITION=true;;
      --force-new-deployment) FORCE_NEW_DEPLOYMENT=true;;
      --skip-deployments-check) SKIP_DEPLOYMENTS_CHECK=true;;
      --run-task) RUN_TASK=true;;
      --launch-type) RUN_TASK_LAUNCH_TYPE="$2"; shift;;
      --platform-version) RUN_TASK_PLATFORM_VERSION="$2"; shift;;
      --wait-for-success) RUN_TASK_WAIT_FOR_SUCCESS=true;;
      --network-configuration) RUN_TASK_NETWORK_CONFIGURATION="$2"; shift;;
      --copy-task-definition-tags) COPY_TASK_DEFINITION_TAGS=true;;
      -C|--container-name) CONTAINER_NAME="$2"; shift;;
      -v|--verbose) VERBOSE=true;;
      --version) echo ${VERSION}; exit 0;;
      *) [[ -n $key ]] && usage || true;;
    esac; shift || true
  done
  if [ $VERBOSE == true ]; then set -x; fi
  assertRequiredArgumentsSet
  if [[ "$AWS_ASSUME_ROLE" != false ]]; then assumeRole; fi
  if [ $FORCE_NEW_DEPLOYMENT == true ]; then
    updateServiceForceNewDeployment; [[ $SKIP_DEPLOYMENTS_CHECK != true ]] && waitForGreenDeployment; exit 0
  fi
  parseImageName; echo "Using image: $useImage"
  getCurrentTaskDefinition; echo "Current task def: $TASK_DEFINITION_ARN"
  createNewTaskDefJson
  registerNewTaskDefinition; echo "New task def: $NEW_TASKDEF"; [[ $CONTAINER_NAME != false ]] && echo "(Updated only container $CONTAINER_NAME)"
  if [ $SERVICE == false ]; then
    if [ $RUN_TASK == true ]; then runTask; fi
    echo "Task definition updated successfully";
  else
    updateService; [[ $SKIP_DEPLOYMENTS_CHECK != true ]] && waitForGreenDeployment
  fi
  if [[ "$AWS_ASSUME_ROLE" != false ]]; then assumeRoleClean; fi
  exit 0
fi
