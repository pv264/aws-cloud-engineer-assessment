# Core Terraform rules (unused declarations, naming, deprecated syntax, typed variables...).
# The AWS ruleset (github.com/terraform-linters/tflint-ruleset-aws) can be added with a
# pinned version to also catch invalid instance types and similar provider-level errors.
plugin "terraform" {
  enabled = true
  preset  = "recommended"
}
