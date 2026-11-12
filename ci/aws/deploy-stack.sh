#!/usr/bin/env bash
# Copyright 2026 The MathWorks, Inc.
#MISE description="Deploy a compiled template as a test stack and print its outputs as JSON"
#MISE tools={aws-cli="2.39.6", jq="1.8.1"}
#
# Deploys a compiled template as a test stack: stages it in S3, creates the stack with the test
# parameters of its refarch type, waits for it, and prints the stack outputs as one line of JSON.
# Run it with `mise run aws:deploy-stack`. AWS credentials come from the standard chain.
#
# Environment:
#   TEMPLATE_FILE   the compiled template
#   REFARCH_TYPE    a key of ci/aws/refarch-type-mappings.json, such as matlab-linux
#   REGION          the region to deploy in
#   STACK_NAME      unique per run and release
#   VPC, SUBNET     where to deploy
#   KEY             an existing EC2 key pair
#   STAGING_BUCKET  an S3 bucket in REGION, with a lifecycle rule expiring the cfn-staging/ prefix
#   CLIENT_CIDR     optional: who may connect; this machine's public IPv4 address/32 by default
#   OUTPUTS_FILE    optional: also write the stack outputs there
#   BASE_DIR        optional: what relative paths are relative to; the current directory by default

MAPPINGS_FILE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/refarch-type-mappings.json"

# Fails, listing the known types, unless ci/aws/refarch-type-mappings.json has the refarch type.
check_refarch_type() {
    if ! jq -e --arg t "$1" '.[$t]' "$MAPPINGS_FILE" > /dev/null 2>&1; then
        echo "::error::Unknown refarch_type '$1'. Available types: $(jq -r 'keys | join(", ")' "$MAPPINGS_FILE")"
        return 1
    fi
}

