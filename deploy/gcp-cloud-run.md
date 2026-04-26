# Deploy FastAPI (`main.py`) to GCP (Artifact Registry + Cloud Run)

Google recommends **Artifact Registry** (`REGION-docker.pkg.dev/...`). Legacy **GCR** (`gcr.io`) still works but is deprecated for new projects.

## One-time setup

```bash
# Set variables
export PROJECT_ID=your-gcp-project-id
export REGION=asia-southeast1          # e.g. Philippines-adjacent
export REPO=floote-api
export IMAGE=floote-routing

gcloud config set project $PROJECT_ID
gcloud services enable run.googleapis.com artifactregistry.googleapis.com cloudbuild.googleapis.com
gcloud artifacts repositories create $REPO --repository-format=docker --location=$REGION --description="Floote API"
gcloud auth configure-docker ${REGION}-docker.pkg.dev
```

## Build and push

From the repo root (where `Dockerfile` and `main.py` live):

```bash
export TAG=${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPO}/${IMAGE}:$(date +%Y%m%d-%H%M)
docker build -t $TAG .
docker push $TAG
```

## Deploy to Cloud Run

```bash
gcloud run deploy floote-routing \
  --image=$TAG \
  --region=$REGION \
  --platform=managed \
  --allow-unauthenticated \
  --memory=512Mi \
  --cpu=1 \
  --min-instances=0 \
  --max-instances=10 \
  --set-env-vars="SUPABASE_URL=https://YOUR.supabase.co,SUPABASE_ANON_KEY=your_anon_key"
```

Use **Secret Manager** for keys instead of plain `--set-env-vars` in production.

### Steady latency (optional, same API behavior)

Cold starts add seconds after idle. To reduce them (you pay for idle capacity):

- Set **`--min-instances=1`** (or higher under load). Example: add `--min-instances=1` to the deploy command above (and remove or override `--min-instances=0`).
- Keep **`--region`** close to your users (e.g. `asia-southeast1` for Philippines-adjacent traffic).
- If routing CPU is the bottleneck, try **`--cpu=2`** and/or **`--memory=1Gi`** on the same service; responses stay the same, only capacity changes.

The Docker image already sets **`PYTHONUNBUFFERED=1`** so container logs flush promptly (see `Dockerfile`).

## Flutter app0
0
0Point `ROUTING_API_URL` / your Dart `String.fromEnvironment('ROUTING_API_URL')` at the **Cloud Run HTTPS URL** (ends in `.run.app`).

## Optional: Cloud Build

Connect your Git repo so pushes build and deploy automatically; use a `cloudbuild.yaml` that runs `docker build` and `gcloud run deploy`.

---

## Step-by-step via Google Cloud Console (GUI)

