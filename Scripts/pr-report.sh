#!/usr/bin/env bash
#
# pr-report.sh <marker> <body-file>
#
# Maintains *this job's* report comment on the pull request.
#
# `gh pr comment --edit-last` edits whatever comment the bot wrote last, so
# with two jobs reporting into the same pull request one of them silently
# overwrites the other's message (that is how the Swift failure of run
# 40150617119 disappeared). Each job therefore owns a comment that it finds by
# a hidden marker and edits in place.
#
# Requires GH_TOKEN and PR_NUMBER; a no-op when either is missing or the body
# is empty, because this must never turn a build failure into a reporting
# failure.
set -euo pipefail

marker="${1:?usage: pr-report.sh <marker> <body-file>}"
body="${2:?usage: pr-report.sh <marker> <body-file>}"
repo="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is not set}"
pr="${PR_NUMBER:?PR_NUMBER is not set}"

[[ -s "${body}" ]] || { echo "pr-report: ${body} is empty, nothing to post"; exit 0; }

tmp="$(mktemp)"
trap 'rm -f "${tmp}"' EXIT
{
    echo "<!-- ${marker} -->"
    cat "${body}"
} > "${tmp}"

id="$(gh api "repos/${repo}/issues/${pr}/comments?per_page=100" \
        --jq ".[] | select(.body | contains(\"${marker}\")) | .id" 2>/dev/null | head -1 || true)"

if [[ -n "${id}" ]]; then
    gh api -X PATCH "repos/${repo}/issues/comments/${id}" -f "body=@${tmp}" --silent \
        && echo "pr-report: updated comment ${id}"
else
    gh api -X POST "repos/${repo}/issues/${pr}/comments" -f "body=@${tmp}" --silent \
        && echo "pr-report: created a comment"
fi
