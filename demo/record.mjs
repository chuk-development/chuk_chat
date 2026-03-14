#!/usr/bin/env node
/**
 * Chuk Chat – Demo Video Recorder
 *
 * Records automated demo videos of the chat UI using Playwright.
 * The sidebar is collapsed by default so the full viewport = chat area.
 * The mouse cursor is hidden via CSS injection.
 *
 * ──────────────────────────────────────────────────────────────────────
 * Usage:
 *   node record.mjs login                  # Save auth state (interactive or automated)
 *   node record.mjs record <scenario>      # Record a single scenario
 *   node record.mjs all                    # Record every scenario
 *   node record.mjs calibrate              # Screenshot to verify coordinates
 *   node record.mjs list                   # List available scenarios
 *   node record.mjs help                   # Show help
 *
 * Environment variables:
 *   DEMO_URL            App URL          (default: http://localhost:8080)
 *   DEMO_EMAIL           Automated login email
 *   DEMO_PASSWORD        Automated login password
 *   DEMO_WIDTH           Viewport width  (default: 1280)
 *   DEMO_HEIGHT          Viewport height (default: 720)
 *   DEMO_TYPING_DELAY    Ms per keystroke (default: 35)
 *   DEMO_HEADED          "true" to show browser window
 * ──────────────────────────────────────────────────────────────────────
 */

import { chromium } from 'playwright';
import { mkdirSync, existsSync } from 'fs';
import { join, dirname } from 'path';
import { fileURLToPath } from 'url';
import { createInterface } from 'readline';

const __dirname = dirname(fileURLToPath(import.meta.url));

// ─── Configuration ───────────────────────────────────────────────────────────
const CONFIG = {
  appUrl:        process.env.DEMO_URL           || 'http://localhost:8080',
  viewport: {
    width:  parseInt(process.env.DEMO_WIDTH  || '1280', 10),
    height: parseInt(process.env.DEMO_HEIGHT || '720',  10),
  },
  typingDelay:   parseInt(process.env.DEMO_TYPING_DELAY || '35', 10),
  outputDir:     join(__dirname, 'recordings'),
  authStateFile: join(__dirname, '.auth-state.json'),
  headed:        process.env.DEMO_HEADED === 'true',
};

// Click targets (tuned for 1280 x 720 viewport).
// Run `node record.mjs calibrate` and adjust if your layout differs.
const COORDS = {
  // Login page – centered card (max-width 400px)
  loginEmail:    { x: 640, y: 330 },
  loginPassword: { x: 640, y: 395 },
  loginSubmit:   { x: 640, y: 465 },

  // Chat page
  // "New Chat" icon sits at top=72 left=8 (kTopInitialSpacing + kMenuButtonHeight + gap)
  newChatButton: { x: 28, y: 92 },
};

// ─── Demo Scenarios ──────────────────────────────────────────────────────────
// Each step:
//   { action: 'send',       text: '...', waitAfter: <ms> }
//   { action: 'wait',       duration: <ms> }
//   { action: 'newChat' }
//   { action: 'screenshot', name: 'label' }
//
// `waitAfter` is the pause AFTER the AI starts responding (so the streamed
// answer is visible in the recording).  Tune to your model's speed.

const SCENARIOS = {
  'hello': {
    name: 'Friendly Greeting',
    description: 'Basic hello and fun-fact conversation',
    steps: [
      { action: 'send', text: 'Hi there! Tell me a fun fact about the ocean.', waitAfter: 12_000 },
      { action: 'send', text: 'That is fascinating! What is the deepest point in the ocean?', waitAfter: 15_000 },
    ],
  },

  'code': {
    name: 'Coding Help',
    description: 'Python palindrome function + pytest tests',
    steps: [
      { action: 'send', text: 'Write a Python function that checks if a string is a valid palindrome, ignoring spaces and punctuation.', waitAfter: 20_000 },
      { action: 'send', text: 'Great! Now add comprehensive unit tests using pytest.', waitAfter: 20_000 },
    ],
  },

  'creative': {
    name: 'Creative Writing',
    description: 'Haiku poems about programming',
    steps: [
      { action: 'send', text: 'Write a short haiku about programming in the rain.', waitAfter: 10_000 },
      { action: 'send', text: 'Beautiful! Now write one about debugging at 3 am.', waitAfter: 10_000 },
    ],
  },
};

