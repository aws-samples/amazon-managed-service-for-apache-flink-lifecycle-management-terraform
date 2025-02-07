#!/bin/bash

# Function to log messages
log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1"
}

# Check if an argument is provided
if [ $# -eq 0 ]; then
    log "No arguments provided. Please specify 'init', 'plan', 'apply' or 'destroy'"
    exit 1
fi

TERRAFORM_ACTION=$1

# Function to check if last command was successful
check_status() {
    if [ $? -ne 0 ]; then
        log "ERROR: $1"
        exit 1
    fi
}

# Get current directory
CURRENT_DIR=$(pwd)
log "Current directory: $CURRENT_DIR"

# Check if flink directory exists
if [ ! -d "$CURRENT_DIR/flink" ]; then
    log "ERROR: flink directory not found in $CURRENT_DIR"
    exit 1
fi

# Navigate to flink directory
cd "$CURRENT_DIR/flink"

# Clean and package with Maven
log "Starting Maven clean package..."
mvn clean package -DskipTests
check_status "Maven build failed"

# Find the generated JAR file
JAR_FILE=$(find target -name "*.jar" -not -name "*-sources.jar" -not -name "*-javadoc.jar" -not -name 'original*')
if [ -z "$JAR_FILE" ]; then
    log "ERROR: No JAR file found after build"
    exit 1
fi

# Generate timestamp
TIMESTAMP=$(date +'%Y%m%d_%H%M%S')

# Get original JAR filename
ORIGINAL_JAR_NAME=$(basename "$JAR_FILE")
BASE_NAME="${ORIGINAL_JAR_NAME%.jar}"
EXTENSION="${ORIGINAL_JAR_NAME##*.}"
echo $BASE_NAME
echo $EXTENSION
NEW_JAR_NAME="${BASE_NAME}_${TIMESTAMP}.${EXTENSION}"
echo $NEW_JAR_NAME
echo $(pwd)

# Copy and rename JAR to projects directory
cp "$JAR_FILE" "$CURRENT_DIR/$NEW_JAR_NAME"
check_status "Failed to copy JAR file"

log "Successfully created JAR file: $NEW_JAR_NAME"
log "JAR location: $CURRENT_DIR/$NEW_JAR_NAME"

# Return to original directory
cd "$CURRENT_DIR"

BUCKET_NAME=$(jq -r '.s3_bucket_name' terraform/config.tfvars.json)
FILE_TO_COPY_KEY=$NEW_JAR_NAME

if [[ -f "$FILE_TO_COPY_KEY" && "$FILE_TO_COPY_KEY" == *.jar ]]; then
  aws s3 cp "$FILE_TO_COPY_KEY" "s3://$BUCKET_NAME/flink-app/$FILE_TO_COPY_KEY"
  echo "File '$FILE_TO_COPY_KEY' copied to bucket '$BUCKET_NAME/flink-app/'."
else
  echo "File '$FILE_TO_COPY' does not exist or is not a .jar file."
fi

cd terraform

case $TERRAFORM_ACTION in
    "init")
        terraform init -backend-config=backend.conf
        ;;
    "plan")
        terraform init -backend-config=backend.conf
        terraform plan -out=plan -var-file=config.tfvars.json -var="s3_file_key=flink-app/$FILE_TO_COPY_KEY"
        ;;
    "apply")
        terraform init -backend-config=backend.conf
        terraform plan -out=plan -var-file=config.tfvars.json -var="s3_file_key=flink-app/$FILE_TO_COPY_KEY"
        terraform apply plan
        ;;
    "destroy")
        terraform init -backend-config=backend.conf
        terraform destroy -var-file=config.tfvars.json -var="s3_file_key=flink-app/$FILE_TO_COPY_KEY" -auto-approve
        ;;
    *)
        log "Invalid command provided. Available commands: init, plan, apply, destroy."
        ;;
esac

