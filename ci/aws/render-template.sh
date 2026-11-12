#!/usr/bin/env bash
# Copyright 2026 The MathWorks, Inc.
#MISE description="Write a CloudFormation template with a RegionMap and any Lambda code injected"
#MISE tools={jq="1.8.1"}
#
# Writes a CloudFormation template from a meta-template: sets its RegionMap, and injects the source of
# each listed Lambda function into the function's Code.ZipFile. Run it with
# `mise run aws:render-template`.
#
# Environment:
#   TEMPLATE           the meta-template, a JSON file
#   REGION_MAP         the RegionMap, a JSON object
#   OUT_NAME           where to write the template
#   LAMBDA_INJECTIONS  optional: Lambda resource logical IDs to source files, for example
#                      '{"AttachInstanceProfileLambda": "src/attachinstanceprofile.py"}'
#   BASE_DIR           optional: what relative paths are relative to; the current directory by default

main() {
    set -euo pipefail
    cd "${BASE_DIR:-.}"

    if [ -z "${REGION_MAP:-}" ]; then
        echo "::error::region_map input is empty"
        exit 1
    fi
    if [ ! -f "${TEMPLATE:-}" ]; then
        echo "::error::Meta-template not found at: ${TEMPLATE:-}"
        exit 1
    fi
    if ! echo "$REGION_MAP" | jq empty 2>/dev/null; then
        echo "::error::region_map is not valid JSON: $REGION_MAP"
        exit 1
    fi

    echo "Injecting Region Map into template..."
    jq --argjson map "$REGION_MAP" '.Mappings.RegionMap = $map' "$TEMPLATE" > "$OUT_NAME"

    local injections="${LAMBDA_INJECTIONS:-{\}}"
    if ! echo "$injections" | jq -e 'type == "object"' >/dev/null 2>&1; then
        echo "::error::lambda_injections is not a valid JSON object: $injections"
        exit 1
    fi

    local resource code_file
    while IFS=$'\t' read -r resource code_file; do
        [ -z "$resource" ] && continue
        if [ ! -f "$code_file" ]; then
            echo "::error::Lambda code file not found for $resource: $code_file"
            exit 1
        fi
        if ! jq -e --arg r "$resource" '.Resources[$r]' "$OUT_NAME" >/dev/null; then
            echo "::error::Resource $resource not found in template $OUT_NAME"
            exit 1
        fi
        echo "Injecting Lambda code into $resource from $code_file..."
        jq --arg r "$resource" --rawfile code "$code_file" \
            '.Resources[$r].Properties.Code.ZipFile = $code' \
            "$OUT_NAME" > "${OUT_NAME}.tmp"
        mv "${OUT_NAME}.tmp" "$OUT_NAME"
    done < <(echo "$injections" | jq -r 'to_entries[] | "\(.key)\t\(.value)"')

    echo "Generated: $OUT_NAME"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