// ─── Low-level helpers ───────────────────────────────────────────────────────

/** Prompt user in the terminal and wait for an answer. */
function prompt(question) {
  const rl = createInterface({ input: process.stdin, output: process.stdout });
  return new Promise(resolve => {
    rl.question(question, answer => {
      rl.close();
      resolve(answer.trim());
    });
  });
}

/** Inject CSS to hide the mouse cursor on the entire page. */
async function hideCursor(page) {
  // Style tag approach (works after DOMContentLoaded)
  await page.addStyleTag({
    content: [
      '*, *::before, *::after { cursor: none !important; }',
      'canvas { cursor: none !important; }',
      'flt-glass-pane, flt-scene-host { cursor: none !important; }',
    ].join('\n'),
  });
}

/**
 * Install an init-script that continuously hides the cursor.
 * Flutter web occasionally resets inline styles on <canvas>,
 * so a MutationObserver keeps enforcing `cursor: none`.
 */
async function installCursorHider(page) {
  await page.addInitScript(() => {
    const STYLE_ID = '__demo_hide_cursor';

    function injectStyle() {
      if (document.getElementById(STYLE_ID)) return;
      const s = document.createElement('style');
      s.id = STYLE_ID;
      s.textContent = '*, *::before, *::after, canvas, flt-glass-pane, flt-scene-host { cursor: none !important; }';
      (document.head || document.documentElement).appendChild(s);
    }

    // Apply immediately and re-apply whenever the DOM changes.
    injectStyle();
    if (typeof MutationObserver !== 'undefined') {
      new MutationObserver(injectStyle).observe(document.documentElement, {
        childList: true, subtree: true,
      });
    }
  });
}

/** Move the mouse pointer far outside the visible viewport. */
async function parkMouse(page) {
  await page.mouse.move(-100, -100);
}

/** Click at an absolute pixel position on the page canvas. */
async function clickAt(page, x, y) {
  await page.mouse.click(x, y);
  await page.waitForTimeout(300);
}

/**
 * Type a chat message and press Enter to send.
 *
 * The chat TextField has `autofocus: true`, but we click the input
 * area anyway to guarantee focus (e.g. after switching chats).
 */
async function sendMessage(page, text, config) {
  const inputY = config.viewport.height - 100; // ~centre of input box
  await clickAt(page, config.viewport.width / 2, inputY);

  // Type character-by-character so it looks natural in the recording
  await page.keyboard.type(text, { delay: config.typingDelay });

  await page.waitForTimeout(200);
  await page.keyboard.press('Enter');

  // Hide the cursor again
  await parkMouse(page);
}

/** Wait until the Flutter app has rendered and network is quiet. */
async function waitForAppReady(page, extraMs = 3000) {
  await page.waitForLoadState('networkidle');
  await page.waitForTimeout(extraMs);
}

// ─── Login ───────────────────────────────────────────────────────────────────

/**
 * Interactive login: opens a headed browser window.
 * The user logs in manually and presses Enter in the terminal.
 */
async function interactiveLogin(config) {
  console.log('\n--- Interactive Login ---');
  console.log(`Opening browser at ${config.appUrl}`);
  console.log('Log in to the app, then come back here and press Enter.\n');

  const browser = await chromium.launch({ headless: false });
  const context = await browser.newContext({ viewport: config.viewport });
  const page    = await context.newPage();

  await page.goto(config.appUrl);
  await page.waitForLoadState('networkidle');

  await prompt('Press Enter after successful login... ');

  await context.storageState({ path: config.authStateFile });
  console.log(`Auth state saved to ${config.authStateFile}\n`);

  await context.close();
  await browser.close();
}

