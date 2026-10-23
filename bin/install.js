#!/usr/bin/env node
/**
 * clash-skill installer
 *
 * Copies the skill into detected AI-assistant skill directories and generates
 * clash-config.json by probing the local Clash for Windows installation.
 *
 * Usage:
 *   npx github:paranoiadd/clash-skill
 *   npx github:paranoiadd/clash-skill --dir ~/.workbuddy/skills
 *   npx github:paranoiadd/clash-skill --force
 */
'use strict';

const fs = require('fs');
const path = require('path');
const os = require('os');

const PKG_ROOT = path.resolve(__dirname, '..');
const SKILL_NAME = 'clash';

// ---------------------------------------------------------------- colors
const useColor = process.stdout.isTTY && !process.env.NO_COLOR;
const paint = (code) => (s) => (useColor ? `\x1b[${code}m${s}\x1b[0m` : String(s));
const bold = paint('1');
const dim = paint('2');
const green = paint('32');
const yellow = paint('33');
const cyan = paint('36');
const red = paint('31');

const ok = (m) => console.log(`${green('✔')} ${m}`);
const warn = (m) => console.log(`${yellow('!')} ${m}`);
const fail = (m) => console.log(`${red('✖')} ${m}`);
const info = (m) => console.log(`  ${m}`);

// ---------------------------------------------------------------- args
function parseArgs(argv) {
  const out = { dirs: [], force: false, help: false };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--help' || a === '-h') out.help = true;
    else if (a === '--force' || a === '-f') out.force = true;
    else if (a === '--dir' || a === '-d') {
      const v = argv[++i];
      if (!v) throw new Error('--dir requires a path');
      out.dirs.push(v);
    } else if (a.startsWith('--dir=')) {
      out.dirs.push(a.slice(6));
    } else {
      throw new Error(`Unknown argument: ${a}`);
    }
  }
  return out;
}

function printHelp() {
  console.log(`
${bold('clash-skill')} — Clash for Windows skill for AI assistants

${bold('Usage')}
  npx github:paranoiadd/clash-skill [options]

${bold('Options')}
  -d, --dir <path>   install into a specific skills directory (repeatable)
  -f, --force        overwrite existing clash-config.json
  -h, --help         show this help

${bold('Notes')}
  Without --dir, the installer looks for these directories and installs
  into every one it finds:
    ~/.workbuddy/skills    (WorkBuddy)
    ~/.claude/skills       (Claude Code)

  Requires Windows + PowerShell 5.1+ and Clash for Windows.
`);
}

// ---------------------------------------------------------------- targets
function detectSkillDirs() {
  const home = os.homedir();
  const candidates = [
    { name: 'WorkBuddy', dir: path.join(home, '.workbuddy', 'skills') },
    { name: 'Claude Code', dir: path.join(home, '.claude', 'skills') },
  ];
  return candidates.filter((c) => {
    try {
      return fs.statSync(c.dir).isDirectory();
    } catch {
      return false;
    }
  });
}

