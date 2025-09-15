#!/bin/bash

# Auto Git Commit with Ollama-generated messages
# Usage: ./commit.sh [model_name] [--dry-run]
# Example: ./commit.sh llama3.2 --dry-run

set -e

# Configuration
DEFAULT_MODEL="gpt-oss:20b"
OLLAMA_HOST="http://localhost:11434"
MAX_DIFF_LINES=100

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print colored output
print_status() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Function to check if we're in a git repository
check_git_repo() {
    if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        print_error "Not in a git repository!"
        exit 1
    fi
}

# Function to check if ollama is running
check_ollama() {
    if ! curl -s "$OLLAMA_HOST/api/version" >/dev/null 2>&1; then
        print_error "Ollama is not running or not accessible at $OLLAMA_HOST"
        print_error "Please start Ollama with: ollama serve"
        exit 1
    fi
}

# Function to check if model exists
check_model() {
    local model=$1
    if ! ollama list | grep -q "^$model"; then
        print_warning "Model '$model' not found locally."
        print_status "Available models:"
        ollama list
        read -p "Do you want to pull the model '$model'? (y/N): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            print_status "Pulling model '$model'..."
            ollama pull "$model"
        else
            print_error "Model '$model' is required. Exiting."
            exit 1
        fi
    fi
}

# Function to get git changes
get_git_changes() {
    local staged_files
    local unstaged_files
    local diff_output=""
    
    # Check for staged changes
    if git diff --cached --quiet; then
        # No staged changes, stage all modified files
        staged_files=$(git diff --name-only)
        if [ -z "$staged_files" ]; then
            print_warning "No changes detected in the repository."
            exit 0
        fi
        
        print_status "Staging all modified files..."
        git add -A
    fi
    
    # Get staged diff
    diff_output=$(git diff --cached)
    
    if [ -z "$diff_output" ]; then
        print_warning "No staged changes found."
        exit 0
    fi
    
    # Limit diff size for the AI model
    local diff_lines=$(echo "$diff_output" | wc -l)
    if [ "$diff_lines" -gt "$MAX_DIFF_LINES" ]; then
        print_warning "Diff is large ($diff_lines lines). Using summary instead."
        diff_output=$(git diff --cached --stat)
        diff_output+="\n\nFiles changed:\n"
        diff_output+=$(git diff --cached --name-only | head -20)
        if [ "$(git diff --cached --name-only | wc -l)" -gt 20 ]; then
            diff_output+="\n... and more files"
        fi
    fi
    
    echo "$diff_output"
}

# Function to generate commit message using Ollama
generate_commit_message() {
    local model=$1
    local changes=$2
    local prompt="Generate a git commit message in conventional format for these changes. Output ONLY the commit message, nothing else.

Format: type: description
Types: feat, fix, docs, style, refactor, test, chore
Keep description under 50 characters, lowercase, no period.

Changes:
$changes

Commit message:"

    print_status "Generating commit message using model: $model"
    
    local commit_msg
    local data
    data=$(jq -n --arg model "$model" --arg prompt "$prompt" '{
        model: $model,
        prompt: $prompt,
        stream: false,
        options: {
            temperature: 0,
            top_p: 1,
            top_k: 1
        }
    }')
    
    commit_msg=$(curl -s -X POST "$OLLAMA_HOST/api/generate" \
        -H "Content-Type: application/json" \
        -d "$data" | jq -r '.response' 2>/dev/null)
    
    if [ -z "$commit_msg" ] || [ "$commit_msg" = "null" ]; then
        print_error "Failed to generate commit message from Ollama"
        exit 1
    fi
    
    # Clean up the commit message (remove quotes, extra whitespace, and unwanted content)
    commit_msg=$(echo "$commit_msg" | sed 's/^"//;s/"$//' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    
    # Remove any lines that contain thinking or debug output and get the last meaningful line
    commit_msg=$(echo "$commit_msg" | grep -v -E "^\[|<think|Explanation|Output:|Commit message:" | tail -n1)
    
    # Extract and clean the commit message
    commit_msg=$(echo "$commit_msg" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | sed 's/\.$//') 
    
    # Fallback: if commit message is empty or looks like debug output, generate a simple one
    if [ -z "$commit_msg" ] || echo "$commit_msg" | grep -q -E "^\[|<think|INFO|ERROR|WARNING"; then
        # Simple fallback based on file changes
        local changed_files=$(git diff --cached --name-only | wc -l)
        if [ "$changed_files" -eq 1 ]; then
            local file_name=$(basename "$(git diff --cached --name-only)")
            commit_msg="chore: update $file_name"
        else
            commit_msg="chore: update $changed_files files"
        fi
    fi
    
    echo "$commit_msg"
}

# Function to display help
show_help() {
    echo "Auto Git Commit with Ollama"
    echo ""
    echo "Usage: $0 [model_name] [options]"
    echo ""
    echo "Options:"
    echo "  --dry-run    Show what would be committed without actually committing"
    echo "  --help       Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0                    # Use default model ($DEFAULT_MODEL)"
    echo "  $0 llama3.2          # Use specific model"
    echo "  $0 codellama --dry-run  # Dry run with codellama model"
    echo ""
    echo "Prerequisites:"
    echo "  - Ollama must be running (ollama serve)"
    echo "  - Must be in a git repository"
    echo "  - jq must be installed for JSON parsing"
}

# Parse arguments
MODEL="$DEFAULT_MODEL"
DRY_RUN=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --help)
            show_help
            exit 0
            ;;
        -*)
            print_error "Unknown option: $1"
            show_help
            exit 1
            ;;
        *)
            MODEL="$1"
            shift
            ;;
    esac
done

# Check dependencies
print_status "Checking dependencies..."

if ! command -v jq &> /dev/null; then
    print_error "jq is required but not installed. Please install it:"
    print_error "  Ubuntu/Debian: sudo apt install jq"
    print_error "  macOS: brew install jq"
    exit 1
fi

if ! command -v curl &> /dev/null; then
    print_error "curl is required but not installed."
    exit 1
fi

# Main execution
print_status "Starting auto-commit process..."
print_status "Using model: $MODEL"

check_git_repo
check_ollama
check_model "$MODEL"

# Get git changes
print_status "Analyzing git changes..."
changes=$(get_git_changes)

if [ -z "$changes" ]; then
    print_warning "No changes to commit."
    exit 0
fi

# Show changes summary
print_status "Changes to be committed:"
echo "----------------------------------------"
git diff --cached --stat
echo "----------------------------------------"

# Generate commit message
commit_msg=$(generate_commit_message "$MODEL" "$changes")

print_success "Generated commit message:"
echo -e "${GREEN}\"$commit_msg\"${NC}"

if [ "$DRY_RUN" = true ]; then
    print_warning "DRY RUN: Would commit with message: \"$commit_msg\""
    print_status "Staged files that would be committed:"
    git diff --cached --name-only
    exit 0
fi

# Perform the commit
print_status "Committing changes..."
if git commit -m "$commit_msg"; then
    print_success "Successfully committed with message: \"$commit_msg\""
    
    # Ask about pushing
    if git remote >/dev/null 2>&1; then
        echo ""
        read -p "Push to remote repository? (y/N): " -n 1 -r
        echo ""
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            print_status "Pushing to remote..."
            git push
            print_success "Successfully pushed to remote repository."
        fi
    fi
else
    print_error "Failed to commit changes."
    exit 1
fi