Use this if you prefer the web UI. Open **[Google Cloud Console](https://console.cloud.google.com)** and select your **project** (top bar).

### 1. Enable billing (if not already)

1. **Billing** → link a billing account to the project (Cloud Run needs it).

### 2. Enable the APIs

1. **☰** (menu) → **APIs & Services** → **Library**.
2. Search and open each, then click **Enable**:
   - **Cloud Run API**
   - **Artifact Registry API**
   - (Optional) **Cloud Build API** — if you use Git-based deploys later.

### 3. Create an Artifact Registry repository (Docker)

1. **☰** → **Artifact Registry** (under “CI/CD” or search the top search bar).
2. Click **Create repository**.
3. **Name:** e.g. `floote-api`.
4. **Format:** **Docker**.
5. **Mode:** **Standard**.
6. **Location type:** **Region** — pick the same region you will use for Cloud Run (e.g. `asia-southeast1`).
7. Click **Create**.

You will push your image to:  
`REGION-docker.pkg.dev/PROJECT_ID/floote-api/IMAGE_NAME:TAG`  
(Replace with your region, project ID, and image name.)

### 4. Build the Docker image and push it

The console **cannot** upload a folder from your PC as a Docker image by itself. Use one of these:

**Option A — Cloud Shell (browser terminal, minimal CLI)**

1. Top bar → **Activate Cloud Shell** (terminal icon).
2. **Upload** your project (or clone from Git): **⋮** → Upload → zip of the folder containing `Dockerfile`, `main.py`, `requirements.txt`.
3. In Cloud Shell, `cd` into that folder and run the **Build and push** commands from the sections above (set `PROJECT_ID`, `REGION`, `REPO`, `IMAGE`, then `docker build` / `docker push`).  
   First time: **Artifact Registry** → your repo → **Setup instructions** → copy the `gcloud auth configure-docker` line for your region.

**Option B — Your own machine**

1. Install [Google Cloud SDK](https://cloud.google.com/sdk) and [Docker Desktop](https://www.docker.com/products/docker-desktop/).
2. Run `gcloud auth login`, `gcloud config set project PROJECT_ID`, and `gcloud auth configure-docker REGION-docker.pkg.dev`.
3. From the repo root (where `Dockerfile` is), run the **Build and push** commands in this doc.

make sure the gcloud is pointing to bin dir
docker build -t first . //to build the docker name/tag first
docker tag first asia-southeast1-docker.pkg.dev/floote-490402/floote-repository-api/first:v1
docker push asia-southeast1-docker.pkg.dev/floote-490402/floote-repository-api/first:v1

### 5. Deploy to Cloud Run (GUI)

1. **☰** → **Cloud Run**.
2. Click **Create service** (or **Deploy container**).
3. **Deploy one revision from** → select **Container image URL** (wording may be “Existing container image”).
4. Click **Select** / **Browse** and choose your image from **Artifact Registry**, **or** paste the full URL:  
   `REGION-docker.pkg.dev/PROJECT_ID/REPO_NAME/IMAGE_NAME:TAG`
5. **Region:** same region as the image (e.g. `asia-southeast1`).
6. **Service name:** e.g. `floote-routing`.
7. **Authentication:** for a public API, choose **Allow unauthenticated invocations** (or restrict later).
8. Expand **Container, Variables & Secrets, Connections, Security** (or **Container(s)**):
   - **Port:** `8080` (matches the `Dockerfile` / Cloud Run default).
   - **Environment variables:** add `SUPABASE_URL` and `SUPABASE_ANON_KEY` (values from Supabase). Prefer **Secret Manager** for production keys.
9. **CPU** / **Memory:** e.g. 1 CPU, 512 MiB to start; increase CPU/memory if traces show compute-bound routing.
10. **Minimum instances:** `0` for lowest cost (cold starts possible). Set **Minimum instances** to `1` if you want fewer cold starts (higher baseline cost).
11. Click **Create** (or **Deploy**).

Go to secret manager
Add principal
Give 666163632061-compute@developer.gserviceaccount.com Secret Manager Secret Accessor access both url and anon


### 6. Get the URL for your Flutter app

1. Open your **Cloud Run** service → copy the **URL** (HTTPS, often `*.run.app`).
https://floote-666163632061.asia-southeast1.run.app
2. Put that base URL + `/route` in your app’s routing config / `ROUTING_API_URL` as needed.

### 7. (Optional) Deploy from GitHub in the GUI

1. **Cloud Run** → **Create service** → look for **Continuously deploy from a repository** (or **Set up with Cloud Build**).
2. Connect **GitHub**, pick the repo and branch, set **Build type** to **Dockerfile** and path to your `Dockerfile`.
3. Finish the wizard; Cloud Build builds the image and Cloud Run deploys it on each push.

---

**Note:** Exact button names move slightly over time; use the top **Search** in the console (e.g. “Artifact Registry”, “Cloud Run”) if a label differs.

---

## Deploy using GitHub (yes)

You can connect **GitHub** so every push (or tags) **builds** your `Dockerfile` and **deploys** to Cloud Run. Two common patterns:

### A) Google Cloud Build + GitHub (stays inside GCP)

1. Push your code (including `Dockerfile`, `main.py`, `requirements.txt`) to a **GitHub** repo.
2. In **Google Cloud Console** → **Cloud Build** → **Triggers** → **Connect repository**.
3. Choose **GitHub**, authorize, select the repo and branch (e.g. `main`).
4. Create a **trigger**:
   - **Configuration:** Autodetected Dockerfile *or* use a `cloudbuild.yaml` that runs `docker build`, pushes to Artifact Registry, then `gcloud run deploy`.
5. Add a **service account** with permission to deploy to Cloud Run and push images (Cloud Build sets this up in the wizard or use default compute SA with roles).
6. On each push, Cloud Build runs in GCP and updates Cloud Run.

**Pros:** Secrets stay in GCP (Secret Manager), one vendor for CI/CD.  
**Cons:** Build minutes are billed; YAML can take a short learning curve.

### B) GitHub Actions (workflow in your repo)

1. In the repo → **Settings** → **Secrets and variables** → add GCP credentials:
   - Use **Workload Identity Federation** (recommended) or a **JSON key** for a service account that can push to Artifact Registry and deploy Cloud Run.
2. Add `.github/workflows/deploy-api.yml` that on `push` to `main`:
   - Authenticates to GCP (`google-github-actions/auth`).
   - `docker build` / `docker push` to Artifact Registry **or** `gcloud builds submit`.
   - `gcloud run deploy --image=...`.

**Pros:** Familiar to many teams; logs in GitHub Actions UI.  
**Cons:** You maintain the workflow YAML; protect secrets carefully.

### Repo layout reminder

Your **`Dockerfile`** is at the **repo root** next to `main.py`. If the API lives in a **subfolder** later, set the **Dockerfile path** in Cloud Build / Actions to that path.

### Same env vars

Whether you use Cloud Build or GitHub Actions, configure **`SUPABASE_URL`** and **`SUPABASE_ANON_KEY`** on the **Cloud Run** service (or map Secret Manager secrets in the deploy step). Do not commit real keys to GitHub.
