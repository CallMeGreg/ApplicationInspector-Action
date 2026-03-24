#!/bin/bash

# $1 is the path relative to repo root to scan
# $2 is the output path relative to repo root.
# $3 is the output format
# $4 is the comma separated list to glob patterns to ignore
# $5 is the arguments
# $6 is if beta should be used
# $7 is if tagdiff comparison should be used

if [ ${3,,} = "html" ]; then
    echo "html output is not supported in the GitHub Action."
    exit -1
fi

if [ "$1" = "GITHUB_WORKSPACE" ]; then
    ScanTarget=$GITHUB_WORKSPACE
else
    ScanTarget=$GITHUB_WORKSPACE/$1
fi

if [ "$2" = "AppInspectorResults" ]; then
    OutputPath=$GITHUB_WORKSPACE/$2.$3
else
    OutputPath=$GITHUB_WORKSPACE/$2
fi

if [ "$4" != "," ]; then
    IFS=',' read -ra SPLITS <<< "$4"
    for i in "${SPLITS[@]}"; do
        IgnoreArg="${IgnoreArg},$GITHUB_WORKSPACE/$i"
    done
    IgnoreArg="-g ${IgnoreArg:1}"
fi

# Select AppInspector binary
if [ "$6" = "true" ]; then
    APPINSPECTOR="/beta-tools/appinspector"
else
    APPINSPECTOR="/tools/appinspector"
fi