/**
 * Automated login using DEMO_EMAIL / DEMO_PASSWORD.
 * Clicks at coordinate positions on the Flutter-rendered login page.
 */
async function automatedLogin(config) {
  const email    = process.env.DEMO_EMAIL;
  const password = process.env.DEMO_PASSWORD;

  if (!email || !password) {
    throw new Error('Set DEMO_EMAIL and DEMO_PASSWORD for automated login.');
  }

  console.log(`\nAutomated login as ${email} ...`);

  const browser = await chromium.launch({ headless: true });
  const context = await browser.newContext({ viewport: config.viewport });
  const page    = await context.newPage();

  await page.goto(config.appUrl);
  await waitForAppReady(page, 4000);

  // Email field
  await clickAt(page, COORDS.loginEmail.x, COORDS.loginEmail.y);
  await page.keyboard.type(email, { delay: 15 });

  // Password field
  await clickAt(page, COORDS.loginPassword.x, COORDS.loginPassword.y);
  await page.keyboard.type(password, { delay: 15 });

  // Submit
  await clickAt(page, COORDS.loginSubmit.x, COORDS.loginSubmit.y);

  console.log('Waiting for authentication ...');
  await page.waitForTimeout(8000);

  await context.storageState({ path: config.authStateFile });
  console.log(`Auth state saved to ${config.authStateFile}\n`);

  await context.close();
  await browser.close();
}

// ─── Recording ───────────────────────────────────────────────────────────────

async function recordScenario(scenarioName, config) {
  const scenario = SCENARIOS[scenarioName];
  if (!scenario) {
    console.error(`Unknown scenario: "${scenarioName}"`);
    console.error(`Available: ${Object.keys(SCENARIOS).join(', ')}`);
    process.exit(1);
  }

  if (!existsSync(config.authStateFile)) {
    console.error('No auth state found. Run  node record.mjs login  first.');
    process.exit(1);
  }

  mkdirSync(config.outputDir, { recursive: true });

  console.log(`\nRecording: "${scenario.name}"`);
  console.log(`  Steps:    ${scenario.steps.length}`);
  console.log(`  Viewport: ${config.viewport.width}x${config.viewport.height}`);
  console.log(`  Output:   ${config.outputDir}\n`);

  const browser = await chromium.launch({ headless: !config.headed });
  const context = await browser.newContext({
    storageState: config.authStateFile,
    viewport:     config.viewport,
    recordVideo: {
      dir:  config.outputDir,
      size: config.viewport,
    },
  });

  const page = await context.newPage();

  // ── Hide cursor ──
  await installCursorHider(page);

  // ── Navigate & wait ──
  await page.goto(config.appUrl);
  await waitForAppReady(page, 4000);

  // Re-apply cursor hiding after Flutter finishes rendering
  await hideCursor(page);

  // ── Start with a fresh chat ──
  await clickAt(page, COORDS.newChatButton.x, COORDS.newChatButton.y);
  await page.waitForTimeout(1500);
  await parkMouse(page);

  // Brief pause so the "empty chat" state is visible
  await page.waitForTimeout(1000);

  // ── Execute steps ──
  for (let i = 0; i < scenario.steps.length; i++) {
    const step = scenario.steps[i];
    const label = step.text
      ? `"${step.text.length > 50 ? step.text.slice(0, 50) + '...' : step.text}"`
      : '';
    console.log(`  [${i + 1}/${scenario.steps.length}] ${step.action} ${label}`);

    switch (step.action) {
      case 'send':
        await sendMessage(page, step.text, config);
        await page.waitForTimeout(step.waitAfter ?? 10_000);
        break;

      case 'wait':
        await page.waitForTimeout(step.duration ?? 3000);
        break;

      case 'newChat':
        await clickAt(page, COORDS.newChatButton.x, COORDS.newChatButton.y);
        await page.waitForTimeout(2000);
        break;

      case 'screenshot': {
        const ssName = step.name || `step-${i + 1}`;
        const ssPath = join(config.outputDir, `${scenarioName}-${ssName}.png`);
        await page.screenshot({ path: ssPath });
        console.log(`    -> ${ssPath}`);
        break;
      }

      default:
        console.warn(`    Unknown action: ${step.action}`);
    }
  }

  // Final hold so the last response is fully visible
  await page.waitForTimeout(4000);

  // ── Save video ──
  const video = page.video();
  await context.close();

  if (video) {
    const videoPath = await video.path();
    console.log(`\nVideo saved: ${videoPath}`);
    console.log('Convert to MP4:');
    console.log(`  ffmpeg -i "${videoPath}" -c:v libx264 -crf 20 -preset fast output.mp4\n`);
  }

  await browser.close();
}