// ---------------------------------------------------------------- clash probe
function parseClashYaml() {
  const yamlPath = path.join(os.homedir(), '.config', 'clash', 'config.yaml');
  const result = { yamlPath, found: false, secret: '', port: 7890, apiBase: '' };
  try {
    const raw = fs.readFileSync(yamlPath, 'utf8');
    result.found = true;
    const secret = raw.match(/^\s*secret\s*:\s*['"]?([^\s'"]+)/m);
    const ctrl = raw.match(/^\s*external-controller\s*:\s*['"]?([^\s'"]+)/m);
    const port = raw.match(/^\s*mixed-port\s*:\s*(\d+)/m);
    if (secret) result.secret = secret[1];
    if (ctrl) result.apiBase = `http://${ctrl[1]}`;
    if (port) result.port = parseInt(port[1], 10);
  } catch {
    /* not installed */
  }
  return result;
}

function findGuiExe() {
  const candidates = [
    'C:\\Program Files\\Clash for Windows\\Clash for Windows.exe',
    'C:\\Program Files (x86)\\Clash for Windows\\Clash for Windows.exe',
    path.join(process.env.LOCALAPPDATA || '', 'Programs', 'Clash for Windows', 'Clash for Windows.exe'),
    path.join(process.env.LOCALAPPDATA || '', 'Clash for Windows', 'Clash for Windows.exe'),
  ];
  for (const p of candidates) {
    try {
      if (p && fs.statSync(p).isFile()) return p;
    } catch {
      /* keep looking */
    }
  }
  // Clash is often installed somewhere non-standard; if it is running we can
  // read the real path straight off the live process.
  return findGuiFromRunningProcess();
}

function findGuiFromRunningProcess() {
  if (process.platform !== 'win32') return '';
  try {
    const { execSync } = require('child_process');
    // -EncodedCommand avoids the quoting nightmare of nesting single/double
    // quotes through cmd.exe -> powershell.
    // The OutputEncoding line is essential: without it PowerShell emits GBK on a
    // Chinese Windows, so a non-ASCII install path comes back as mojibake and
    // fs.existsSync() rejects an otherwise valid path.
    const ps = "[Console]::OutputEncoding=[System.Text.Encoding]::UTF8; " +
               "(Get-Process -Name 'Clash for Windows' -ErrorAction SilentlyContinue | " +
               "Select-Object -First 1).Path";
    const encoded = Buffer.from(ps, 'utf16le').toString('base64');
    const out = execSync(
      `powershell -NoProfile -NonInteractive -EncodedCommand ${encoded}`,
      { encoding: 'utf8', timeout: 8000, windowsHide: true, stdio: ['ignore', 'pipe', 'ignore'] }
    ).trim();
    if (out && fs.existsSync(out)) return out;
  } catch {
    /* process not running or no PowerShell */
  }
  return '';
}

function buildConfig(probe) {
  return {
    _comment:
      'Generated by clash-skill installer. GuiExe is auto-detected; if Clash lives ' +
      'elsewhere, point it at your own path. The control port changes on every ' +
      'launch — clashctl.ps1 re-reads ~/.config/clash/config.yaml at runtime.',
    GuiExe: findGuiExe(),
    GuiProcess: 'Clash for Windows',
    CoreProcess: 'clash-win64',
    MixedPort: probe.port,
    ApiBase: probe.apiBase || 'http://127.0.0.1:9090',
    ApiSecret: probe.secret,
    MarkerFile: '%USERPROFILE%\\.config\\clash\\.agent-opened',
    DefaultUrl: 'https://github.com',
  };
}

// ---------------------------------------------------------------- install
function copyRecursive(src, dest) {
  const st = fs.statSync(src);
  if (st.isDirectory()) {
    fs.mkdirSync(dest, { recursive: true });
    for (const entry of fs.readdirSync(src)) {
      copyRecursive(path.join(src, entry), path.join(dest, entry));
    }
  } else {
    fs.mkdirSync(path.dirname(dest), { recursive: true });
    fs.copyFileSync(src, dest);
  }
}

function installInto(skillsDir, opts, probe) {
  const target = path.join(skillsDir, SKILL_NAME);
  fs.mkdirSync(target, { recursive: true });

  // Always refresh code and docs so re-running upgrades cleanly
  copyRecursive(path.join(PKG_ROOT, 'SKILL.md'), path.join(target, 'SKILL.md'));
  copyRecursive(path.join(PKG_ROOT, 'scripts'), path.join(target, 'scripts'));
  copyRecursive(
    path.join(PKG_ROOT, 'clash-config.example.json'),
    path.join(target, 'clash-config.example.json')
  );

  const cfgPath = path.join(target, 'clash-config.json');
  let created = false;
  if (!fs.existsSync(cfgPath) || opts.force) {
    fs.writeFileSync(cfgPath, JSON.stringify(buildConfig(probe), null, 2) + '\n', 'utf8');
    created = true;
  }
  return { target, created, cfgPath };
}

// ---------------------------------------------------------------- main
function main() {
  let opts;
  try {
    opts = parseArgs(process.argv.slice(2));
  } catch (e) {
    fail(e.message);
    printHelp();
    process.exit(1);
  }
  if (opts.help) return printHelp();

  console.log('');
  console.log(bold('  clash-skill') + dim(` installer v${require(path.join(PKG_ROOT, 'package.json')).version}`));
  console.log(dim('  Route only what needs a proxy; keep CN traffic direct.'));
  console.log('');

  if (process.platform !== 'win32') {
    warn('This skill targets Windows (Clash for Windows + PowerShell 5.1).');
    warn('Files will be installed, but the controller script will not run here.');
    console.log('');
  }

  const targets = opts.dirs.length
    ? opts.dirs.map((d) => ({ name: 'custom', dir: path.resolve(d) }))
    : detectSkillDirs();

  if (targets.length === 0) {
    fail('No skills directory found.');
    info('Create one, or pass --dir explicitly:');
    info(dim('  npx github:paranoiadd/clash-skill --dir ~/.workbuddy/skills'));
    process.exit(1);
  }

  const probe = parseClashYaml();
  console.log(bold('  Probing local Clash'));
  if (probe.found) {
    ok(`config.yaml found`);
    info(`secret     ${probe.secret ? dim(probe.secret.slice(0, 8) + '…') : yellow('empty')}`);
    info(`mixed-port ${probe.port}`);
    if (probe.apiBase) info(`api base   ${probe.apiBase} ${dim('(port changes per launch; read at runtime)')}`);
  } else {
    warn('~/.config/clash/config.yaml not found — is Clash for Windows installed and run once?');
  }
  const gui = findGuiExe();
  if (gui) ok(`GUI at ${gui}`);
  else warn('Clash executable not auto-detected; set GuiExe in clash-config.json manually');
  console.log('');

  console.log(bold('  Installing'));
  for (const t of targets) {
    const r = installInto(t.dir, opts, probe);
    ok(`${t.name.padEnd(12)} → ${r.target}`);
    if (r.created) info(dim('clash-config.json generated'));
    else info(dim('clash-config.json kept (use --force to overwrite)'));
  }
  console.log('');

  console.log(bold('  Next steps'));
  info(`1. ${cyan('Start Clash')} and make sure your subscription is loaded.`);
  info(`2. Ask your assistant to run ${cyan('clashctl.ps1 status')} to verify the link.`);
  info(`3. If Google/GitHub still stalls, check ${cyan('mode')} is ${cyan('rule')}, not ${cyan('global')}.`);
  console.log('');
  console.log(dim('  Docs: https://github.com/paranoiadd/clash-skill'));
  console.log('');
}

main();
