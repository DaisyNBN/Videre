# Google Credentials Setup Guide

This backend uses two Google integrations:

- Cloud Vision API for primary image analysis
- Gemini API for navigation text and image-analysis fallback

## 1. Prerequisites

- A Google Cloud project with billing enabled
- Access to the Google Cloud CLI (`gcloud`)
- A Gemini API key

Set your project id once for commands below:

```bash
export PROJECT_ID="your-gcp-project-id"
```

Enable required APIs:

```bash
gcloud services enable vision.googleapis.com generativelanguage.googleapis.com --project "$PROJECT_ID"
```

## 2. Recommended for Local Dev (ADC)

This is the simplest and safest local setup.

```bash
gcloud auth login
gcloud config set project "$PROJECT_ID"
gcloud auth application-default login

export GOOGLE_CLOUD_PROJECT="$PROJECT_ID"
export GEMINI_API_KEY="your-gemini-api-key"
```

Verify ADC is available:

```bash
test -f "$HOME/.config/gcloud/application_default_credentials.json" && echo "ADC file present"
gcloud auth application-default print-access-token >/dev/null && echo "ADC token OK"
```

## 3. Service Account Option (CI/Server)

Use this for non-interactive environments.

Create a service account:

```bash
gcloud iam service-accounts create videre-vision --project "$PROJECT_ID"
```

Grant minimum Vision access (project-level):

```bash
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:videre-vision@$PROJECT_ID.iam.gserviceaccount.com" \
  --role="roles/visionai.user"
```

Create key file:

```bash
mkdir -p "$HOME/.config/videre"
gcloud iam service-accounts keys create "$HOME/.config/videre/vision-sa.json" \
  --iam-account="videre-vision@$PROJECT_ID.iam.gserviceaccount.com"
chmod 600 "$HOME/.config/videre/vision-sa.json"
```

Export runtime variables:

```bash
export GOOGLE_APPLICATION_CREDENTIALS="$HOME/.config/videre/vision-sa.json"
export GOOGLE_CLOUD_PROJECT="$PROJECT_ID"
export GEMINI_API_KEY="your-gemini-api-key"
```

## 4. Start Backend

```bash
cd /home/asura/Videre/backend
npm run dev
```

## 5. Validate End-to-End

Health check:

```bash
curl -sS http://localhost:5516/api/health
```

Expected log behavior during scan analysis:

- Good: `Triggering AI analysis for keyframe ...`
- Good: No repeated `Could not load the default credentials` errors
- Good: No process crash on scan analysis

## 6. Troubleshooting

- `Could not load the default credentials`
  - Run `gcloud auth application-default login`, or set `GOOGLE_APPLICATION_CREDENTIALS` to a valid absolute path.

- `MetadataLookupWarning`
  - Common when local machine has no metadata identity. Use ADC or service-account credentials.

- Gemini `400 Unable to process input image`
  - Input frame is not valid image bytes/base64. Ensure keyframes are valid JPEG/PNG payloads.

- Gemini `429 Too Many Requests` / `Quota exceeded`
  - Free-tier Gemini quota has been exhausted for the current window.
  - Backend now auto-pauses Gemini fallback briefly based on retry delay and uses non-Gemini fallback during cooldown.
  - To restore full fallback quality: enable billing/upgrade quota, reduce request volume, or wait for quota reset.

## 7. Security Notes

- Do not commit credential files.
- Rotate service-account keys regularly.
- Prefer ADC locally and managed identity in production where available.
