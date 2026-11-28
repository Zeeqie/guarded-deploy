"""Fail if any Terraform in infra/ or bootstrap/ grants a wildcard IAM action.

Why a text scan when Trivy has GD-0001 (.trivy/checks/)? Trivy 0.76.1 keeps only one
inline `aws_iam_role_policy` per role in its IAM model, so a SECOND inline policy on the
same role is invisible to every Trivy IAM check. That is exactly how seeded defect #4 was
written. This test reads the raw .tf text, so it can't share that blind spot. GD-0001 stays
because it sees evaluated policies (e.g. actions built from locals) that text can't.

Flags: any "*" or "<service>:*" in an actions/Action attribute, and any not_actions/NotAction
(Allow + NotAction grants everything not listed). Does NOT look at resources/Resource:
Resource = "*" is legitimate for actions like ecr:GetAuthorizationToken. Skips matches whose
enclosing block (HCL `statement {}` or jsonencode `{}` object) has Effect "Deny": denying
broadly is safe (e.g. bootstrap's TLS-only Deny on "s3:*"). Stdlib only.
"""

import re
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
TF_FILES = sorted([*ROOT.glob("infra/*.tf"), *ROOT.glob("bootstrap/*.tf")])

# actions = [...] / Action = "..." / Action = [...] (HCL and jsonencode), possibly multi-line.
ACTION_ATTR = re.compile(r"\b(not_actions|actions|NotAction|Action)\s*=\s*(\[[^\]]*\]|\"[^\"]*\")")
STRING = re.compile(r"\"([^\"]*)\"")
DENY = re.compile(r"\b[Ee]ffect\s*=\s*\"[Dd]eny\"")


def strip_comments(text: str) -> str:
    """Drop # and // comments, keeping line numbers. Ignores markers inside quotes."""
    out = []
    for line in text.splitlines():
        cut = len(line)
        in_quotes = False
        for i, ch in enumerate(line):
            if ch == '"':
                in_quotes = not in_quotes
            elif not in_quotes and (ch == "#" or line.startswith("//", i)):
                cut = i
                break
        out.append(line[:cut])
    return "\n".join(out)


def enclosing_block(text: str, pos: int) -> str:
    """Text of the innermost {...} around pos (statement block or jsonencode object)."""
    depth, start = 0, 0
    for i in range(pos, -1, -1):
        if text[i] == "}":
            depth += 1
        elif text[i] == "{":
            if depth == 0:
                start = i
                break
            depth -= 1
    depth = 0
    for j in range(start, len(text)):
        if text[j] == "{":
            depth += 1
        elif text[j] == "}":
            depth -= 1
            if depth == 0:
                return text[start : j + 1]
    return text[start:]


def wildcard_actions(text: str) -> list[tuple[int, str]]:
    text = strip_comments(text)
    hits = []
    for match in ACTION_ATTR.finditer(text):
        name, value = match.groups()
        line = text.count("\n", 0, match.start()) + 1
        if DENY.search(enclosing_block(text, match.start())):
            continue
        if name.lower().startswith("not"):
            hits.append((line, f"{name} grants everything not listed"))
            continue
        for action in STRING.findall(value):
            if action == "*" or action.endswith(":*"):
                hits.append((line, f'{name} contains "{action}"'))
    return hits


def test_terraform_files_found():
    assert len(TF_FILES) >= 5, TF_FILES  # guards against a glob silently matching nothing


@pytest.mark.parametrize("path", TF_FILES, ids=lambda p: str(p.relative_to(ROOT)))
def test_no_wildcard_iam_actions(path):
    assert wildcard_actions(path.read_text()) == []


# ---- unit tests of the scanner itself -------------------------------------------------


@pytest.mark.parametrize(
    "snippet",
    [
        'policy = jsonencode({ Statement = [{ Effect = "Allow", Action = "*", Resource = "*" }] })',
        'statement {\n  actions = [\n    "s3:GetObject",\n    "*",\n  ]\n}',
        'Action = ["iam:*"]',
        'not_actions = ["s3:DeleteBucket"]',
        'NotAction = "s3:DeleteBucket"',
        # Allow "*" next to a Deny sibling: the Deny must not excuse the Allow.
        'Statement = [{ Effect = "Deny", Action = "s3:*" }, { Effect = "Allow", Action = "*" }]',
    ],
)
def test_scanner_flags(snippet):
    assert wildcard_actions(snippet), snippet


@pytest.mark.parametrize(
    "snippet",
    [
        'actions = ["ecr:GetAuthorizationToken"]\nresources = ["*"]',  # Resource "*" is fine
        'Action = "sts:AssumeRoleWithWebIdentity"',
        'actions = ["s3:Get*"]',  # scoped prefix, not a whole service
        '# Action = "*" in a comment\n// actions = ["*"] too',
        'description = "Action = \\"*\\" inside a string is not an attribute"',
        # bootstrap's TLS-only bucket policy: broad Deny is safe.
        'statement {\n  effect  = "Deny"\n  actions = ["s3:*"]\n  principals {\n'
        '    type = "*"\n  }\n}',
    ],
)
def test_scanner_allows(snippet):
    assert wildcard_actions(snippet) == [], snippet