# --- Tagdiff mode: compare tags between PR base and head branches ---
if [ "$7" = "true" ]; then
    if [ "$GITHUB_EVENT_NAME" != "pull_request" ] && [ "$GITHUB_EVENT_NAME" != "pull_request_target" ]; then
        echo "::error::tagdiff mode is only supported in pull_request workflows. Current event: $GITHUB_EVENT_NAME"
        exit 1
    fi

    if [ -z "$GITHUB_TOKEN" ]; then
        echo "::error::github-token input is required when tagdiff is enabled."
        exit 1
    fi

    echo "::group::Tag Diff - Fetching base branch"
    git config --global --add safe.directory "$GITHUB_WORKSPACE"
    cd "$GITHUB_WORKSPACE" || exit 1
    git fetch --depth 1 origin "$GITHUB_BASE_REF"

    BASE_DIR=$(mktemp -d)
    git archive "origin/$GITHUB_BASE_REF" | tar -x -C "$BASE_DIR"
    echo "Base branch ($GITHUB_BASE_REF) extracted to $BASE_DIR"
    echo "::endgroup::"

    # Determine scan targets for tagdiff
    if [ "$1" = "GITHUB_WORKSPACE" ]; then
        HeadScanTarget="$GITHUB_WORKSPACE"
        BaseScanTarget="$BASE_DIR"
    else
        HeadScanTarget="$GITHUB_WORKSPACE/$1"
        BaseScanTarget="$BASE_DIR/$1"
    fi

    echo "::group::Tag Diff - Running Application Inspector tagdiff"
    TAGDIFF_OUTPUT="/tmp/tagdiff_results.json"
    $APPINSPECTOR tagdiff --src1 "$BaseScanTarget" --src2 "$HeadScanTarget" -f json -o "$TAGDIFF_OUTPUT" --no-show-progress $IgnoreArg
    TAGDIFF_EXIT=$?
    echo "::endgroup::"

    # Exit codes: 0 = no changes, 1 = changes detected, >=2 = error
    if [ $TAGDIFF_EXIT -gt 1 ]; then
        echo "::warning::Application Inspector tagdiff exited with code $TAGDIFF_EXIT"
    fi

    if [ -f "$TAGDIFF_OUTPUT" ]; then
        echo "::group::Tag Diff - Building PR comment"

        # Parse tagdiff results (handle both camelCase and PascalCase JSON keys)
        ADDED_TAGS=$(jq -r '
            (.tagDiffList // .TagDiffList // [])[] |
            select((.state // .State) == "Added" or (.state // .State) == "added") |
            (.tag // .Tag)
        ' "$TAGDIFF_OUTPUT" 2>/dev/null || true)

        REMOVED_TAGS=$(jq -r '
            (.tagDiffList // .TagDiffList // [])[] |
            select((.state // .State) == "Removed" or (.state // .State) == "removed") |
            (.tag // .Tag)
        ' "$TAGDIFF_OUTPUT" 2>/dev/null || true)

        # Count tags
        if [ -z "$ADDED_TAGS" ]; then
            ADDED_COUNT=0
        else
            ADDED_COUNT=$(echo "$ADDED_TAGS" | wc -l)
        fi
        if [ -z "$REMOVED_TAGS" ]; then
            REMOVED_COUNT=0
        else
            REMOVED_COUNT=$(echo "$REMOVED_TAGS" | wc -l)
        fi

        # Build markdown comment
        COMMENT_FILE="/tmp/tagdiff_comment.md"
        {
            echo "<!-- appinspector-tagdiff -->"
            echo "## 🔍 Application Inspector - Tag Diff"
            echo ""
            echo "Comparison of source code tags between \`$GITHUB_BASE_REF\` and this pull request."
            echo ""

            if [ "$ADDED_COUNT" -eq 0 ] && [ "$REMOVED_COUNT" -eq 0 ]; then
                echo "✅ **No tag differences detected.** The changes in this PR do not affect the detected feature tags."
            else
                if [ "$ADDED_COUNT" -gt 0 ]; then
                    echo "### 🆕 New Tags"
                    echo "These tags were **added** by the changes in this PR:"
                    echo ""
                    echo "$ADDED_TAGS" | while IFS= read -r tag; do
                        echo "- \`$tag\`"
                    done
                    echo ""
                fi

                if [ "$REMOVED_COUNT" -gt 0 ]; then
                    echo "### ❌ Removed Tags"
                    echo "These tags are **no longer detected** after the changes in this PR:"
                    echo ""
                    echo "$REMOVED_TAGS" | while IFS= read -r tag; do
                        echo "- \`$tag\`"
                    done
                    echo ""
                fi

                echo "### 📊 Summary"
                echo "- **$ADDED_COUNT** new tag(s) added"
                echo "- **$REMOVED_COUNT** tag(s) removed"
            fi

            echo ""
            echo "---"
            echo "*Generated by [Application Inspector](https://github.com/microsoft/ApplicationInspector)*"
        } > "$COMMENT_FILE"

        echo "::endgroup::"

        echo "::group::Tag Diff - Posting PR comment"

        PR_NUMBER=$(jq -r '.pull_request.number' "$GITHUB_EVENT_PATH")

        if [ -z "$PR_NUMBER" ] || [ "$PR_NUMBER" = "null" ]; then
            echo "::warning::Could not determine PR number from event payload."
        else
            # Check for existing tagdiff comment to update instead of duplicating
            EXISTING_COMMENT_ID=$(curl -s \
                -H "Authorization: token $GITHUB_TOKEN" \
                -H "Accept: application/vnd.github.v3+json" \
                "$GITHUB_API_URL/repos/$GITHUB_REPOSITORY/issues/$PR_NUMBER/comments?per_page=100" \
                | jq -r '[.[] | select(.body | contains("<!-- appinspector-tagdiff -->"))] | last | .id // empty')

            # Build JSON payload with proper escaping
            BODY=$(jq -Rs '.' "$COMMENT_FILE")
            PAYLOAD=$(jq -n --argjson body "$BODY" '{"body": $body}')

            if [ -n "$EXISTING_COMMENT_ID" ]; then
                echo "Updating existing comment $EXISTING_COMMENT_ID"
                curl -s -X PATCH \
                    -H "Authorization: token $GITHUB_TOKEN" \
                    -H "Accept: application/vnd.github.v3+json" \
                    "$GITHUB_API_URL/repos/$GITHUB_REPOSITORY/issues/comments/$EXISTING_COMMENT_ID" \
                    -d "$PAYLOAD" > /dev/null
            else
                echo "Creating new comment on PR #$PR_NUMBER"
                curl -s -X POST \
                    -H "Authorization: token $GITHUB_TOKEN" \
                    -H "Accept: application/vnd.github.v3+json" \
                    "$GITHUB_API_URL/repos/$GITHUB_REPOSITORY/issues/$PR_NUMBER/comments" \
                    -d "$PAYLOAD" > /dev/null
            fi

            echo "PR comment posted successfully."
        fi

        echo "::endgroup::"
    else
        echo "::warning::tagdiff output file not found. Skipping PR comment."
    fi

    # Cleanup
    rm -rf "$BASE_DIR"
fi

# --- Standard analyze ---
$APPINSPECTOR analyze --no-show-progress -s "$ScanTarget" -o "$OutputPath" -f $3 $IgnoreArg $5