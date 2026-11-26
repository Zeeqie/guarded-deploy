# Lambda alias `live` explained (`infra/lambda.tf`)

The public URL never points at code directly. It points at an **alias** called `live`, and the alias points at one **published version** (an immutable snapshot of code + config). Deploying means publishing a new version and moving the alias. Rolling back means moving it back.

```
API Gateway ──> alias "live" ──> version N   (immutable)
                                 version N-1 (still there for instant rollback)
```

## The function's relevant lines

| Line | What it does | Why | What breaks without it | Interview question it answers |
|---|---|---|---|---|
| `package_type = "Image"` | Code comes from a container image in ECR, not a zip | Same image is built, scanned, and run | Would need a separate zip build path | "Why container images for Lambda?" |
| `image_uri = "<repo>:${var.initial_image_tag}"` | Image the function is *created* with | Lambda can't exist without code | `terraform apply` fails: no image | "How did you solve the chicken-and-egg of creating a Lambda before CI has pushed?" |
| `publish = true` | Creation also publishes version `1` | The alias needs a numbered version to point at; `$LATEST` is mutable | Alias would have to use `$LATEST`, so a code update would go live untested | "What's the difference between `$LATEST` and a version?" |
| `lifecycle { ignore_changes = [image_uri] }` | Terraform stops tracking which image is deployed | The CD pipeline owns code (`UpdateFunctionCode`) | The next `terraform apply` silently rolls code back to the initial image | "How do Terraform and a deploy pipeline share one resource without fighting?" |
| `GIT_SHA` *not* in `environment` | Version string comes only from the image's `ENV` | A config env var could shadow the image value and keep reporting the creation SHA | `/health` could report the wrong version, so the smoke test can't prove which build is live | "How do you know which build is serving traffic?" |

## The alias

| Line | What it does | Why | What breaks without it | Interview question it answers |
|---|---|---|---|---|
| `resource "aws_lambda_alias" "live"` | A named, movable pointer to one version | Gives API Gateway a stable target while versions change underneath | API Gateway would need re-pointing on every deploy | "What is a Lambda alias for?" |
| `name = "live"` | The alias name; its ARN is `...:function:guarded-deploy:live` | The pipeline and API refer to it by name | — | — |
| `function_version = aws_lambda_function.app.version` | Initial target: version `1` from `publish = true` | Something must be live on day one | Alias creation fails (it needs a version) | — |
| `lifecycle { ignore_changes = [function_version] }` | Terraform creates the alias but never moves it again | The pipeline moves `live` N-1 → N after the smoke test passes, or leaves it on N-1 on failure | Every `terraform apply` would yank traffic back to version 1: an unintended rollback | "Why `ignore_changes` here, and what is the risk?" |

## Where the alias is used

| Line (`infra/main.tf`) | What it does | Why |
|---|---|---|
| `integration_uri = aws_lambda_alias.live.invoke_arn` | API Gateway invokes the **qualified** alias ARN | Traffic only reaches what `live` points at, never `$LATEST` or a half-tested version |
| `aws_lambda_permission` with `qualifier = "live"` | Allows API Gateway to invoke **only** the alias, and only from this API (`source_arn`) | A smoke test can invoke version N directly (`--qualifier N`) without it being public |

## Trade-off to know

`ignore_changes` means Terraform's state no longer reflects which version or image is live: drift is intentional. To see the truth, run `aws lambda get-alias --function-name guarded-deploy --name live`. Terraform then only owns the *shape* (memory, timeout, env, role); the pipeline owns *what runs*.