# Prints the stack parameters as JSON: the refarch type's defaults, the network and access values, and
# the password for each password parameter the template declares.
# Usage: build_parameters <refarch-type> <template> <vpc> <subnet> <key> <client-cidr> <password>
build_parameters() {
    # Only Password / ConfirmPassword parameters that the compiled template declares are set (added if
    # absent, updated if present), so CloudFormation never gets an unknown parameter.
    jq --arg t "$1" --arg vpc "$3" --arg subnet "$4" --arg key "$5" --arg ip "$6" --arg pw "$7" \
        --slurpfile tmpl "$2" '
        .[$t] as $m
        | $m.defaults + [
            {"ParameterKey": $m.vpc_param, "ParameterValue": $vpc},
            {"ParameterKey": $m.subnet_param, "ParameterValue": $subnet},
            {"ParameterKey": $m.key_param, "ParameterValue": $key},
            {"ParameterKey": $m.client_ip_param, "ParameterValue": $ip}
          ]
        | ($tmpl[0].Parameters // {}) as $tp
        | reduce ["Password", "ConfirmPassword"][] as $name (.;
            if ($tp | has($name)) then
              if any(.[]; .ParameterKey == $name)
              then map(if .ParameterKey == $name then .ParameterValue = $pw else . end)
              else . + [{"ParameterKey": $name, "ParameterValue": $pw}]
              end
            else . end)
        ' "$MAPPINGS_FILE"
}

# Prints a 20-character password that satisfies all known MATLAB / NLM rules: >=14 characters,
# with upper, lower, digit and special characters.
generate_password() {
    # Read a bounded block from /dev/urandom before filtering: piping an unbounded stream straight into
    # `head -c` makes `tr` die on SIGPIPE when head closes the pipe, which aborts under pipefail.
    gen() { LC_ALL=C head -c 8192 /dev/urandom | LC_ALL=C tr -dc "$1" | head -c "$2"; }
    echo "$(gen 'A-Z' 1)$(gen 'a-z' 1)$(gen '0-9' 1)$(gen '!@#%^_+=-' 1)$(gen 'A-Za-z0-9' 16)"
}

# Prints the parameters JSON on stdin with the password values replaced.
redact_parameters() {
    jq 'map(if .ParameterKey == "Password" or .ParameterKey == "ConfirmPassword" then .ParameterValue = "***" else . end)'
}

# Sets CLIENT_CIDR to this machine's public IPv4 address as a /32.
set_public_client_cidr() {
    local ip
    ip=$(curl -fsS --retry 3 --max-time 10 https://checkip.amazonaws.com | tr -d '[:space:]')
    if ! [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "::error::Failed to resolve runner public IPv4 (got: '$ip')"
        return 1
    fi
    CLIENT_CIDR="$ip/32"
}

main() {
    set -euo pipefail
    cd "${BASE_DIR:-.}"

    if [[ ! -f "${TEMPLATE_FILE:-}" ]]; then
        echo "::error::Template file not found at ${TEMPLATE_FILE:-}"
        exit 1
    fi
    if [ -z "${STAGING_BUCKET:-}" ]; then
        echo "::error::template_staging_bucket is empty. Set it from a TEMPLATE_STAGING_BUCKET repository variable."
        exit 1
    fi

    check_refarch_type "$REFARCH_TYPE"

    local password
    password=$(generate_password)
    if [ "${#password}" -lt 14 ]; then
        echo "::error::Generated password too short (${#password} chars); entropy source may be unavailable"
        exit 1
    fi
    if [[ "${GITHUB_ACTIONS:-}" == "true" ]]; then
        echo "::add-mask::$password"
    fi
    if [ -z "${CLIENT_CIDR:-}" ]; then
        set_public_client_cidr
    fi

    # Not local: the trap runs after main returns.
    params=$(mktemp)
    trap 'rm -f "$params"' EXIT
    build_parameters "$REFARCH_TYPE" "$TEMPLATE_FILE" "$VPC" "$SUBNET" "$KEY" "$CLIENT_CIDR" "$password" > "$params"
    echo "Generated Parameters (passwords redacted):"
    redact_parameters < "$params"

    # Always by URL: --template-body caps at 51200 bytes and the templates are close to it. The key
    # carries the stack name, unique per run and version.
    local template_key
    template_key="cfn-staging/${STACK_NAME}/$(basename "$TEMPLATE_FILE")"
    echo "Staging template at s3://${STAGING_BUCKET}/${template_key}"
    aws s3 cp "$TEMPLATE_FILE" "s3://${STAGING_BUCKET}/${template_key}" --region "$REGION"

    aws cloudformation create-stack \
        --stack-name "$STACK_NAME" \
        --template-url "https://${STAGING_BUCKET}.s3.${REGION}.amazonaws.com/${template_key}" \
        --region "$REGION" \
        --capabilities CAPABILITY_NAMED_IAM CAPABILITY_AUTO_EXPAND \
        --tags Key=ManagedBy,Value=mw-public-actions-ci \
        --parameters "file://$params"

    echo "Waiting for stack creation..."
    if ! aws cloudformation wait stack-create-complete --stack-name "$STACK_NAME" --region "$REGION" 2>&1; then
        echo "::error::CloudFormation stack creation failed for $STACK_NAME"
        aws cloudformation describe-stack-events \
            --stack-name "$STACK_NAME" \
            --region "$REGION" \
            --query "StackEvents[?ResourceStatus=='CREATE_FAILED'].[LogicalResourceId,ResourceStatusReason]" \
            --output table
        exit 1
    fi

    # Outputs as a flat JSON object { "OutputKey": "OutputValue" }.
    local outputs
    outputs=$(aws cloudformation describe-stacks \
        --stack-name "$STACK_NAME" \
        --region "$REGION" \
        --query "Stacks[0].Outputs" |
        jq -c 'reduce (. // [])[] as $item ({}; . + {($item.OutputKey): $item.OutputValue})')
    echo "Stack outputs: $outputs"
    if [ -n "${OUTPUTS_FILE:-}" ]; then
        echo "$outputs" > "$OUTPUTS_FILE"
    fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
