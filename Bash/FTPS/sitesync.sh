#!/bin/bash

# Load environment variables
SCRIPT_DIR="$(dirname "$0")"
ENV_FILE="$SCRIPT_DIR/sitesync.env"
if [ -f "$ENV_FILE" ]; then
    source "$ENV_FILE"
else
    echo "Environment file not found: $ENV_FILE"
    exit 1
fi

# Ensure SSH key exists and add it to the agent
function ensure_ssh_key() {
    if [ ! -f "$SSH_KEY_PATH" ]; then
        echo "SSH key not found at $SSH_KEY_PATH."
        echo "Generating a new SSH key..."
        mkdir -p "$(dirname \"$SSH_KEY_PATH\")"
        ssh-keygen -t rsa -b 4096 -C "$SSH_KEY_EMAIL" -f "$SSH_KEY_PATH" -N ""
        echo "SSH key generated."

        echo "Please add the following public key to your GitHub repository as a deploy key:"
        cat "${SSH_KEY_PATH}.pub"
        echo "Visit https://github.com/GithubUSER/repoSITEcom/settings/keys to add the key."
        echo "Re-run the script after adding the key."
        exit 1
    fi

    echo "SSH key found at $SSH_KEY_PATH. Proceeding..."
    eval "$(ssh-agent -s)"
    ssh-add "$SSH_KEY_PATH" </dev/null
}

# Ensure Git repository is valid and properly configured
function ensure_git_repo() {
    if [ ! -d "$LOCAL_REPO" ]; then
        echo "$LOCAL_REPO does not exist. Cloning the repository..."
        git clone "$GIT_REMOTE_URL" "$LOCAL_REPO"
    fi

    cd "$LOCAL_REPO" || exit 1

    if [ ! -d ".git" ]; then
        echo ".git directory is missing. Restoring Git repository..."
        git init
        git remote add origin "$GIT_REMOTE_URL"
        git fetch origin "$BRANCH"
        git checkout -b "$BRANCH" --track origin/"$BRANCH" || git checkout -b "$BRANCH"
    else
        git checkout "$BRANCH" 2>/dev/null || git checkout -b "$BRANCH"
        git pull origin "$BRANCH" || echo "Failed to pull from remote."
    fi

    # Configure Git user information
    git config user.name "$GIT_USER_NAME"
    git config user.email "$GIT_USER_EMAIL"
}

# Download files via FTPS, excluding the .git directory and its contents
function download_ftps() {
    echo "Starting FTPS download..."

    lftp -u "$FTPS_USER","$FTPS_PASS" ftps://"$FTPS_SERVER" <<EOF
mirror --verbose --continue --delete --parallel=2 \
--exclude-glob ".git" --exclude-glob ".git/**" --exclude-glob ".ssh*" \
"$FTPS_REMOTE_DIR" "$LOCAL_REPO"
quit
EOF

    if [ $? -ne 0 ]; then
        echo "Error: FTPS download failed."
        exit 1
    fi
}

# Perform Git operations
function perform_git_operations() {
    echo "Performing Git operations..."
    cd "$LOCAL_REPO" || exit 1

    # Add and commit any new changes
    git add --all
    git commit -m "Automated update from FTPS $(date)" || echo "No changes to commit."

    # Pull latest changes from remote, preferring our local changes in conflicts
    git pull origin "$BRANCH" --strategy=recursive -X ours --no-edit || echo "Pull failed, attempting to continue."

    # Push changes to the remote repository
    git push origin "$BRANCH" || {
        echo "Standard push failed. Force pushing to remote repository..."
        git push --force origin "$BRANCH"
    }
}

# Skip FTPS if a key is pressed
function maybe_skip_ftps() {
    echo "Press any key to skip the FTPS download, or wait 5 seconds to continue."
    read -t 5 -n 1 SKIP </dev/tty
    EXIT_STATUS=$?
    if [ $EXIT_STATUS -eq 0 ]; then
        echo -e "\nSkipping FTPS download..."
        return 0
    else
        echo -e "\nProceeding with FTPS download..."
        return 1
    fi
}

# Main execution
cd "$SCRIPT_DIR"  # Change to script directory
ensure_ssh_key
ensure_git_repo

if ! maybe_skip_ftps; then
    download_ftps
else
    echo "FTPS download skipped."
fi

perform_git_operations
echo "Sync completed successfully."
