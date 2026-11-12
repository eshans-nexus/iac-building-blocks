#!/usr/bin/env bash
# Copyright 2026 The MathWorks, Inc.
#MISE description="Delete a test stack and wait for the deletion"
#MISE tools={aws-cli="2.39.6"}
#
# Deletes a test stack and waits. A deletion that doesn't finish is a warning, not a failure, so that
# cleaning up never fails a test run. Run it with `mise run aws:delete-stack`. AWS credentials come from
# the standard chain.
#
# Environment:
#   STACK_NAME  the stack to delete
#   REGION      the region it is in

set -euo pipefail

echo "Deleting stack ${STACK_NAME}..."
aws cloudformation delete-stack --stack-name "$STACK_NAME" --region "$REGION"
echo "Waiting for stack deletion..."
if ! aws cloudformation wait stack-delete-complete --stack-name "$STACK_NAME" --region "$REGION" 2>/dev/null; then
    echo "::warning::Stack deletion may not have completed for ${STACK_NAME}. Check the AWS console for orphaned resources."
fi
