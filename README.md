# AWS Academy Lab Scripts

Bash scripts that automate the CLI/SDK tasks for each AWS Academy lab (CUR-TF-200-ACCDEV-2-91558).

---

## Running with Docker (recommended on Mac, Linux, or Windows)

Use Docker for a consistent environment — avoids platform differences with `sed`, `grep`, and Python paths across Mac, Linux, and Windows (Git Bash).

### Prerequisites

- [Docker Desktop](https://www.docker.com/products/docker-desktop/) (Mac, Linux, or Windows)
- A `.env` file with your AWS credentials (see [Setup](#setup-required-before-every-lab) below)

### Run a lab

**PowerShell (Windows):**
```powershell
# First run — builds the image automatically, then runs the script
.\run_lab.ps1 lab5_1.sh

# Force a rebuild (e.g. after pulling new script changes)
.\run_lab.ps1 lab5_1.sh -Build
```

If PowerShell blocks the script, run this once first:
```powershell
Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
```

**Git Bash / Mac / Linux:**
```bash
# First run — builds the image automatically, then runs the script
./run_lab.sh lab5_1.sh

# Force a rebuild (e.g. after pulling new script changes)
./run_lab.sh lab5_1.sh --build
```

The image is built once and reused for subsequent runs. Any files downloaded during the lab (e.g. `code.zip`) are written to your local folder via a bind mount.

---

## Running without Docker (Windows Git Bash only)

### Prerequisites

**1. Git Bash**  
Download and install from https://git-scm.com/downloads  
All scripts must be run inside **Git Bash**, not PowerShell or CMD.

**2. AWS CLI v2**  
Download and install from https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html  
If Git Bash can't find `aws` after installing, add it to your PATH:
```bash
export PATH=$PATH:"/c/Program Files/Amazon/AWSCLIV2"
```
To make this permanent, add that line to your `~/.bashrc`.  
Verify: `aws --version`

**3. Python 3**  
Download and install from https://www.python.org/downloads/  
Check **"Add Python to PATH"** during install.  
Verify: `python3 --version`

**4. pip / boto3**  
boto3 is installed automatically by each script. To install manually:
```bash
pip3 install boto3
```

**5. curl and unzip**  
Included with Git Bash. Verify: `curl --version` and `unzip -v`

### Run a lab

```bash
bash lab5_1.sh
```

---

## Setup (required before every lab)

### 1. Get fresh AWS credentials

Each AWS Academy lab session gives you temporary credentials that expire when the session ends.

1. In the lab console click **Details → Show**
2. Copy the three credential values

### 2. Create or update `.env`

Copy `.env.example` and fill in your credentials:

```
AWS_ACCESS_KEY_ID=ASIA...
AWS_SECRET_ACCESS_KEY=...
AWS_SESSION_TOKEN=...
AWS_DEFAULT_REGION=us-east-1
```

> **Important:** Credentials expire when the lab session ends. Update `.env` every time you start a new lab session.

The `.env` file is loaded automatically by every script via `common.sh`.

---

## Lab Scripts

| Script | Lab | What it does |
|--------|-----|--------------|
| `lab2_1.sh` | Lab 2.1 | Exploring AWS CloudShell and IDE |
| `lab3_1.sh` | Lab 3.1 | S3 bucket, bucket policy, static website upload |
| `lab5_1.sh` | Lab 5.1 | DynamoDB table, batch load, GSI, queries |
| `lab6_1.sh` | Lab 6.1 | API Gateway REST API with mock integrations |
| `lab7_1.sh` | Lab 7.1 | Lambda functions, API Gateway Lambda integration |

Each script is idempotent — safe to re-run if it fails partway through.

---

## Troubleshooting

**"AWS credentials are expired or invalid"**  
Update `.env` with fresh credentials from the lab Details panel.

**"Cannot find LabIDE instance"** (Lab 8)  
Make sure the lab environment is fully started (all EC2 instances show as running in the EC2 console).

**Script fails partway through**  
Re-run it — all scripts check for existing resources and skip steps already done.

**Labs are independent**  
Each AWS Academy lab starts a fresh environment. Resources from previous labs (S3 buckets, DynamoDB tables, etc.) do not carry over. Scripts handle this automatically.
