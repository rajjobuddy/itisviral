PROMPT="A serene, ultra-realistic natural landscape featuring a crystal-clear stream winding through a vibrant, lush green forest. Sunlight filters softly through the dense canopy, casting dappled patterns of light and shadow on the mossy ground. Birds of various colors are perched on graceful branches, some mid-song, adding life to the tranquil scene. The air is fresh and filled with the subtle sounds of nature, creating a peaceful and harmonious atmosphere."

PROJECT_ID="gothic-envelope-458808-h6"
LOCATION_ID="us-central1"
API_ENDPOINT="us-central1-aiplatform.googleapis.com"
MODEL_ID="veo-3.0-generate-preview"
STORAGE_URI="gs://helloranjan1/output/"
AUDIO_FILE=`ls *.mp3| shuf | head -n 1`
LOCAL_DIR="./videos"

# Check for required tools
if ! command -v gsutil &> /dev/null; then
  echo "Error: gsutil is not installed. Please install Google Cloud SDK."
  exit 1
fi
if ! command -v jq &> /dev/null; then
  echo "Warning: jq is not installed. Falling back to grep for parsing."
  USE_JQ=false
else
  USE_JQ=true
fi

cat <<EOF > request.json
{
  "endpoint": "projects/${PROJECT_ID}/locations/${LOCATION_ID}/publishers/google/models/${MODEL_ID}",
  "instances": [
    {
      "prompt": "${{ github.event.inputs.prompt }}"
    }
  ],
  "parameters": {
    "aspectRatio": "16:9",
    "sampleCount": 1,
    "durationSeconds": "8",
    "personGeneration": "allow_adult",
    "addWatermark": true,
    "includeRaiReason": true,
    "storageUri": "${STORAGE_URI}",
    "generateAudio": true
  }
}
EOF

# Start video generation and get operation ID
echo "Initiating video generation with Veo 3.0..."
OPERATION_ID=$(curl -s \
  -X POST \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $(gcloud auth print-access-token)" \
  "https://${API_ENDPOINT}/v1/projects/${PROJECT_ID}/locations/${LOCATION_ID}/publishers/google/models/${MODEL_ID}:predictLongRunning" \
  -d '@request.json' | sed -n 's/.*"name": "\(.*\)".*/\1/p')

if [ -z "$OPERATION_ID" ]; then
  echo "Error: Failed to get OPERATION_ID. Check authentication or API access."
  rm -f request.json
  exit 1
fi

echo "OPERATION_ID: ${OPERATION_ID}"

# Poll for operation completion
echo "Waiting for video generation to complete..."
MAX_ATTEMPTS=30
ATTEMPT=1
while [ $ATTEMPT -le $MAX_ATTEMPTS ]; do
  cat << EOF > fetch.json
  {
    "operationName": "${OPERATION_ID}"
  }
EOF


  RESPONSE=$(curl -s \
    -X POST \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $(gcloud auth print-access-token)" \
    "https://${API_ENDPOINT}/v1/projects/${PROJECT_ID}/locations/${LOCATION_ID}/publishers/google/models/${MODEL_ID}:fetchPredictOperation" \
    -d '@fetch.json')

  
  DONE=$(echo "$RESPONSE" | grep -o '"done": true')
  if [ -n "$DONE" ]; then
    echo "Video generation completed!"
    break
  fi
  echo "Operation in progress, attempt $ATTEMPT/$MAX_ATTEMPTS, waiting 10 seconds..."
  sleep 10
  ATTEMPT=$((ATTEMPT + 1))
  if [ $ATTEMPT -gt $MAX_ATTEMPTS ]; then
    echo "Error: Operation timed out after $MAX_ATTEMPTS attempts"
    rm -f request.json fetch.json
    exit 1
  fi
done  

# Extract video URI from response
if [ "$USE_JQ" = true ]; then
  VIDEO_URI=$(echo "$RESPONSE" | jq -r '.response.videos[].gcsUri' 2>/dev/null | head -n 1)
else
  VIDEO_URI=$(echo "$RESPONSE" | grep -o '"gcsUri": "[^"]*"' | sed 's/"gcsUri": "\([^"]*\)"/\1/' | grep '\.mp4$' | head -n 1)
fi

if [ -z "$VIDEO_URI" ]; then
  echo "Error: No video URI found in response"
  echo "Response: $RESPONSE"
  rm -f request.json fetch.json
  exit 1
fi

echo "Downloading video, adding music, and storing locally..."
FILENAME=$(basename "$VIDEO_URI")
OUTPUT_FILENAME="${LOCAL_DIR}/${PROMPT}.mp4"
echo "Downloading $VIDEO_URI to ${LOCAL_DIR}/${FILENAME}"
gsutil cp "$VIDEO_URI" "${LOCAL_DIR}/${FILENAME}"
if [ $? -eq 0 ]; then
  echo "Successfully downloaded $FILENAME"
  echo "Adding music from $AUDIO_FILE to $FILENAME..."
  ffmpeg -i "${LOCAL_DIR}/${FILENAME}" -i "$AUDIO_FILE" -c:v copy -c:a aac -map 0:v:0 -map 1:a:0 -shortest -y "$OUTPUT_FILENAME"
  if [ $? -eq 0 ]; then
    echo "Successfully created $OUTPUT_FILENAME with music"
    echo "Note: If required, attribute the music in your project (e.g., 'Music: Cartoon Battle by Doug Maxwell from YouTube Audio Library')"
    rm -f "${LOCAL_DIR}/${FILENAME}" # Remove original video without music
    # Delete video from bucket
    echo "Deleting $VIDEO_URI from bucket..."
    #gsutil rm "$VIDEO_URI"
    if [ $? -eq 0 ]; then
      echo "Successfully deleted $VIDEO_URI from bucket"
    else
      echo "Error deleting $VIDEO_URI from bucket"
    fi
  else
    echo "Error adding music to $FILENAME"
  fi
else
  echo "Error downloading $VIDEO_URI"
fi

# Clean up temporary files
rm -f request.json fetch.json

echo "Done! Animated video with YouTube Audio Library music is saved locally in $OUTPUT_FILENAME."
echo "No video remains in the bucket."


