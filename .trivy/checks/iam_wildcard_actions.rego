# METADATA
# title: IAM policy grants a wildcard action
# description: |
#   An Allow statement grants every action ("*"), every action of a service ("iam:*"), or
#   everything except a list (NotAction). Replaces bundled AWS-0057, which is deprecated and
#   ships empty in the Trivy checks bundle, so nothing caught `Action = "*"` (seeded defect #4).
#   Resource = "*" is NOT flagged: some actions (e.g. ecr:GetAuthorizationToken) only accept it.
# scope: package
# schemas:
#   - input: schema["cloud"]
# custom:
#   id: GD-0001
#   avd_id: GD-0001
#   provider: aws
#   service: iam
#   severity: HIGH
#   short_code: no-wildcard-actions
#   recommended_action: List the exact actions the principal needs (see docs/learning/oidc-trust-policy.md).
#   input:
#     selector:
#       - type: cloud
#         subtypes:
#           - service: iam
#             provider: aws
package user.aws.iam.gd0001

import rego.v1

# Action / NotAction may be a single string or a list in IAM JSON.
as_list(x) := x if is_array(x)

as_list(x) := [x] if is_string(x)

wildcard(action) if action == "*"

wildcard(action) if endswith(action, ":*") # whole service, e.g. "iam:*"

allow_statements(document) := [statement |
	some statement in as_list(json.unmarshal(document).Statement)
	lower(statement.Effect) == "allow"
]

problems(document) := {msg |
	some statement in allow_statements(document)
	some action in as_list(statement.Action)
	wildcard(action)
	msg := sprintf("Allow statement grants wildcard action '%s'", [action])
} | {msg |
	some statement in allow_statements(document)
	count(as_list(object.get(statement, "NotAction", []))) > 0 # adapter emits [] when unset
	msg := "Allow statement uses NotAction (grants everything not listed)"
}

deny contains res if {
	some policy in input.aws.iam.policies
	some msg in problems(policy.document.value)
	res := result.new(msg, policy.document)
}

deny contains res if {
	some role in input.aws.iam.roles
	some policy in role.policies
	some msg in problems(policy.document.value)
	res := result.new(sprintf("IAM role policy: %s", [msg]), policy.document)
}
