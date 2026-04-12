# DAMOps — Domain Access Management Toolkit

AI-powered access management automation for Microsoft Entra ID 
and Active Directory environments. Built for IAM analysts, 
IT administrators, and security operations teams.

## What It Does

DAMOps automates the daily operational work of a Domain Access 
Management team:

- Access Audit Dashboard — stale accounts, guest accounts, 
  privileged role holders, risk scoring (HIGH/MEDIUM/LOW)
- AI Chat — ask plain-English questions about your audit data, 
  powered by NVIDIA NIM (LLaMA 3.3 70B)
- PS Helper — AI-generated PowerShell scripts tailored to your 
  role and environment, PowerShell command reference, 
  Python snippet generator
- Report Generation — audit-ready HTML and CSV reports, 
  AI risk summaries in plain English
- JML Automation — Joiner/Mover/Leaver processing from CSV input
- Role-Based Script Access — DAMAnalyst, ITAdmin, SecurityOps, 
  HelpDesk roles enforce what each user can generate and execute

## Tech Stack

| Layer | Technology |
|---|---|
| Runtime | Node.js / Express.js |
| Logic | Vanilla JavaScript & HTML/CSS templates |
| Modules | PowerShell 7+ |
| AI Engine | NVIDIA NIM — meta/llama-3.3-70b-instruct |
| APIs | Native JS fetch (no external SDKs required) |

## Getting Started

### Prerequisites
- Node.js 18+
- PowerShell 7+
- NVIDIA NIM API key — get one at integrate.api.nvidia.com

### Installation

```bash
git clone https://github.com/YOUR_USERNAME/damops-toolkit
cd damops-toolkit
npm install
cp .env.example .env.local
```

Edit the environment variables (or rely on your shell profile) and add your NVIDIA API key:
`NVIDIA_API_KEY=your_key_here`

```bash
npm run start
```

Open `http://localhost:3000`

## Project Structure

```text
damops-toolkit/
├── server.js            # Express API server & dashboard generator
├── Modules/             # Comprehensive PowerShell functions
│   ├── Connect.ps1
│   ├── AccessAudit.ps1
│   └── ...
├── Templates/           # HTML templates for reports
├── Data/                # PS command reference data
└── Logs/                # Auto-generated runtime logs
```

## AI Integration

All AI calls are server-side only via Express API routes protecting your key.
The NVIDIA NIM API is integrated directly under `callNvidiaAPI()`:

Model: `meta/llama-3.3-70b-instruct`
Temperature: `0.2` (deterministic, appropriate for technical generation)

## PS Helper — Role Access

| Role | Can Generate | Blocked |
|---|---|---|
| DAMAnalyst | Read, export, report scripts | Set/New/Remove/Disable |
| ITAdmin | All scripts | Nothing |
| SecurityOps | Priv role + anomaly scripts | JML, account changes |
| HelpDesk | Input validation only | All execution scripts |

## Security Notes

- Never commit `.env` or `.env.local`
- All AI calls are server-side — API key never exposed to browser
- Demo data uses fictional tenant: `contoso.onmicrosoft.com`
- Always test generated scripts with `-DryRun` before production use

## Demo

The dashboard loads with sample data for `contoso.onmicrosoft.com`.
To connect to a real tenant, execute the PowerShell module:
`Connect-DAMOps -Tenant yourtenant.onmicrosoft.com`

## License

MIT
