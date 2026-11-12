# CI scripts

The steps the GitHub workflows run to test and release the templates, as [mise](https://mise.jdx.dev) tasks. The workflows only set the inputs and run `mise run <task>`, so you can run the same steps yourself, or from another CI system.

Each executable script in `ci/<cloud>/` is a task named `<cloud>:<script>`. `mise tasks ls` lists them.

| Task | What it does | Inputs (environment variables) |
| ---- | ------------ | ------------------------------ |
| `aws:render-template` | Writes a CloudFormation template from a meta-template, with a RegionMap and any Lambda code injected | `TEMPLATE`, `REGION_MAP`, `OUT_NAME`; optional `LAMBDA_INJECTIONS` |
| `aws:deploy-stack` | Deploys a template as a test stack, waits for it, and prints the stack outputs as JSON | `TEMPLATE_FILE`, `REFARCH_TYPE`, `REGION`, `STACK_NAME`, `VPC`, `SUBNET`, `KEY`, `STAGING_BUCKET`; optional `CLIENT_CIDR`, `OUTPUTS_FILE` |
| `aws:delete-stack` | Deletes a test stack and waits for the deletion | `STACK_NAME`, `REGION` |

The top of each script describes its inputs.

## Run them yourself

You need:
- mise 2026.10.8 or later. Each task installs the tools it needs, such as the AWS CLI, the first time it runs.
- For `aws:deploy-stack` and `aws:delete-stack`: AWS credentials, from any source the AWS CLI reads (for example `AWS_PROFILE`), and in the region you deploy to, a VPC, a subnet, an EC2 key pair and an S3 bucket for staging templates.

Tasks run in this repository's root. To pass paths relative to another folder, such as a reference architecture repository, set `BASE_DIR` to that folder. For example, from a clone of [matlab-on-aws](https://github.com/mathworks-ref-arch/matlab-on-aws), with this repository cloned at `$IAC`:

```sh
mise trust "$IAC"   # once per clone
export BASE_DIR="$PWD" REGION=us-east-1 STACK_NAME="my-test-$(date +%s)"

TEMPLATE=src/aws-matlab-template.json OUT_NAME=template.json \
REGION_MAP='{"us-east-1": {"AMI": "<ami-id>"}}' \
    mise -C "$IAC" run aws:render-template

TEMPLATE_FILE=template.json REFARCH_TYPE=matlab-linux \
VPC=<vpc-id> SUBNET=<subnet-id> KEY=<key-pair-name> STAGING_BUCKET=<bucket> \
    mise -C "$IAC" run aws:deploy-stack

mise -C "$IAC" run aws:delete-stack
```

A deployed stack creates billable resources: delete it when you are done. By default, only this machine's public IPv4 address can connect to the stack; set `CLIENT_CIDR` to allow another range.

## Add a task

Add an executable script to `ci/<cloud>/`, with `#MISE description="..."` and `#MISE tools={...}` lines after its copyright line, and its inputs listed in its header. The task needs no change to `mise.toml`.
