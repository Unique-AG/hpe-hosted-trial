#!/bin/bash

# Define the certificate file path and namespace
CERT_FILE="./public.sealed-secrets.cert.pem"
NAMESPACE="unique"

# Function to process a single secret file
process_secret() {
    local secret_file=$1
    
    # Construct the output file path by replacing the suffix
    # Remove the leading './' if present for cleaner output path
    clean_secret_file="${secret_file#./}"
    output_file="${clean_secret_file%.secret.yaml}.sealed-secret.yaml"

    echo "Processing '$clean_secret_file'..."

    # Create parent directory for output file if it doesn't exist
    output_dir=$(dirname "$output_file")
    mkdir -p "$output_dir"

    # Run kubeseal command
    kubeseal --cert "$CERT_FILE" \
             -f "$secret_file" \
             -o yaml \
             -w "$output_file" \
             -n "$NAMESPACE"

    # Check if kubeseal command was successful
    if [[ $? -ne 0 ]]; then
        echo "Error: Failed to seal secret '$clean_secret_file'. Please check the output above."
        return 1
    else
        echo "Successfully sealed '$clean_secret_file' to '$output_file'"
    fi
    echo "---"
    return 0
}

# Check if the certificate file exists
if [[ ! -f "$CERT_FILE" ]]; then
    echo "Error: Certificate file not found at $CERT_FILE"
    echo "Please ensure the certificate file is present in the current directory or update the CERT_FILE variable."
    exit 1
fi

# Check for --all flag or specific secret name
if [[ "$1" == "--all" ]]; then
    # Process all secrets (original behavior)
    echo "Processing all secret files..."
    find . -type f -name '*.secret.yaml' -print0 | while IFS= read -r -d $'\0' secret_file; do
        process_secret "$secret_file"
    done
    echo "Finished processing all secret files."
elif [[ -n "$1" ]]; then
    # Process a specific secret
    # Look for the secret file with pattern *$1*.secret.yaml
    secret_files=($(find . -type f -name "*$1*.secret.yaml"))
    
    if [[ ${#secret_files[@]} -eq 0 ]]; then
        echo "Error: No secret file found matching pattern '*$1*.secret.yaml'"
        exit 1
    fi
    
    if [[ ${#secret_files[@]} -gt 1 ]]; then
        echo "Found multiple matching secrets:"
        for file in "${secret_files[@]}"; do
            echo "  ${file#./}"
        done
        echo "Please specify a more precise name."
        exit 1
    fi
    
    process_secret "${secret_files[0]}"
else
    # No arguments provided
    echo "Usage: $0 [--all | secret-name]"
    echo "  --all        Process all secret files"
    echo "  secret-name  Process only the specified secret"
    exit 1
fi
