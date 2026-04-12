/**
 * DAMOps Web Server — Express.js dashboard with AI chatbot
 * 
 * Serves audit reports, provides live AI chat via NVIDIA NIM,
 * and auto-refreshes when new reports are generated.
 * 
 * Usage: node server.js
 * URL:   http://localhost:3000
 */

const express = require('express');
const fs = require('fs');
const path = require('path');
const https = require('https');

const app = express();
const PORT = 3000;

// ── Config ──────────────────────────────────────────────────────────────────
const NVIDIA_API_KEY = process.env.NVIDIA_API_KEY || 'YOUR_NVIDIA_API_KEY_HERE';
const NVIDIA_MODEL = 'meta/llama-3.3-70b-instruct';
const NVIDIA_URL = 'https://integrate.api.nvidia.com/v1/chat/completions';
const OUTPUT_DIR = path.join(__dirname, 'Output');
const TEMPLATES_DIR = path.join(__dirname, 'Templates');
const DATA_DIR = path.join(__dirname, 'Data');

app.use(express.json({ limit: '10mb' }));
app.use(express.static(OUTPUT_DIR));

// ── Load audit data for context ─────────────────────────────────────────────
function loadAuditCSV() {
    const csvPath = path.join(OUTPUT_DIR, 'audit_report.csv');
    if (!fs.existsSync(csvPath)) return null;

    const raw = fs.readFileSync(csvPath, 'utf8');
    const lines = raw.trim().split('\n');
    if (lines.length < 2) return null;

    const headers = lines[0].split(',').map(h => h.trim().replace(/^"|"$/g, ''));
    const rows = [];

    for (let i = 1; i < lines.length; i++) {
        // Simple CSV parse (handles quoted fields)
        const values = [];
        let current = '';
        let inQuotes = false;
        for (const char of lines[i]) {
            if (char === '"') { inQuotes = !inQuotes; continue; }
            if (char === ',' && !inQuotes) { values.push(current.trim()); current = ''; continue; }
            current += char;
        }
        values.push(current.trim());

        const row = {};
        headers.forEach((h, idx) => { row[h] = values[idx] || ''; });
        rows.push(row);
    }

    return rows;
}

// ── NVIDIA NIM API call ─────────────────────────────────────────────────────
function callNvidiaAPI(messages, maxTokens = 1024, temperature = 0.4) {
    return new Promise((resolve, reject) => {
        const body = JSON.stringify({
            model: NVIDIA_MODEL,
            messages: messages,
            max_tokens: maxTokens,
            temperature: temperature,
            top_p: 0.9
        });

        const url = new URL(NVIDIA_URL);
        const options = {
            hostname: url.hostname,
            path: url.pathname,
            method: 'POST',
            headers: {
                'Authorization': `Bearer ${NVIDIA_API_KEY}`,
                'Content-Type': 'application/json',
                'Content-Length': Buffer.byteLength(body)
            }
        };

        const req = https.request(options, (res) => {
            let data = '';
            res.on('data', chunk => data += chunk);
            res.on('end', () => {
                try {
                    const parsed = JSON.parse(data);
                    if (parsed.choices && parsed.choices[0]) {
                        resolve(parsed.choices[0].message.content);
                    } else if (parsed.error) {
                        reject(new Error(parsed.error.message || 'API error'));
                    } else {
                        reject(new Error('Unexpected response format'));
                    }
                } catch (e) {
                    reject(new Error(`Parse error: ${e.message}`));
                }
            });
        });

        req.on('error', reject);
        req.setTimeout(60000, () => { req.destroy(); reject(new Error('Request timeout')); });
        req.write(body);
        req.end();
    });
}

// ── API: Chat endpoint ──────────────────────────────────────────────────────
app.post('/api/chat', async (req, res) => {
    try {
        const { message, history = [] } = req.body;

        if (!message) return res.status(400).json({ error: 'Message required' });

        // Load current audit data for context
        const auditData = loadAuditCSV();
        const auditContext = auditData
            ? JSON.stringify(auditData.map(r => ({
                Name: r.DisplayName, Dept: r.Department, LastSignIn: r.LastSignIn,
                DaysStale: r.DaysSinceSignIn, Privileged: r.IsPrivileged,
                Roles: r.PrivilegedRoles, Risk: r.RiskFlag
            })))
            : 'No audit data loaded.';

        const totalCount = auditData ? auditData.length : 0;
        const highCount = auditData ? auditData.filter(r => r.RiskFlag === 'HIGH').length : 0;
        const medCount = auditData ? auditData.filter(r => r.RiskFlag === 'MEDIUM').length : 0;
        const privCount = auditData ? auditData.filter(r => r.IsPrivileged === 'True').length : 0;

        const systemPrompt = `You are the DAMOps AI Assistant — an expert in Identity and Access Management for Microsoft Entra ID.
You have access to the current access audit data for the tenant.

CURRENT AUDIT CONTEXT:
- Total accounts audited: ${totalCount}
- HIGH risk: ${highCount}
- MEDIUM risk: ${medCount}
- Privileged accounts: ${privCount}

AUDIT DATA:
${auditContext}

INSTRUCTIONS:
1. Answer questions about the audit data clearly and specifically
2. Reference specific users by name when relevant
3. Explain risks in plain English a manager can understand
4. Provide actionable recommendations with timelines
5. Keep responses concise but thorough (max 300 words)
6. Format with markdown: use **bold**, bullet points, and headers
7. If asked about something not in the data, say so honestly
8. Never fabricate user data — only reference what's in the audit`;

        const messages = [
            { role: 'system', content: systemPrompt },
            ...history.slice(-6), // Keep last 6 messages for context
            { role: 'user', content: message }
        ];

        const reply = await callNvidiaAPI(messages, 800);
        res.json({ reply, model: NVIDIA_MODEL });

    } catch (err) {
        console.error('Chat error:', err.message);
        res.status(500).json({
            reply: `⚠️ AI is temporarily unavailable: ${err.message}\n\nYou can still view the audit reports and data in the dashboard.`,
            error: true
        });
    }
});

// ── API: Get audit summary ──────────────────────────────────────────────────
app.get('/api/audit-summary', (req, res) => {
    const data = loadAuditCSV();
    if (!data) return res.json({ loaded: false });

    res.json({
        loaded: true,
        total: data.length,
        high: data.filter(r => r.RiskFlag === 'HIGH').length,
        medium: data.filter(r => r.RiskFlag === 'MEDIUM').length,
        low: data.filter(r => r.RiskFlag === 'LOW').length,
        info: data.filter(r => r.RiskFlag === 'INFO').length,
        guests: data.filter(r => r.UserType === 'Guest').length,
        privileged: data.filter(r => r.IsPrivileged === 'True').length,
        data: data
    });
});

// ── API: List available reports ─────────────────────────────────────────────
app.get('/api/reports', (req, res) => {
    if (!fs.existsSync(OUTPUT_DIR)) return res.json([]);

    const files = fs.readdirSync(OUTPUT_DIR)
        .filter(f => f.endsWith('.html') || f.endsWith('.csv') || f.endsWith('.md'))
        .map(f => ({
            name: f,
            type: path.extname(f).slice(1),
            size: fs.statSync(path.join(OUTPUT_DIR, f)).size,
            modified: fs.statSync(path.join(OUTPUT_DIR, f)).mtime
        }))
        .sort((a, b) => new Date(b.modified) - new Date(a.modified));

    res.json(files);
});

// ── API: Get AI risk summary markdown ───────────────────────────────────────
app.get('/api/ai-summary', (req, res) => {
    const mdPath = path.join(OUTPUT_DIR, 'ai_risk_summary.md');
    if (!fs.existsSync(mdPath)) return res.json({ content: null });

    const content = fs.readFileSync(mdPath, 'utf8');
    res.json({ content });
});

// ── API: AI Script Generator ────────────────────────────────────────────────
app.post('/api/ps-helper/generate', async (req, res) => {
    try {
        const { task, role, environment, outputFormat, dryRun, ticketRef } = req.body;
        
        const systemPrompt = `You are a Senior PowerShell Engineer specializing in Microsoft Identity and Access Management. You write production-quality, well-commented PowerShell scripts for enterprise AD and Entra ID environments. Every script you write must include:
1. Comment-based help block (Synopsis, Description, Parameters, Example)
2. A -DryRun switch that previews actions without executing them
3. Structured logging: timestamp, action, result, UPN, ticket reference
4. Error handling with try/catch and descriptive messages
5. Role-based access guards — enforce what each role can and cannot do:
   DAMAnalyst: read-only (Get-Mg*, Export-Csv, reports only, no Set/New/Remove)
   ITAdmin: full access including disable, move OU, group changes
   SecurityOps: privileged role monitoring and anomaly detection only
   HelpDesk: input validation only, no execution of destructive actions
6. Return PSCustomObjects, never raw strings

Output must be ONLY the raw .ps1 script content block. NO markdown fences or explanations.`;

        const userPrompt = `Generate a PowerShell script for the following:
Task: ${task}
Role: ${role}
Environment: ${environment}
Output format: ${outputFormat}
DryRun default: ${dryRun ? 'on' : 'off'}
Ticket ref field: ${ticketRef || 'none'}`;

        const messages = [
            { role: 'system', content: systemPrompt },
            { role: 'user', content: userPrompt }
        ];

        // Process request
        const rawReply = await callNvidiaAPI(messages, 2500, 0.2);
        console.log("NVIDIA RAW:", rawReply);
        
        const parsed = {
            script: rawReply.replace(/```(powershell|ps1)?\n?/gi, '').replace(/```$/gi, '').trim(),
            filename: "DAMOps-Generated.ps1",
            description: "AI generated script",
            requiredModules: ["Microsoft.Graph"],
            estimatedRuntime: "< 1 minute"
        };
        
        // Log to file
        const logDir = path.join(__dirname, 'Logs');
        if(!fs.existsSync(logDir)) fs.mkdirSync(logDir);
        const logEntry = `[${new Date().toISOString()}] GenScript | Role:${role} | Env:${environment} | File:${parsed.filename}\n`;
        fs.appendFileSync(path.join(logDir, 'ps-helper.log'), logEntry);

        res.json(parsed);
    } catch(e) {
        console.error('Generate Script Error:', e.message);
        res.status(500).json({ error: e.message });
    }
});

