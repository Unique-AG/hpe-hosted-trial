#!/bin/bash

# Define the certificate file path and namespace
CERT_FILE="./public.sealed-secrets.cert.pem"
NAMESPACE="unique"

# Check if the certificate file exists
if [[ ! -f "$CERT_FILE" ]]; then
    echo "Error: Certificate file not found at $CERT_FILE"
    echo "Please ensure the certificate file is present in the current directory or update the CERT_FILE variable."
    exit 1
fi

# Find all .secret.yaml files and process them
find . -type f -name '*.secret.yaml' -print0 | while IFS= read -r -d $'\0' secret_file; do
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
             -f "$clean_secret_file" \
             -o yaml \
             -w "$output_file" \
             -n "$NAMESPACE"

    # Check if kubeseal command was successful
    if [[ $? -ne 0 ]]; then
        echo "Error: Failed to seal secret '$clean_secret_file'. Please check the output above."
        # Consider adding 'exit 1' here if you want the script to stop on the first error
    else
        echo "Successfully sealed '$clean_secret_file' to '$output_file'"
    fi
    echo "---"
done

echo "Finished processing all secret files."