// ─── Calibrate ───────────────────────────────────────────────────────────────

async function calibrate(config) {
  mkdirSync(config.outputDir, { recursive: true });

  const hasAuth = existsSync(config.authStateFile);
  console.log(`\nCalibration screenshot (${config.viewport.width}x${config.viewport.height})`);
  console.log(hasAuth ? '  Using saved auth state.' : '  No auth state – will show login page.');

  const browser = await chromium.launch({ headless: true });
  const context = await browser.newContext({
    viewport: config.viewport,
    ...(hasAuth ? { storageState: config.authStateFile } : {}),
  });
  const page = await context.newPage();

  await page.goto(config.appUrl);
  await waitForAppReady(page, 5000);

  const ssPath = join(config.outputDir, 'calibration.png');
  await page.screenshot({ path: ssPath });
  console.log(`Screenshot: ${ssPath}`);
  console.log('Open it to verify / adjust the COORDS object in record.mjs.\n');

  await context.close();
  await browser.close();
}

// ─── Main ────────────────────────────────────────────────────────────────────

async function main() {
  const command = process.argv[2] || 'help';
  const arg     = process.argv[3];

  switch (command) {
    case 'login':
      if (process.env.DEMO_EMAIL && process.env.DEMO_PASSWORD) {
        await automatedLogin(CONFIG);
      } else {
        await interactiveLogin(CONFIG);
      }
      break;

    case 'record':
      await recordScenario(arg || 'hello', CONFIG);
      break;

    case 'all':
      for (const name of Object.keys(SCENARIOS)) {
        await recordScenario(name, CONFIG);
      }
      break;

    case 'calibrate':
      await calibrate(CONFIG);
      break;

    case 'list':
      console.log('\nAvailable scenarios:\n');
      for (const [key, s] of Object.entries(SCENARIOS)) {
        console.log(`  ${key.padEnd(15)} ${s.name} – ${s.description}`);
      }
      console.log('');
      break;

    case 'help':
    default:
      console.log(`
Chuk Chat Demo Recorder
=======================

Commands:
  node record.mjs login                Save auth state (interactive or env-based)
  node record.mjs record <scenario>    Record a single scenario (default: hello)
  node record.mjs all                  Record every scenario
  node record.mjs calibrate            Screenshot to verify click coordinates
  node record.mjs list                 List available scenarios

Environment variables:
  DEMO_URL            App URL            (default: http://localhost:8080)
  DEMO_EMAIL          Auto-login email
  DEMO_PASSWORD       Auto-login password
  DEMO_WIDTH          Viewport width     (default: 1280)
  DEMO_HEIGHT         Viewport height    (default: 720)
  DEMO_TYPING_DELAY   Ms per keystroke   (default: 35)
  DEMO_HEADED         "true" = show browser window

Workflow:
  1. Start the web app:  flutter run -d web-server --web-port=8080 --dart-define-from-file=.env
  2. Login once:         node record.mjs login
  3. Record demos:       node record.mjs record hello
  4. Convert video:      ffmpeg -i recordings/video.webm -c:v libx264 -crf 20 out.mp4
`);
      break;
  }
}

main().catch(err => {
  console.error('\nFatal:', err.message);
  process.exit(1);
});