// ── API: Python Helper ──────────────────────────────────────────────────────
app.post('/api/ps-helper/python', async (req, res) => {
    try {
        const { task, usecase, libraries, outputType } = req.body;
        
        const systemPrompt = `You are a Senior Python developer specializing in IT automation, data processing, and API integrations for enterprise environments. Write clean, well-commented Python 3 scripts. Every script must:
1. Include a docstring explaining what it does, inputs, and outputs
2. Use only the libraries specified by the user
3. Include error handling with try/except
4. Be immediately runnable — no placeholders, use realistic example values
5. Add a if __name__ == '__main__': block

Output must be ONLY a raw JSON object matching EXACTLY this shape:
{
  "script": "<raw Python code only>",
  "filename": "descriptive_name.py",
  "description": "Short description",
  "libraries": ["lib1"],
  "pythonVersion": "3.10+"
}
NO markdown fences or explanations outside the JSON object.`;

        const userPrompt = `Generate a Python script for the following:
Task: ${task}
Use case: ${usecase}
Allowed Libraries: ${libraries}
Output type: ${outputType}`;

        const messages = [
            { role: 'system', content: systemPrompt },
            { role: 'user', content: userPrompt }
        ];

        const rawReply = await callNvidiaAPI(messages, 2500, 0.2);
        
        let parsed;
        try {
            const match = rawReply.match(/\{[\s\S]*\}/);
            parsed = JSON.parse(match ? match[0] : rawReply);
        } catch(e) { throw new Error("Failed to parse AI response as JSON"); }

        res.json(parsed);
    } catch(e) {
        console.error('Python Generate Error:', e.message);
        res.status(500).json({ error: e.message });
    }
});

// ── API: Explain Script/Command ─────────────────────────────────────────────
app.post('/api/ps-helper/explain', async (req, res) => {
    try {
        const { code } = req.body;
        
        const systemPrompt = `You are an expert IT instructor. Explain the following IT script or command in plain English so a junior admin can understand. Include:
1. What the code does in general terms
2. When to use it
3. Common mistakes to avoid
4. A realistic enterprise context example

Output must be ONLY a raw JSON object matching EXACTLY this shape:
{
  "explanation": "<html>...formatted plain-English html payload...</html>"
}
NO markdown fences or explanations outside the JSON object. Use HTML tags (<b>, <ul>, <p>, <code>) for formatting.`;

        const messages = [
            { role: 'system', content: systemPrompt },
            { role: 'user', content: code }
        ];

        const rawReply = await callNvidiaAPI(messages, 1024, 0.4);
        
        let parsed;
        try {
            const match = rawReply.match(/\{[\s\S]*\}/);
            parsed = JSON.parse(match ? match[0] : rawReply);
        } catch(e) { throw new Error("Failed to parse AI response as JSON"); }

        res.json(parsed);
    } catch(e) {
        console.error('Explain Error:', e.message);
        res.status(500).json({ error: e.message });
    }
});

// ── API: Get PS Commands ────────────────────────────────────────────────────
app.get('/api/ps-helper/commands', (req, res) => {
    const jsonPath = path.join(DATA_DIR, 'ps-commands.json');
    if (!fs.existsSync(jsonPath)) return res.json([]);
    try {
        const raw = fs.readFileSync(jsonPath, 'utf8');
        res.json(JSON.parse(raw));
    } catch(e) {
        res.status(500).json({ error: 'Failed to read commands' });
    }
});

// ── Main dashboard page ─────────────────────────────────────────────────────
app.get('/', (req, res) => {
    res.send(getDashboardHTML());
});

// ── PS Helper page ────────────────────────────────────────────────────────
app.get('/ps-helper', (req, res) => {
    res.send(getPSHelperHTML());
});

// ── Dashboard HTML ──────────────────────────────────────────────────────────
function getDashboardHTML() {
    return `<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>DAMOps — Domain Access Management Dashboard</title>
    <link href="https://fonts.googleapis.com/css2?family=Inter:wght@300;400;500;600;700&display=swap" rel="stylesheet">
    <style>
        /* ── Reset & Variables ──────────────────────────────────── */
        * { margin: 0; padding: 0; box-sizing: border-box; }
        :root {
            --bg-primary: #0a0e17;
            --bg-secondary: #111827;
            --bg-card: #1a1f35;
            --bg-chat: #0d1220;
            --border: #1e293b;
            --text-primary: #e2e8f0;
            --text-secondary: #94a3b8;
            --text-muted: #64748b;
            --accent: #3b82f6;
            --accent-glow: rgba(59, 130, 246, 0.15);
            --high: #ef4444;
            --medium: #f59e0b;
            --low: #3b82f6;
            --info: #64748b;
            --success: #10b981;
            --font: 'Inter', -apple-system, BlinkMacSystemFont, sans-serif;
        }

        body {
            font-family: var(--font);
            background: var(--bg-primary);
            color: var(--text-primary);
            min-height: 100vh;
            overflow-x: hidden;
        }

        /* ── Animated background ───────────────────────────────── */
        body::before {
            content: '';
            position: fixed; top: 0; left: 0; right: 0; bottom: 0;
            background: 
                radial-gradient(ellipse at 20% 50%, rgba(59,130,246,0.06) 0%, transparent 60%),
                radial-gradient(ellipse at 80% 20%, rgba(139,92,246,0.04) 0%, transparent 60%),
                radial-gradient(ellipse at 50% 80%, rgba(16,185,129,0.03) 0%, transparent 60%);
            pointer-events: none; z-index: 0;
        }

        /* ── Layout ────────────────────────────────────────────── */
        .app { position: relative; z-index: 1; display: flex; height: 100vh; }

        /* ── Sidebar ───────────────────────────────────────────── */
        .sidebar {
            width: 280px; min-width: 280px;
            background: var(--bg-secondary);
            border-right: 1px solid var(--border);
            display: flex; flex-direction: column;
            padding: 1.5rem 1rem;
        }
        .logo {
            display: flex; align-items: center; gap: 0.75rem;
            padding: 0 0.5rem 1.5rem 0.5rem;
            border-bottom: 1px solid var(--border);
            margin-bottom: 1.5rem;
        }
        .logo-icon {
            width: 36px; height: 36px;
            background: linear-gradient(135deg, var(--accent), #8b5cf6);
            border-radius: 10px;
            display: flex; align-items: center; justify-content: center;
            font-weight: 700; font-size: 0.85rem; color: #fff;
        }
        .logo h1 { font-size: 1.1rem; font-weight: 700; letter-spacing: 0.05em; }
        .logo span { font-size: 0.7rem; color: var(--text-muted); display: block; }

        .nav-section { margin-bottom: 1.5rem; }
        .nav-label {
            font-size: 0.65rem; font-weight: 600; text-transform: uppercase;
            letter-spacing: 0.1em; color: var(--text-muted); padding: 0 0.5rem;
            margin-bottom: 0.5rem;
        }
        .nav-item {
            display: flex; align-items: center; gap: 0.6rem;
            padding: 0.6rem 0.75rem; border-radius: 8px;
            cursor: pointer; transition: all 0.2s; font-size: 0.85rem;
            color: var(--text-secondary);
        }
        .nav-item:hover { background: var(--accent-glow); color: var(--text-primary); }
        .nav-item.active { background: var(--accent-glow); color: var(--accent); font-weight: 500; }
        .nav-item .icon { font-size: 1rem; width: 20px; text-align: center; }
        .nav-badge {
            margin-left: auto; font-size: 0.7rem; padding: 0.15rem 0.5rem;
            border-radius: 10px; font-weight: 600;
        }
        .badge-high { background: rgba(239,68,68,0.15); color: var(--high); }
        .badge-count { background: rgba(59,130,246,0.15); color: var(--accent); }

        /* ── Main content ──────────────────────────────────────── */
        .main { flex: 1; display: flex; flex-direction: column; overflow: hidden; }

        .topbar {
            height: 56px; min-height: 56px;
            background: var(--bg-secondary);
            border-bottom: 1px solid var(--border);
            display: flex; align-items: center; justify-content: space-between;
            padding: 0 1.5rem;
        }
        .topbar h2 { font-size: 0.95rem; font-weight: 600; }
        .topbar-actions { display: flex; gap: 0.75rem; align-items: center; }
        .btn {
            padding: 0.4rem 1rem; border-radius: 8px; border: none;
            font-family: var(--font); font-size: 0.8rem; font-weight: 500;
            cursor: pointer; transition: all 0.2s; display: flex;
            align-items: center; gap: 0.4rem;
        }
        .btn-primary { background: var(--accent); color: #fff; }
        .btn-primary:hover { background: #2563eb; }
        .btn-ghost {
            background: transparent; color: var(--text-secondary);
            border: 1px solid var(--border);
        }
        .btn-ghost:hover { background: var(--bg-card); color: var(--text-primary); }
        .status-dot {
            width: 8px; height: 8px; border-radius: 50%;
            display: inline-block; margin-right: 0.3rem;
        }
        .status-dot.online { background: var(--success); box-shadow: 0 0 6px var(--success); }

        .content { flex: 1; overflow-y: auto; padding: 1.5rem; }

        /* ── Stats Grid ────────────────────────────────────────── */
        .stats-grid {
            display: grid; grid-template-columns: repeat(auto-fit, minmax(180px, 1fr));
            gap: 1rem; margin-bottom: 1.5rem;
        }
        .stat-card {
            background: var(--bg-card);
            border: 1px solid var(--border);
            border-radius: 12px; padding: 1.2rem;
            transition: all 0.3s; position: relative; overflow: hidden;
        }
        .stat-card:hover { border-color: var(--accent); transform: translateY(-2px); }
        .stat-card::after {
            content: ''; position: absolute; top: 0; left: 0; right: 0;
            height: 3px; border-radius: 12px 12px 0 0;
        }
        .stat-card.high::after { background: var(--high); }
        .stat-card.medium::after { background: var(--medium); }
        .stat-card.low::after { background: var(--low); }
        .stat-card.info::after { background: var(--info); }
        .stat-card.total::after { background: linear-gradient(90deg, var(--accent), #8b5cf6); }
        .stat-label { font-size: 0.75rem; color: var(--text-muted); text-transform: uppercase; letter-spacing: 0.05em; }
        .stat-value { font-size: 2rem; font-weight: 700; margin: 0.3rem 0; }
        .stat-card.high .stat-value { color: var(--high); }
        .stat-card.medium .stat-value { color: var(--medium); }
        .stat-card.low .stat-value { color: var(--low); }
        .stat-card.total .stat-value { color: var(--text-primary); }

        /* ── Data Table ────────────────────────────────────────── */
        .table-section {
            background: var(--bg-card); border: 1px solid var(--border);
            border-radius: 12px; overflow: hidden;
        }
        .table-header {
            padding: 1rem 1.2rem; border-bottom: 1px solid var(--border);
            display: flex; align-items: center; justify-content: space-between;
        }
        .table-header h3 { font-size: 0.9rem; font-weight: 600; }
        table { width: 100%; border-collapse: collapse; }
        thead th {
            padding: 0.7rem 0.8rem; text-align: left; font-size: 0.7rem;
            font-weight: 600; text-transform: uppercase; letter-spacing: 0.06em;
            color: var(--text-muted); border-bottom: 1px solid var(--border);
            background: rgba(0,0,0,0.2);
        }
        tbody td {
            padding: 0.6rem 0.8rem; font-size: 0.82rem; border-bottom: 1px solid var(--border);
            color: var(--text-secondary);
        }
        tbody tr { transition: background 0.2s; }
        tbody tr:hover { background: rgba(59,130,246,0.05); }
        .risk-badge {
            padding: 0.2rem 0.6rem; border-radius: 6px; font-size: 0.7rem;
            font-weight: 600; display: inline-block;
        }
        .risk-HIGH { background: rgba(239,68,68,0.15); color: var(--high); }
        .risk-MEDIUM { background: rgba(245,158,11,0.15); color: var(--medium); }
        .risk-LOW { background: rgba(59,130,246,0.15); color: var(--low); }
        .risk-INFO { background: rgba(100,116,139,0.15); color: var(--info); }

        /* ── Reports list ──────────────────────────────────────── */
        .reports-grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(300px, 1fr)); gap: 1rem; }
        .report-card {
            background: var(--bg-card); border: 1px solid var(--border);
            border-radius: 12px; padding: 1.2rem; cursor: pointer;
            transition: all 0.3s;
        }
        .report-card:hover { border-color: var(--accent); transform: translateY(-2px); }
        .report-card .name { font-weight: 600; font-size: 0.85rem; margin-bottom: 0.3rem; word-break: break-all; }
        .report-card .meta { font-size: 0.75rem; color: var(--text-muted); }

        /* ── Chat Panel ────────────────────────────────────────── */
        .chat-panel {
            width: 420px; min-width: 420px;
            background: var(--bg-chat);
            border-left: 1px solid var(--border);
            display: flex; flex-direction: column;
            transition: all 0.3s;
        }
        .chat-panel.collapsed { width: 0; min-width: 0; overflow: hidden; border: none; }

        .chat-header {
            padding: 1rem 1.2rem;
            border-bottom: 1px solid var(--border);
            display: flex; align-items: center; justify-content: space-between;
        }
        .chat-header h3 {
            font-size: 0.9rem; font-weight: 600;
            display: flex; align-items: center; gap: 0.5rem;
        }
        .chat-header .ai-badge {
            font-size: 0.6rem; padding: 0.15rem 0.5rem; border-radius: 6px;
            background: linear-gradient(135deg, rgba(59,130,246,0.2), rgba(139,92,246,0.2));
            color: var(--accent); font-weight: 600;
        }
        .close-chat {
            background: none; border: none; color: var(--text-muted);
            cursor: pointer; font-size: 1.2rem; padding: 0.2rem;
        }
        .close-chat:hover { color: var(--text-primary); }

        .chat-messages {
            flex: 1; overflow-y: auto; padding: 1rem;
            display: flex; flex-direction: column; gap: 0.75rem;
        }
        .message {
            max-width: 90%; padding: 0.8rem 1rem; border-radius: 12px;
            font-size: 0.83rem; line-height: 1.5; animation: fadeIn 0.3s ease;
        }
        @keyframes fadeIn { from { opacity: 0; transform: translateY(8px); } to { opacity: 1; transform: translateY(0); } }
        .message.user {
            align-self: flex-end; background: var(--accent);
            color: #fff; border-bottom-right-radius: 4px;
        }
        .message.assistant {
            align-self: flex-start; background: var(--bg-card);
            border: 1px solid var(--border); border-bottom-left-radius: 4px;
            color: var(--text-primary);
        }
        .message.assistant strong { color: var(--accent); }
        .message.system {
            align-self: center; background: rgba(59,130,246,0.08);
            border: 1px solid rgba(59,130,246,0.15);
            color: var(--text-muted); font-size: 0.78rem; text-align: center;
            max-width: 100%;
        }
        .typing-indicator {
            display: flex; gap: 4px; padding: 1rem; align-self: flex-start;
        }
        .typing-indicator span {
            width: 8px; height: 8px; border-radius: 50%; background: var(--text-muted);
            animation: bounce 1.4s infinite;
        }
        .typing-indicator span:nth-child(2) { animation-delay: 0.2s; }
        .typing-indicator span:nth-child(3) { animation-delay: 0.4s; }
        @keyframes bounce {
            0%, 60%, 100% { transform: translateY(0); }
            30% { transform: translateY(-8px); }
        }

        .chat-input {
            padding: 1rem; border-top: 1px solid var(--border);
            display: flex; gap: 0.5rem;
        }
        .chat-input input {
            flex: 1; padding: 0.7rem 1rem; border-radius: 10px;
            border: 1px solid var(--border); background: var(--bg-secondary);
            color: var(--text-primary); font-family: var(--font); font-size: 0.85rem;
            outline: none; transition: border-color 0.2s;
        }
        .chat-input input:focus { border-color: var(--accent); }
        .chat-input input::placeholder { color: var(--text-muted); }
        .chat-input button {
            padding: 0.7rem 1rem; border-radius: 10px;
            background: var(--accent); border: none; color: #fff;
            cursor: pointer; font-size: 1rem; transition: background 0.2s;
            display: flex; align-items: center;
        }
        .chat-input button:hover { background: #2563eb; }
        .chat-input button:disabled { opacity: 0.5; cursor: not-allowed; }

        /* ── Quick actions ─────────────────────────────────────── */
        .quick-actions {
            padding: 0.75rem 1rem; display: flex; flex-wrap: wrap; gap: 0.4rem;
            border-bottom: 1px solid var(--border);
        }
        .quick-btn {
            padding: 0.35rem 0.7rem; border-radius: 16px; border: 1px solid var(--border);
            background: transparent; color: var(--text-muted); font-size: 0.72rem;
            cursor: pointer; font-family: var(--font); transition: all 0.2s;
            white-space: nowrap;
        }
        .quick-btn:hover {
            border-color: var(--accent); color: var(--accent);
            background: var(--accent-glow);
        }

        /* ── View panels ───────────────────────────────────────── */
        .view-panel { display: none; }
        .view-panel.active { display: block; }

        /* ── Report iframe ─────────────────────────────────────── */
        .report-frame {
            width: 100%; height: calc(100vh - 56px); border: none;
            background: #fff;
        }

        /* ── Scrollbar ─────────────────────────────────────────── */
        ::-webkit-scrollbar { width: 6px; }
        ::-webkit-scrollbar-track { background: transparent; }
        ::-webkit-scrollbar-thumb { background: var(--border); border-radius: 3px; }
        ::-webkit-scrollbar-thumb:hover { background: var(--text-muted); }
    </style>
</head>
<body>
<div class="app">
    <!-- ═══════ Sidebar ═══════ -->
    <nav class="sidebar">
        <div class="logo">
            <div class="logo-icon">DA</div>
            <div>
                <h1>DAMOps</h1>
                <span>Access Management</span>
            </div>
        </div>

        <div class="nav-section">
            <div class="nav-label">Dashboard</div>
            <div class="nav-item active" onclick="showView('dashboard')">
                <span class="icon">📊</span> Overview
                <span class="nav-badge badge-count" id="nav-total">—</span>
            </div>
            <div class="nav-item" onclick="showView('reports')">
                <span class="icon">📄</span> Reports
            </div>
        </div>

        <div class="nav-section">
            <div class="nav-label">Risk Findings</div>
            <div class="nav-item" onclick="filterRisk('HIGH')">
                <span class="icon">🔴</span> High Risk
                <span class="nav-badge badge-high" id="nav-high">—</span>
            </div>
            <div class="nav-item" onclick="filterRisk('MEDIUM')">
                <span class="icon">🟡</span> Medium Risk
            </div>
            <div class="nav-item" onclick="filterRisk('LOW')">
                <span class="icon">🔵</span> Low Risk
            </div>
        </div>

        <div class="nav-section">
            <div class="nav-label">Tools</div>
            <div class="nav-item" onclick="window.location.href='/ps-helper'">
                <span class="icon">💻</span> PS Helper
            </div>
        </div>

        <div class="nav-section" style="margin-top:auto;">
            <div class="nav-label">AI Engine</div>
            <div class="nav-item" onclick="toggleChat()" id="chat-toggle">
                <span class="icon">🤖</span> AI Chatbot
                <span class="status-dot online"></span>
            </div>
        </div>
    </nav>

    <!-- ═══════ Main Content ═══════ -->
    <div class="main">
        <div class="topbar">
            <h2 id="view-title">Access Audit Overview</h2>
            <div class="topbar-actions">
                <button class="btn btn-ghost" onclick="refreshData()">↻ Refresh</button>
                <button class="btn btn-primary" onclick="toggleChat()">🤖 AI Chat</button>
            </div>
        </div>

        <!-- Dashboard View -->
        <div class="content">
            <div class="view-panel active" id="view-dashboard">
                <div class="stats-grid" id="stats-grid">
                    <div class="stat-card total"><div class="stat-label">Total Audited</div><div class="stat-value" id="stat-total">—</div></div>
                    <div class="stat-card high"><div class="stat-label">High Risk</div><div class="stat-value" id="stat-high">—</div></div>
                    <div class="stat-card medium"><div class="stat-label">Medium Risk</div><div class="stat-value" id="stat-medium">—</div></div>
                    <div class="stat-card low"><div class="stat-label">Low Risk</div><div class="stat-value" id="stat-low">—</div></div>
                </div>

                <div class="table-section">
                    <div class="table-header">
                        <h3>Audit Findings</h3>
                        <input type="text" id="search-input" placeholder="Search users..." 
                            style="padding:0.4rem 0.8rem; border-radius:8px; border:1px solid var(--border); background:var(--bg-secondary); color:var(--text-primary); font-size:0.8rem; outline:none; width:200px;">
                    </div>
                    <div style="overflow-x:auto;">
                        <table>
                            <thead>
                                <tr>
                                    <th>Name</th><th>UPN</th><th>Type</th><th>Dept</th>
                                    <th>Last Sign-In</th><th>Days Stale</th><th>Privileged</th>
                                    <th>Roles</th><th>Risk</th>
                                </tr>
                            </thead>
                            <tbody id="audit-table"></tbody>
                        </table>
                    </div>
                </div>
            </div>

            <!-- Reports View -->
            <div class="view-panel" id="view-reports">
                <div class="reports-grid" id="reports-grid"></div>
            </div>

            <!-- Report Viewer -->
            <div class="view-panel" id="view-report-detail">
                <iframe id="report-frame" class="report-frame"></iframe>
            </div>
        </div>
    </div>

    <!-- ═══════ Chat Panel ═══════ -->
    <div class="chat-panel collapsed" id="chat-panel">
        <div class="chat-header">
            <h3>🤖 DAMOps AI <span class="ai-badge">NVIDIA NIM</span></h3>
            <button class="close-chat" onclick="toggleChat()">✕</button>
        </div>
        <div class="quick-actions">
            <button class="quick-btn" onclick="quickChat('Summarize the top risks')">Top Risks</button>
            <button class="quick-btn" onclick="quickChat('Who are the high risk users?')">High Risk Users</button>
            <button class="quick-btn" onclick="quickChat('What privileged accounts need attention?')">Priv Accounts</button>
            <button class="quick-btn" onclick="quickChat('Guest account recommendations')">Guest Review</button>
            <button class="quick-btn" onclick="quickChat('What should I do first?')">Priority Actions</button>
        </div>
        <div class="chat-messages" id="chat-messages">
            <div class="message system">
                DAMOps AI Assistant powered by NVIDIA NIM.<br>
                Ask me anything about the audit data.
            </div>
        </div>
        <div class="chat-input">
            <input type="text" id="chat-input" placeholder="Ask about the audit data..." 
                onkeydown="if(event.key==='Enter')sendChat()">
            <button onclick="sendChat()" id="send-btn">➤</button>
        </div>
    </div>
</div>

<script>
// ── State ───────────────────────────────────────────────────────────────
let auditData = [];
let chatHistory = [];
let currentFilter = null;

// ── Init ────────────────────────────────────────────────────────────────
document.addEventListener('DOMContentLoaded', () => {
    refreshData();
    loadReports();
});

// ── Data loading ────────────────────────────────────────────────────────
async function refreshData() {
    try {
        const res = await fetch('/api/audit-summary');
        const data = await res.json();
        if (!data.loaded) return;

        auditData = data.data;
        document.getElementById('stat-total').textContent = data.total;
        document.getElementById('stat-high').textContent = data.high;
        document.getElementById('stat-medium').textContent = data.medium;
        document.getElementById('stat-low').textContent = data.low;
        document.getElementById('nav-total').textContent = data.total;
        document.getElementById('nav-high').textContent = data.high;

        renderTable(auditData);
    } catch (e) { console.error('Refresh failed:', e); }
}

function renderTable(data) {
    const tbody = document.getElementById('audit-table');
    tbody.innerHTML = data.map(r => \`
        <tr>
            <td style="font-weight:500;color:var(--text-primary)">\${r.DisplayName}</td>
            <td style="font-size:0.75rem">\${r.UPN}</td>
            <td>\${r.UserType}</td>
            <td>\${r.Department}</td>
            <td>\${r.LastSignIn}</td>
            <td style="text-align:center;font-weight:600">\${r.DaysSinceSignIn}</td>
            <td>\${r.IsPrivileged === 'True' ? '✓' : ''}</td>
            <td style="font-size:0.73rem;max-width:180px;overflow:hidden;text-overflow:ellipsis">\${r.PrivilegedRoles !== '-' ? r.PrivilegedRoles : ''}</td>
            <td><span class="risk-badge risk-\${r.RiskFlag}">\${r.RiskFlag}</span></td>
        </tr>
    \`).join('');
}

// ── Search ──────────────────────────────────────────────────────────────
document.addEventListener('DOMContentLoaded', () => {
    document.getElementById('search-input').addEventListener('input', (e) => {
        const q = e.target.value.toLowerCase();
        const filtered = auditData.filter(r =>
            r.DisplayName.toLowerCase().includes(q) ||
            r.UPN.toLowerCase().includes(q) ||
            r.Department.toLowerCase().includes(q) ||
            r.RiskFlag.toLowerCase().includes(q)
        );
        renderTable(filtered);
    });
});

// ── Filter by risk ──────────────────────────────────────────────────────
function filterRisk(level) {
    showView('dashboard');
    const filtered = auditData.filter(r => r.RiskFlag === level);
    renderTable(filtered);
    document.getElementById('search-input').value = level;
}

// ── Reports ─────────────────────────────────────────────────────────────
async function loadReports() {
    try {
        const res = await fetch('/api/reports');
        const reports = await res.json();
        const grid = document.getElementById('reports-grid');
        grid.innerHTML = reports.map(r => \`
            <div class="report-card" onclick="openReport('\${r.name}')">
                <div class="name">\${r.type === 'html' ? '📊' : r.type === 'csv' ? '📋' : '📝'} \${r.name}</div>
                <div class="meta">\${r.type.toUpperCase()} · \${(r.size/1024).toFixed(1)} KB · \${new Date(r.modified).toLocaleString()}</div>
            </div>
        \`).join('');
    } catch (e) { console.error('Reports load failed:', e); }
}

function openReport(name) {
    showView('report-detail');
    document.getElementById('report-frame').src = '/' + name;
    document.getElementById('view-title').textContent = name;
}

// ── Navigation ──────────────────────────────────────────────────────────
function showView(view) {
    document.querySelectorAll('.view-panel').forEach(el => el.classList.remove('active'));
    document.getElementById('view-' + view).classList.add('active');

    document.querySelectorAll('.nav-item').forEach(el => el.classList.remove('active'));

    const titles = { dashboard: 'Access Audit Overview', reports: 'Generated Reports', 'report-detail': 'Report Viewer' };
    document.getElementById('view-title').textContent = titles[view] || '';

    if (view === 'dashboard') { renderTable(auditData); document.getElementById('search-input').value = ''; }
}

// ── Chat ────────────────────────────────────────────────────────────────
function toggleChat() {
    document.getElementById('chat-panel').classList.toggle('collapsed');
}

function quickChat(msg) {
    document.getElementById('chat-input').value = msg;
    sendChat();
}

async function sendChat() {
    const input = document.getElementById('chat-input');
    const msg = input.value.trim();
    if (!msg) return;
    input.value = '';

    // Add user message
    addMessage(msg, 'user');
    chatHistory.push({ role: 'user', content: msg });

    // Show typing indicator
    const typing = document.createElement('div');
    typing.className = 'typing-indicator';
    typing.innerHTML = '<span></span><span></span><span></span>';
    document.getElementById('chat-messages').appendChild(typing);
    typing.scrollIntoView({ behavior: 'smooth' });

    document.getElementById('send-btn').disabled = true;

    try {
        const res = await fetch('/api/chat', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ message: msg, history: chatHistory })
        });
        const data = await res.json();

        typing.remove();

        // Simple markdown rendering
        let html = data.reply
            .replace(/\\*\\*(.+?)\\*\\*/g, '<strong>$1</strong>')
            .replace(/^- /gm, '• ')
            .replace(/^(\\d+)\\. /gm, '$1. ')
            .replace(/\\n/g, '<br>');

        addMessage(html, 'assistant', true);
        chatHistory.push({ role: 'assistant', content: data.reply });

    } catch (e) {
        typing.remove();
        addMessage('Connection error. Please try again.', 'system');
    }

    document.getElementById('send-btn').disabled = false;
    document.getElementById('chat-input').focus();
}

function addMessage(content, role, isHTML = false) {
    const div = document.createElement('div');
    div.className = 'message ' + role;
    if (isHTML) { div.innerHTML = content; } else { div.textContent = content; }
    document.getElementById('chat-messages').appendChild(div);
    div.scrollIntoView({ behavior: 'smooth' });
}
</script>
</body>
</html>`;
}

// ── Start server ────────────────────────────────────────────────────────────
app.listen(PORT, () => {
    console.log('');
    console.log('  ╔══════════════════════════════════════════════════╗');
    console.log('  ║       DAMOps Web Dashboard                      ║');
    console.log('  ╠══════════════════════════════════════════════════╣');
    console.log(`  ║  URL:    http://localhost:${PORT}                   ║`);
    console.log('  ║  AI:     NVIDIA NIM (meta/llama-3.3-70b)        ║');
    console.log('  ║  Chat:   Click 🤖 AI Chat to open               ║');
    console.log('  ╚══════════════════════════════════════════════════╝');
    console.log('');
});

// ── PS Helper HTML ──────────────────────────────────────────────────────────
function getPSHelperHTML() {
    return `<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>PS Helper — DAMOps</title>
    <link href="https://fonts.googleapis.com/css2?family=Inter:wght@300;400;500;600;700&display=swap" rel="stylesheet">
    <link rel="stylesheet" href="https://cdnjs.cloudflare.com/ajax/libs/highlight.js/11.8.0/styles/atom-one-dark.min.css">
    <style>
        /* Shared Styles matching dashboard */
        * { margin: 0; padding: 0; box-sizing: border-box; }
        :root {
            --bg-primary: #0a0e17; --bg-secondary: #111827; --bg-card: #1a1f35;
            --border: #1e293b; --text-primary: #e2e8f0; --text-secondary: #94a3b8;
            --text-muted: #64748b; --accent: #3b82f6; --accent-glow: rgba(59, 130, 246, 0.15);
            --font: 'Inter', -apple-system, BlinkMacSystemFont, sans-serif;
            --success: #10b981;
        }

        body { font-family: var(--font); background: var(--bg-primary); color: var(--text-primary); min-height: 100vh; overflow-x: hidden; }
        body::before { content: ''; position: fixed; top: 0; left: 0; right: 0; bottom: 0; background: radial-gradient(ellipse at 20% 50%, rgba(59,130,246,0.06) 0%, transparent 60%), radial-gradient(ellipse at 80% 20%, rgba(139,92,246,0.04) 0%, transparent 60%); pointer-events: none; z-index: 0; }
        .app { position: relative; z-index: 1; display: flex; height: 100vh; }
        
        /* Sidebar */
        .sidebar { width: 280px; min-width: 280px; background: var(--bg-secondary); border-right: 1px solid var(--border); display: flex; flex-direction: column; padding: 1.5rem 1rem; }
        .logo { display: flex; align-items: center; gap: 0.75rem; padding: 0 0.5rem 1.5rem 0.5rem; border-bottom: 1px solid var(--border); margin-bottom: 1.5rem; }
        .logo-icon { width: 36px; height: 36px; background: linear-gradient(135deg, var(--accent), #8b5cf6); border-radius: 10px; display: flex; align-items: center; justify-content: center; font-weight: 700; font-size: 0.85rem; color: #fff; cursor: pointer; }
        .logo h1 { font-size: 1.1rem; font-weight: 700; letter-spacing: 0.05em; margin:0;}
        .logo span { font-size: 0.7rem; color: var(--text-muted); display: block; }
        
        .nav-section { margin-bottom: 1.5rem; }
        .nav-label { font-size: 0.65rem; font-weight: 600; text-transform: uppercase; letter-spacing: 0.1em; color: var(--text-muted); padding: 0 0.5rem; margin-bottom: 0.5rem; }
        .nav-item { display: flex; align-items: center; gap: 0.6rem; padding: 0.6rem 0.75rem; border-radius: 8px; cursor: pointer; transition: all 0.2s; font-size: 0.85rem; color: var(--text-secondary); }
        .nav-item:hover { background: var(--accent-glow); color: var(--text-primary); }
        .nav-item.active { background: var(--accent-glow); color: var(--accent); font-weight: 500; }
        .nav-item .icon { font-size: 1rem; width: 20px; text-align: center; }
        
        /* Main */
        .main { flex: 1; display: flex; flex-direction: column; overflow: hidden; }
        .topbar { height: 56px; min-height: 56px; background: var(--bg-secondary); border-bottom: 1px solid var(--border); display: flex; align-items: center; justify-content: space-between; padding: 0 1.5rem; }
        .topbar h2 { font-size: 0.95rem; font-weight: 600; }
        .content { flex: 1; overflow-y: auto; padding: 1.5rem; display: flex; flex-direction: column; align-items: center; }

        /* Tabs Navigation */
        .tabs-nav {
            display: flex; gap: 0.5rem; margin-bottom: 1.5rem;
            background: var(--bg-card); padding: 0.4rem; border-radius: 12px;
            border: 1px solid var(--border); width: 100%; max-width: 900px;
        }
        .tab-btn {
            flex: 1; text-align: center; padding: 0.7rem; border-radius: 8px; cursor: pointer;
            font-size: 0.85rem; font-weight: 500; color: var(--text-secondary);
            transition: all 0.2s;
        }
        .tab-btn:hover { color: var(--text-primary); }
        .tab-btn.active { background: var(--bg-secondary); color: var(--text-primary); box-shadow: 0 2px 4px rgba(0,0,0,0.2); }

        /* Tab Content */
        .tab-pane { display: none; width: 100%; max-width: 900px; }
        .tab-pane.active { display: block; animation: fadeIn 0.3s ease; }
        @keyframes fadeIn { from { opacity: 0; transform: translateY(5px); } to { opacity: 1; transform: translateY(0); } }

        .card { background: var(--bg-card); border: 1px solid var(--border); border-radius: 12px; padding: 1.5rem; margin-bottom: 1rem; }
        
        /* Command Guide Tab Styles */
        .search-bar { width: 100%; padding: 0.8rem 1rem; border-radius: 8px; border: 1px solid var(--border); background: var(--bg-secondary); color: var(--text-primary); font-family: var(--font); font-size: 0.9rem; margin-bottom: 1rem; outline: none; }
        .search-bar:focus { border-color: var(--accent); }
        .chips { display: flex; flex-wrap: wrap; gap: 0.5rem; margin-bottom: 1.5rem; }
        .chip { padding: 0.3rem 0.8rem; border-radius: 16px; border: 1px solid var(--border); background: var(--bg-secondary); font-size: 0.75rem; cursor: pointer; color: var(--text-secondary); transition: all 0.2s; }
        .chip:hover { border-color: var(--accent); color: var(--text-primary); }
        .chip.active { background: var(--accent); border-color: var(--accent); color: #fff; }
        
        .cmd-grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(280px, 1fr)); gap: 1rem; }
        .cmd-card { background: var(--bg-secondary); border: 1px solid var(--border); border-radius: 8px; padding: 1rem; position: relative; transition: all 0.2s; }
        .cmd-card:hover { border-color: var(--accent); }
        .cmd-name { font-family: monospace; font-size: 0.95rem; font-weight: 600; color: var(--accent); margin-bottom: 0.4rem; padding-right: 30px;}
        .cmd-cat { font-size: 0.65rem; color: var(--text-muted); text-transform: uppercase; margin-bottom: 0.6rem; letter-spacing:0.05em;}
        .cmd-desc { font-size: 0.8rem; color: var(--text-primary); margin-bottom: 0.8rem; line-height: 1.4; }
        .cmd-block { background: var(--bg-primary); border-radius: 6px; padding: 0.6rem; font-family: monospace; font-size: 0.75rem; color: #a6accd; overflow-x: auto; margin-bottom: 0.5rem; border: 1px solid #111;}
        .cmd-label { font-size: 0.7rem; color: var(--text-muted); margin-bottom: 0.2rem; }
        
        .copy-btn { position: absolute; top: 0.8rem; right: 0.8rem; background: transparent; border: none; color: var(--text-muted); cursor: pointer; transition: color 0.2s; }
        .copy-btn:hover { color: var(--text-primary); }
        .btn-explain { background: rgba(59, 130, 246, 0.1); border: 1px solid rgba(59, 130, 246, 0.3); color: var(--accent); padding: 0.3rem 0.6rem; border-radius: 4px; font-size: 0.7rem; cursor: pointer; margin-top: 0.5rem; transition: background 0.2s;}
        .btn-explain:hover { background: rgba(59, 130, 246, 0.2); }

        /* Script Generator Styles */
        .form-group { margin-bottom: 1rem; }
        .form-label { display: block; font-size: 0.8rem; font-weight: 500; margin-bottom: 0.4rem; color: var(--text-secondary); }
        .form-control { width: 100%; padding: 0.7rem 0.8rem; border-radius: 8px; border: 1px solid var(--border); background: var(--bg-secondary); color: var(--text-primary); font-family: var(--font); font-size: 0.9rem; outline: none; transition: border-color 0.2s;}
        .form-control:focus { border-color: var(--accent); }
        textarea.form-control { resize: vertical; min-height: 80px; }
        
        .form-row { display: flex; gap: 1rem; margin-bottom: 1rem; flex-wrap: wrap; }
        .form-col { flex: 1; min-width: 200px; }
        
        .checkbox-container { display: flex; align-items: center; gap: 0.5rem; font-size: 0.85rem; color: var(--text-secondary); cursor: pointer; }
        .checkbox-container input { width: 16px; height: 16px; cursor: pointer; }
        
        .btn-generate { width: 100%; padding: 0.8rem; border-radius: 8px; background: var(--accent); color: #fff; font-weight: 600; font-size: 0.95rem; border: none; cursor: pointer; transition: background 0.2s; display: flex; align-items: center; justify-content: center; gap: 0.5rem; }
        .btn-generate:hover { background: #2563eb; }
        .btn-generate:disabled { opacity: 0.6; cursor: not-allowed; }

        .result-container { display: none; margin-top: 1.5rem; border-top: 1px solid var(--border); padding-top: 1.5rem; }
        .result-header { display: flex; justify-content: space-between; align-items: center; margin-bottom: 1rem; }
        .result-filename { font-family: monospace; font-size: 1.1rem; color: var(--accent); font-weight: 600; }
        .badges { display: flex; gap: 0.4rem; flex-wrap: wrap; margin-bottom: 1rem; }
        .badge { padding: 0.2rem 0.5rem; background: rgba(59, 130, 246, 0.1); border: 1px solid rgba(59, 130, 246, 0.2); border-radius: 4px; font-size: 0.7rem; color: var(--accent); font-family: monospace; }
        
        pre { margin: 0; padding: 1rem; border-radius: 8px; background: var(--bg-primary); border: 1px solid #111; overflow-x: auto; position: relative;}
        code { font-family: monospace; font-size: 0.85rem; line-height: 1.5; }
        
        .actions-row { display: flex; gap: 0.8rem; margin-bottom: 1rem; }
        .btn-action { padding: 0.5rem 1rem; border-radius: 6px; background: var(--bg-secondary); border: 1px solid var(--border); color: var(--text-primary); cursor: pointer; font-size: 0.8rem; transition: all 0.2s; display: flex; align-items: center; gap: 0.4rem;}
        .btn-action:hover { border-color: var(--accent); color: var(--accent); }
        .btn-action.download { background: var(--accent); border-color: var(--accent); color: #fff; }
        .btn-action.download:hover { background: #2563eb; }
        
        .loader { width: 16px; height: 16px; border: 2px solid rgba(255,255,255,0.3); border-radius: 50%; border-top-color: #fff; animation: spin 1s linear infinite; display: none; }
        @keyframes spin { 100% { transform: rotate(360deg); } }

        /* Explanation Modal */
        .modal-overlay { position: fixed; top: 0; left: 0; right: 0; bottom: 0; background: rgba(0,0,0,0.6); display: none; justify-content: center; align-items: center; z-index: 1000; backdrop-filter: blur(2px);}
        .modal { background: var(--bg-card); border: 1px solid var(--border); border-radius: 12px; padding: 1.5rem; width: 90%; max-width: 600px; max-height: 80vh; overflow-y: auto; position: relative;}
        .modal-close { position: absolute; top: 1rem; right: 1rem; background: none; border: none; color: var(--text-muted); cursor: pointer; font-size: 1.2rem; }
        .modal-close:hover { color: var(--text-primary); }
        .modal-content { font-size: 0.85rem; line-height: 1.5; color: var(--text-secondary); margin-top: 1rem;}
        .modal-content b { color: var(--text-primary); }
        .modal-content code { background: rgba(59, 130, 246, 0.1); color: var(--accent); padding: 0.1rem 0.3rem; border-radius: 4px; font-family: monospace;}

        /* Scrollbar */
        ::-webkit-scrollbar { width: 6px; }
        ::-webkit-scrollbar-track { background: transparent; }
        ::-webkit-scrollbar-thumb { background: var(--border); border-radius: 3px; }
        ::-webkit-scrollbar-thumb:hover { background: var(--text-muted); }
    </style>
</head>
<body>
<div class="app">
    <!-- Sidebar -->
    <nav class="sidebar">
        <div class="logo">
            <div class="logo-icon" onclick="window.location.href='/'">DA</div>
            <div>
                <h1>DAMOps</h1>
                <span>Access Management</span>
            </div>
        </div>
        <div class="nav-section">
            <div class="nav-label">Dashboard</div>
            <div class="nav-item" onclick="window.location.href='/'">
                <span class="icon">📊</span> Overview
            </div>
        </div>
        <div class="nav-section">
            <div class="nav-label">Tools</div>
            <div class="nav-item active">
                <span class="icon">💻</span> PS Helper
            </div>
        </div>
    </nav>

    <!-- Main -->
    <div class="main">
        <div class="topbar">
            <h2>PowerShell & Scripting Assistant</h2>
        </div>
        <div class="content">
            <!-- Tabs -->
            <div class="tabs-nav">
                <div class="tab-btn active" onclick="switchTab('script-gen')">🛠️ Script Generator</div>
                <div class="tab-btn" onclick="switchTab('cmd-guide')">📚 Command Guide</div>
                <div class="tab-btn" onclick="switchTab('python-helper')">🐍 Python Helper</div>
                <div class="tab-btn" onclick="switchTab('how-to')">📖 How to Use</div>
            </div>

            <!-- Tab 1: Script Generator -->
            <div id="tab-script-gen" class="tab-pane active">
                <div class="card">
                    <h3>AI PowerShell Script Generator</h3>
                    <p style="color:var(--text-muted); font-size:0.85rem; margin-top:0.5rem; margin-bottom:1.5rem;">Describe what you want to automate, and the AI will generate a production-ready, logged, and role-enforced script.</p>
                    
                    <div class="form-group">
                        <label class="form-label">Task Description</label>
                        <textarea id="gen-task" class="form-control" placeholder="e.g. Find all active users who haven't logged in for 90 days and disable them, then export a report..."></textarea>
                    </div>
                    
                    <div class="form-row">
                        <div class="form-col">
                            <label class="form-label">Active Role</label>
                            <select id="gen-role" class="form-control">
                                <option value="DAMAnalyst">DAMAnalyst (Read-Only/Reports)</option>
                                <option value="ITAdmin" selected>ITAdmin (Full Execution)</option>
                                <option value="SecurityOps">SecurityOps (Privileged Roles)</option>
                                <option value="HelpDesk">HelpDesk (Input Validation)</option>
                            </select>
                        </div>
                        <div class="form-col">
                            <label class="form-label">Environment</label>
                            <select id="gen-env" class="form-control">
                                <option value="Entra ID / Azure AD">Entra ID / Azure AD</option>
                                <option value="On-Prem Active Directory">On-Prem Active Directory</option>
                                <option value="Hybrid">Hybrid Directory</option>
                                <option value="Exchange Online">Exchange Online</option>
                            </select>
                        </div>
                        <div class="form-col">
                            <label class="form-label">Output Format</label>
                            <select id="gen-output" class="form-control">
                                <option value="CSV">CSV</option>
                                <option value="HTML">HTML</option>
                                <option value="Log only">Log only</option>
                            </select>
                        </div>
                    </div>
                    
                    <div class="form-row" style="align-items: center;">
                        <div class="form-col" style="flex: 2;">
                            <label class="form-label">Ticket Reference (Optional)</label>
                            <input type="text" id="gen-ticket" class="form-control" placeholder="INC-123456">
                        </div>
                        <div class="form-col" style="display:flex; justify-content: flex-end; padding-top:1.5rem;">
                            <label class="checkbox-container">
                                <input type="checkbox" id="gen-dryrun" checked> Enable -DryRun switch (Preview only)
                            </label>
                        </div>
                    </div>
                    
                    <button class="btn-generate" id="gen-btn" onclick="generateScript()">
                        <div class="loader" id="gen-loader"></div>
                        <span id="gen-btn-text">⚡ Generate Script</span>
                    </button>
                    
                    <div id="gen-error" style="color:var(--high); font-size:0.8rem; margin-top:1rem; display:none;"></div>
                    
                    <div class="result-container" id="gen-result">
                        <div class="result-header">
                            <div class="result-filename" id="res-filename">script.ps1</div>
                            <div style="font-size:0.75rem; color:var(--text-muted)">Est. Runtime: <span id="res-time"></span></div>
                        </div>
                        <div class="badges" id="res-modules"></div>
                        
                        <div class="actions-row">
                            <button class="btn-action download" onclick="downloadScript()">💾 Download .ps1</button>
                            <button class="btn-action" onclick="copyGenScript(this)">📋 Copy Code</button>
                            <button class="btn-action" onclick="explainCmd('Generated Script')">🤔 What does this do?</button>
                        </div>
                        
                        <pre><code class="language-powershell" id="res-code"></code></pre>
                    </div>
                </div>
            </div>

            <!-- Tab 2: Command Guide -->
            <div id="tab-cmd-guide" class="tab-pane">
                <div class="card">
                    <h3>PowerShell Command Reference</h3>
                    <p style="color:var(--text-muted); font-size:0.85rem; margin-top:0.5rem; margin-bottom: 1.5rem;">
                        Search and filter essential PowerShell cmdlets for IAM operations.
                    </p>
                    <input type="text" id="cmd-search" class="search-bar" placeholder="Search commands, description, or syntax..." oninput="filterCommands()">
                    <div class="chips" id="cmd-chips">
                        <!-- Chips rendered here -->
                    </div>
                </div>
                <div class="cmd-grid" id="cmd-grid">
                    <!-- Cards rendered here -->
                </div>
            </div>

            <!-- Tab 3: Python Helper -->
            <div id="tab-python-helper" class="tab-pane">
                <div class="card">
                    <h3>Python Snippet Generator</h3>
                    <p style="color:var(--text-muted); font-size:0.85rem; margin-top:0.5rem; margin-bottom:1.5rem;">Generate clean, well-commented Python 3 scripts for IT automation and data processing.</p>
                    
                    <div class="form-group">
                        <label class="form-label">Task Description</label>
                        <textarea id="py-task" class="form-control" placeholder="e.g. Parse a CSV of user accounts and flag anyone with no sign-in in 90 days..."></textarea>
                    </div>
                    
                    <div class="form-row">
                        <div class="form-col">
                            <label class="form-label">Use Case</label>
                            <select id="py-usecase" class="form-control">
                                <option value="Data Processing">Data Processing</option>
                                <option value="API Integration">API Integration</option>
                                <option value="Report Generation">Report Generation</option>
                                <option value="Automation Script">Automation Script</option>
                                <option value="Log Analysis">Log Analysis</option>
                            </select>
                        </div>
                        <div class="form-col">
                            <label class="form-label">Output Type</label>
                            <select id="py-output" class="form-control">
                                <option value="Print to console">Print to console</option>
                                <option value="Save to CSV">Save to CSV</option>
                                <option value="Save to JSON">Save to JSON</option>
                                <option value="Return as function">Return as function</option>
                            </select>
                        </div>
                    </div>
                    
                    <div class="form-group">
                        <label class="form-label">Allowed Libraries</label>
                        <div style="display:flex; flex-wrap:wrap; gap:1rem; margin-bottom: 0.5rem; background: var(--bg-secondary); padding: 1rem; border-radius: 8px; border: 1px solid var(--border);">
                            <label class="checkbox-container"><input type="checkbox" class="py-lib" value="pandas"> pandas</label>
                            <label class="checkbox-container"><input type="checkbox" class="py-lib" value="requests"> requests</label>
                            <label class="checkbox-container"><input type="checkbox" class="py-lib" value="openpyxl"> openpyxl</label>
                            <label class="checkbox-container"><input type="checkbox" class="py-lib" value="json" checked> json</label>
                            <label class="checkbox-container"><input type="checkbox" class="py-lib" value="csv" checked> csv</label>
                            <label class="checkbox-container"><input type="checkbox" class="py-lib" value="datetime" checked> datetime</label>
                            <label class="checkbox-container"><input type="checkbox" class="py-lib" value="os" checked> os</label>
                            <label class="checkbox-container"><input type="checkbox" class="py-lib" value="re"> re</label>
                        </div>
                    </div>
                    
                    <button class="btn-generate" id="py-btn" onclick="generatePython()">
                        <div class="loader" id="py-loader"></div>
                        <span id="py-btn-text">⚡ Generate Snippet</span>
                    </button>
                    
                    <div id="py-error" style="color:var(--high); font-size:0.8rem; margin-top:1rem; display:none;"></div>
                    
                    <div class="result-container" id="py-result">
                        <div class="result-header">
                            <div class="result-filename" id="pres-filename">script.py</div>
                            <div style="font-size:0.75rem; color:var(--text-muted)">Version: <span id="pres-time"></span></div>
                        </div>
                        <div class="badges" id="pres-modules"></div>
                        
                        <div class="actions-row">
                            <button class="btn-action download" onclick="downloadPython()">💾 Download .py</button>
                            <button class="btn-action" onclick="copyPythonScript(this)">📋 Copy Code</button>
                            <button class="btn-action" onclick="explainCmd('Python Snippet')">🤔 What does this do?</button>
                        </div>
                        
                        <pre><code class="language-python" id="pres-code"></code></pre>
                    </div>
                </div>
            </div>

            <!-- Tab 4: How to Use -->
            <div id="tab-how-to" class="tab-pane">
                <div class="card">
                    <h3 style="margin-bottom:1.5rem; color:var(--accent);">How to Use PS Helper</h3>
                    
                    <div style="margin-bottom:2rem;">
                        <h4 style="margin-bottom:0.5rem; color:var(--text-primary);">Section 1 &mdash; Getting Started</h4>
                        <div class="cmd-block">
Install the DAMOps module: Import-Module ./DAMOps.psm1
Connect to your tenant: Connect-DAMOps -Tenant contoso.onmicrosoft.com
Run your first audit: Invoke-AccessAudit -StaleThreshold 90 -Output Both
                        </div>
                    </div>

                    <div style="margin-bottom:2rem;">
                        <h4 style="margin-bottom:0.5rem; color:var(--text-primary);">Section 2 &mdash; PS Helper: Script Generator</h4>
                        <p style="font-size:0.85rem; color:var(--text-secondary); line-height:1.6; margin-bottom:1rem;">
                            Step by step: describe your task &rarr; select your role &rarr; choose environment &rarr; toggle DryRun &rarr; click Generate &rarr; review the script &rarr; download or copy.
                        </p>
                        <div style="background:rgba(245, 158, 11, 0.1); border-left:4px solid #f59e0b; padding:1rem; border-radius:4px;">
                            <p style="font-size:0.85rem; color:#f59e0b; margin:0;">
                                <strong>Warning:</strong> Always run with <code>-DryRun</code> first. Review output before removing <code>-DryRun</code> for production execution.
                            </p>
                        </div>
                    </div>

                    <div style="margin-bottom:2rem;">
                        <h4 style="margin-bottom:0.5rem; color:var(--text-primary);">Section 3 &mdash; Role-Based Access Guide</h4>
                        <table style="width:100%; border-collapse:collapse; font-size:0.85rem; text-align:left;">
                            <thead>
                                <tr style="border-bottom:1px solid var(--border); color:var(--text-secondary);">
                                    <th style="padding:0.5rem;">Role</th>
                                    <th style="padding:0.5rem;">What they can generate</th>
                                    <th style="padding:0.5rem;">What is blocked</th>
                                </tr>
                            </thead>
                            <tbody>
                                <tr style="border-bottom:1px solid var(--border);">
                                    <td style="padding:0.5rem; font-weight:600; color:var(--accent);">DAMAnalyst</td>
                                    <td style="padding:0.5rem; color:var(--text-secondary);">Read, export, report scripts</td>
                                    <td style="padding:0.5rem; color:var(--text-secondary);">Any Set/New/Remove/Disable</td>
                                </tr>
                                <tr style="border-bottom:1px solid var(--border);">
                                    <td style="padding:0.5rem; font-weight:600; color:var(--accent);">ITAdmin</td>
                                    <td style="padding:0.5rem; color:var(--text-secondary);">All scripts including enforce</td>
                                    <td style="padding:0.5rem; color:var(--text-secondary);">Nothing blocked</td>
                                </tr>
                                <tr style="border-bottom:1px solid var(--border);">
                                    <td style="padding:0.5rem; font-weight:600; color:var(--accent);">SecurityOps</td>
                                    <td style="padding:0.5rem; color:var(--text-secondary);">Priv role + anomaly scripts</td>
                                    <td style="padding:0.5rem; color:var(--text-secondary);">JML and account changes</td>
                                </tr>
                                <tr>
                                    <td style="padding:0.5rem; font-weight:600; color:var(--accent);">HelpDesk</td>
                                    <td style="padding:0.5rem; color:var(--text-secondary);">Input validation only</td>
                                    <td style="padding:0.5rem; color:var(--text-secondary);">All execution scripts</td>
                                </tr>
                            </tbody>
                        </table>
                    </div>

                    <div style="margin-bottom:2rem;">
                        <h4 style="margin-bottom:0.5rem; color:var(--text-primary);">Section 4 &mdash; Python Helper</h4>
                        <p style="font-size:0.85rem; color:var(--text-secondary); margin-bottom:0.8rem;">When to use Python vs PowerShell — quick decision guide:</p>
                        <ul style="font-size:0.85rem; color:var(--text-secondary); padding-left:1.5rem; line-height:1.6;">
                            <li><strong>Use PowerShell:</strong> AD/Entra ID operations, M365 management, Windows automation.</li>
                            <li><strong>Use Python:</strong> Data parsing, report generation, API calls, log analysis, cross-platform scripts.</li>
                        </ul>
                    </div>

                    <div style="margin-bottom:2rem;">
                        <h4 style="margin-bottom:0.5rem; color:var(--text-primary);">Section 5 &mdash; Command Reference Tips</h4>
                        <p style="font-size:0.85rem; color:var(--text-secondary); line-height:1.6;">
                            Use the search bar to filter by cmdlet name or description. Use the <strong>Explain this command</strong> button to have the AI interpret the selected command and provide a custom example. You can copy the code from any block directly into your script generator prompt.
                        </p>
                    </div>

                    <div>
                        <h4 style="margin-bottom:0.5rem; color:var(--text-primary);">Section 6 &mdash; Logging</h4>
                        <p style="font-size:0.85rem; color:var(--text-secondary); line-height:1.6;">
                            Every script generated is automatically logged in <code>/Logs/ps-helper.log</code> with:
                            timestamp, role, environment, and the filename generated.
                        </p>
                    </div>

                </div>
            </div>
        </div>
    </div>
</div>

<!-- Explanation Modal -->
<div class="modal-overlay" id="explainModal">
    <div class="modal">
        <button class="modal-close" onclick="closeModal()">✕</button>
        <h3 id="modal-title" style="margin-bottom:0.5rem; padding-right:2rem; font-size:1.1rem; border-bottom: 1px solid var(--border); padding-bottom: 0.5rem;">AI Explanation</h3>
        <div class="modal-content" id="modal-body"></div>
    </div>
</div>

<script src="https://cdnjs.cloudflare.com/ajax/libs/highlight.js/11.8.0/highlight.min.js"></script>
<script>
// State
let allCommands = [];
let cmdFilterCategory = 'All';

// Init
document.addEventListener('DOMContentLoaded', () => {
    loadCommands();
});

// Tab Router
function switchTab(tabId) {
    document.querySelectorAll('.tab-btn').forEach(btn => btn.classList.remove('active'));
    document.querySelectorAll('.tab-pane').forEach(pane => pane.classList.remove('active'));
    event.currentTarget.classList.add('active');
    document.getElementById('tab-' + tabId).classList.add('active');
}

// Commands Logic
async function loadCommands() {
    try {
        const res = await fetch('/api/ps-helper/commands');
        allCommands = await res.json();
        
        // Extract unique categories
        const cats = new Set(allCommands.map(c => c.category));
        renderChips(['All', ...Array.from(cats)]);
        renderCommands(allCommands);
    } catch(e) {
        console.error('Failed to load commands', e);
    }
}

function renderChips(categories) {
    const chipsDiv = document.getElementById('cmd-chips');
    chipsDiv.innerHTML = categories.map(cat => 
        \`<div class="chip \${cat === cmdFilterCategory ? 'active' : ''}" onclick="setCmdCategory('\${cat}')">\${cat}</div>\`
    ).join('');
}

function setCmdCategory(cat) {
    cmdFilterCategory = cat;
    renderChips(['All', ...new Set(allCommands.map(c => c.category))]);
    filterCommands();
}

function filterCommands() {
    const q = document.getElementById('cmd-search').value.toLowerCase();
    const filtered = allCommands.filter(c => {
        const matchesQuery = c.name.toLowerCase().includes(q) || c.description.toLowerCase().includes(q);
        const matchesCat = cmdFilterCategory === 'All' || c.category === cmdFilterCategory;
        return matchesQuery && matchesCat;
    });
    renderCommands(filtered);
}

function renderCommands(cmds) {
    const grid = document.getElementById('cmd-grid');
    if(cmds.length === 0) {
        grid.innerHTML = '<p style="color:var(--text-muted)">No commands found.</p>';
        return;
    }
    grid.innerHTML = cmds.map(c => \`
        <div class="cmd-card">
            <button class="copy-btn" onclick="copyText(this, '\${c.example.replace(/'/g, "\\'")}')" title="Copy Example">📋</button>
            <div class="cmd-name">\${c.name}</div>
            <div class="cmd-cat">\${c.category}</div>
            <div class="cmd-desc">\${c.description}</div>
            
            <div class="cmd-label">Syntax</div>
            <div class="cmd-block">\${c.syntax}</div>
            
            <div class="cmd-label">Example</div>
            <div class="cmd-block" style="color:#c3e88d;">\${c.example}</div>
            
            <button class="btn-explain" onclick="explainCmd('\${c.name}')">Explain this command</button>
        </div>
    \`).join('');
}

function copyText(btn, text) {
    navigator.clipboard.writeText(text);
    btn.textContent = '✅';
    setTimeout(() => { btn.textContent = '📋'; }, 2000);
}

let currentScriptData = null;

async function generateScript() {
    const task = document.getElementById('gen-task').value.trim();
    if(!task) return alert('Please describe the task.');
    
    const role = document.getElementById('gen-role').value;
    const environment = document.getElementById('gen-env').value;
    const outputFormat = document.getElementById('gen-output').value;
    const dryRun = document.getElementById('gen-dryrun').checked;
    const ticketRef = document.getElementById('gen-ticket').value.trim();
    
    // UI State
    document.getElementById('gen-btn').disabled = true;
    document.getElementById('gen-loader').style.display = 'block';
    document.getElementById('gen-btn-text').textContent = 'Generating with NVIDIA LLaMA 3.3 70B...';
    document.getElementById('gen-result').style.display = 'none';
    document.getElementById('gen-error').style.display = 'none';

    try {
        const res = await fetch('/api/ps-helper/generate', {
            method: 'POST',
            headers: {'Content-Type': 'application/json'},
            body: JSON.stringify({ task, role, environment, outputFormat, dryRun, ticketRef })
        });
        
        const data = await res.json();
        if(res.status !== 200) throw new Error(data.error || 'Server error');
        
        currentScriptData = data;
        
        // Render
        document.getElementById('res-filename').textContent = data.filename;
        document.getElementById('res-time').textContent = data.estimatedRuntime;
        document.getElementById('res-modules').innerHTML = (data.requiredModules||[]).map(m => \`<span class="badge">\${m}</span>\`).join('');
        
        const codeElement = document.getElementById('res-code');
        codeElement.textContent = data.script || data.raw || "No output returned";
        
        // Syntax highlighting
        delete codeElement.dataset.highlighted;
        hljs.highlightElement(codeElement);
        
        document.getElementById('gen-result').style.display = 'block';
        
    } catch(e) {
        document.getElementById('gen-error').textContent = 'Error: ' + e.message;
        document.getElementById('gen-error').style.display = 'block';
    } finally {
        document.getElementById('gen-btn').disabled = false;
        document.getElementById('gen-loader').style.display = 'none';
        document.getElementById('gen-btn-text').textContent = '⚡ Generate Script';
    }
}

function copyGenScript(btn) {
    if(!currentScriptData) return;
    navigator.clipboard.writeText(currentScriptData.script);
    btn.textContent = '✅ Copied!';
    setTimeout(() => { btn.innerHTML = '📋 Copy Code'; }, 2000);
}

function downloadScript() {
    if(!currentScriptData) return;
    const blob = new Blob([currentScriptData.script], { type: 'text/plain' });
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url;
    a.download = currentScriptData.filename || 'script.ps1';
    a.click();
    URL.revokeObjectURL(url);
}

// Modal logic
function openModal(title, htmlContent) {
    document.getElementById('modal-title').textContent = title;
    document.getElementById('modal-body').innerHTML = htmlContent;
    document.getElementById('explainModal').style.display = 'flex';
}
function closeModal() {
    document.getElementById('explainModal').style.display = 'none';
}

async function explainCmd(name) {
    let codeToExplain = name;
    
    // Determine context
    if(name === 'Generated Script') {
        if(!currentScriptData) return alert('No script generated yet.');
        codeToExplain = currentScriptData.script;
    } else if(name === 'Python Snippet') {
        if(!currentPythonData) return alert('No script generated yet.');
        codeToExplain = currentPythonData.script;
    } else {
        // It's a command card lookup
        const cmd = allCommands.find(c => c.name === name);
        if(cmd) codeToExplain = cmd.name + '\\n' + cmd.syntax + '\\n' + cmd.example;
    }

    openModal('AI Explanation: ' + name, '<div style="display:flex; justify-content:center; padding: 2rem;"><div class="loader" style="display:block; border-top-color:var(--accent);"></div></div><div style="text-align:center;font-size:0.8rem;margin-top:1rem;">Asking NVIDIA LLaMA 3.3 70B...</div>');

    try {
        const res = await fetch('/api/ps-helper/explain', {
            method: 'POST',
            headers: {'Content-Type': 'application/json'},
            body: JSON.stringify({ code: codeToExplain })
        });
        const data = await res.json();
        if(res.status !== 200) throw new Error(data.error || 'Server error');
        
        document.getElementById('modal-body').innerHTML = data.explanation;
    } catch(e) {
        document.getElementById('modal-body').innerHTML = '<div style="color:var(--high)">Error generating explanation: ' + e.message + '</div>';
    }
}

let currentPythonData = null;

async function generatePython() {
    const task = document.getElementById('py-task').value.trim();
    if(!task) return alert('Please describe the task.');
    
    const usecase = document.getElementById('py-usecase').value;
    const outputType = document.getElementById('py-output').value;
    
    const checkboxes = document.querySelectorAll('.py-lib');
    const libraries = Array.from(checkboxes).filter(c => c.checked).map(c => c.value).join(', ');
    
    document.getElementById('py-btn').disabled = true;
    document.getElementById('py-loader').style.display = 'block';
    document.getElementById('py-btn-text').textContent = 'Generating with NVIDIA LLaMA 3.3 70B...';
    document.getElementById('py-result').style.display = 'none';
    document.getElementById('py-error').style.display = 'none';

    try {
        const res = await fetch('/api/ps-helper/python', {
            method: 'POST',
            headers: {'Content-Type': 'application/json'},
            body: JSON.stringify({ task, usecase, outputType, libraries })
        });
        const data = await res.json();
        if(res.status !== 200) throw new Error(data.error || 'Server error');
        
        currentPythonData = data;
        
        document.getElementById('pres-filename').textContent = data.filename;
        document.getElementById('pres-time').textContent = data.pythonVersion;
        document.getElementById('pres-modules').innerHTML = (data.libraries||[]).map(m => \`<span class="badge">\${m}</span>\`).join('');
        
        const codeElement = document.getElementById('pres-code');
        codeElement.textContent = data.script;
        
        delete codeElement.dataset.highlighted;
        hljs.highlightElement(codeElement);
        
        document.getElementById('py-result').style.display = 'block';
        
    } catch(e) {
        document.getElementById('py-error').textContent = 'Error: ' + e.message;
        document.getElementById('py-error').style.display = 'block';
    } finally {
        document.getElementById('py-btn').disabled = false;
        document.getElementById('py-loader').style.display = 'none';
        document.getElementById('py-btn-text').textContent = '⚡ Generate Snippet';
    }
}

function copyPythonScript(btn) {
    if(!currentPythonData) return;
    navigator.clipboard.writeText(currentPythonData.script);
    btn.textContent = '✅ Copied!';
    setTimeout(() => { btn.innerHTML = '📋 Copy Code'; }, 2000);
}

function downloadPython() {
    if(!currentPythonData) return;
    const blob = new Blob([currentPythonData.script], { type: 'text/plain' });
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url;
    a.download = currentPythonData.filename || 'script.py';
    a.click();
    URL.revokeObjectURL(url);
}
</script>
</body>
</html>`;
}
