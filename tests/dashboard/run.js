// Drives the ccusage dashboard in a real browser against fixture data, and checks what it shows.
//
// Usage: node run.js [path-to-dashboard-assets]
//   default assets: ../../../ccusage/rust/crates/ccusage-dashboard/assets
//   CHROME=/path/to/chrome overrides the browser; SHOTS=1 keeps screenshots in ./out
//
// The expected numbers are computed here from the fixtures, not read back from the page, so a page that
// miscounts cannot agree with itself. Needs Chrome and `npm install` in this directory.

const fs = require('node:fs');
const http = require('node:http');
const path = require('node:path');
const puppeteer = require('puppeteer-core');

const ASSETS = path.resolve(
	process.argv[2] || path.join(__dirname, '../../../ccusage/rust/crates/ccusage-dashboard/assets'),
);
const CHROME = process.env.CHROME || '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
const OUT = path.join(__dirname, 'out');

/* ---------------------------------------------------------------- fixtures */

const AGENTS = ['claude', 'codex', 'gemini'];
const MODELS = ['model-a', 'model-b', 'model-c', 'model-d'];
const MACHINES = Array.from({ length: 10 }, (_, k) => `m${String(k + 1).padStart(2, '0')}`);
const DAY_COUNT = 30;
const LAST_DAY = '2026-10-10';

const shift = (date, days) => {
	const [y, m, d] = date.split('-').map(Number);
	return new Date(Date.UTC(y, m - 1, d + days)).toISOString().slice(0, 10);
};
const DATES = Array.from({ length: DAY_COUNT }, (_, n) => shift(LAST_DAY, n - (DAY_COUNT - 1)));

// One cell per machine per day. Machine k always uses the same agent and model, so every number can be
// worked out by hand: cost = (k + 1) + day/100, output = 100 * (k + 1), messages = k + 1.
const cellFor = (k, dayIndex) => ({
	machine: MACHINES[k],
	agent: AGENTS[k % AGENTS.length],
	i: 40,
	m: MODELS[k % MODELS.length],
	in: 10,
	out: 100 * (k + 1),
	cw: 0,
	cr: 0,
	cost: k + 1 + dayIndex / 100,
	msgs: k + 1,
});

const daily = { schema: 1, generatedAt: `${LAST_DAY}T12:00:00Z`, anomalies: [], days: {} };
DATES.forEach((date, dayIndex) => {
	daily.days[date] = MACHINES.map((_, k) => cellFor(k, dayIndex));
});

const now = Date.parse(`${LAST_DAY}T12:00:00Z`);
const machines = {
	schema: 1,
	generatedAt: `${LAST_DAY}T12:00:00Z`,
	retiredAfterDays: 14,
	machines: MACHINES.map((id, k) => ({
		id,
		label: `sandbox-${String(k + 1).padStart(2, '0')}`,
		lastSyncAt: new Date(now - (k >= 8 ? 30 : 0) * 86400000 - 60000).toISOString(),
		retired: k >= 8,
	})),
};

// Sessions: every machine has two, in its own project. Machine 10 hashes its project name.
const sessions = {
	schema: 1,
	generatedAt: machines.generatedAt,
	total: MACHINES.length * 2,
	truncated: false,
	sessions: MACHINES.flatMap((id, k) =>
		[0, 1].map((n) => ({
			machine: id,
			agent: AGENTS[k % AGENTS.length],
			id: `session-${id}-${n}`,
			project: k === 9 ? 'sha256:0123456789abcdef0123456789abcdef' : `/work/team${k % 3}/app-${k}`,
			first: Date.parse(`${DATES[28 - n]}T10:00:00Z`),
			last: Date.parse(`${DATES[28 - n]}T11:00:00Z`),
			cost: (k + 1) * (n + 1),
			days: 1,
		})),
	),
};

const sum = (items, pick) => items.reduce((total, item) => total + pick(item), 0);
const allCells = DATES.flatMap((date, dayIndex) => MACHINES.map((_, k) => ({ date, k, cell: cellFor(k, dayIndex) })));
const expected = (keep) => {
	const picked = allCells.filter(keep);
	return {
		cost: sum(picked, (item) => item.cell.cost),
		days: new Set(picked.map((item) => item.date)).size,
		messages: sum(picked, (item) => item.cell.msgs),
	};
};
const money = (value) => (value >= 1000 ? `$${value.toFixed(0)}` : `$${value.toFixed(2)}`);

/* ------------------------------------------------------------------ server */

function serve() {
	const types = { '.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css', '.json': 'application/json' };
	const data = { daily, machines, sessions, weekly: { periods: [] }, monthly: { periods: [] }, models: {} };
	const root = { 'pricing.json': { models: {}, attribution: '' }, 'model-equivalence.json': { tiers: [], providers: [] } };
	const server = http.createServer((request, response) => {
		const url = new URL(request.url, 'http://localhost');
		const name = url.pathname.replace(/^\//, '') || 'index.html';
		const match = name.match(/^data\/(\w+)\.json$/);
		if (match && data[match[1]]) {
			response.writeHead(200, { 'Content-Type': 'application/json' });
			return response.end(JSON.stringify(data[match[1]]));
		}
		if (root[name]) {
			response.writeHead(200, { 'Content-Type': 'application/json' });
			return response.end(JSON.stringify(root[name]));
		}
		const file = path.join(ASSETS, name);
		if (file.startsWith(ASSETS) && fs.existsSync(file) && fs.statSync(file).isFile()) {
			response.writeHead(200, { 'Content-Type': types[path.extname(file)] || 'text/plain' });
			return response.end(fs.readFileSync(file));
		}
		response.writeHead(404);
		response.end('not found');
	});
	return new Promise((resolve) => server.listen(0, '127.0.0.1', () => resolve(server)));
}

/* ------------------------------------------------------------------- tests */

let failures = 0;
const check = (description, ok, detail = '') => {
	console.log(`  ${ok ? 'ok  ' : 'FAIL'}  ${description}${!ok && detail ? `  (${detail})` : ''}`);
	if (!ok) failures += 1;
};
const section = (title) => console.log(`\n== ${title}`);

async function open(browser, base, query = '', { width = 1300, height = 900, scheme = 'dark' } = {}) {
	const page = await browser.newPage();
	await page.setViewport({ width, height });
	await page.emulateMediaFeatures([{ name: 'prefers-color-scheme', value: scheme }]);
	const errors = [];
	page.on('pageerror', (error) => errors.push(error.message));
	page.on('console', (message) => {
		// Browsers ask for a favicon the dashboard has never had.
		if (message.type() === 'error' && !message.location().url?.endsWith('/favicon.ico')) errors.push(message.text());
	});
	await page.goto(`${base}/${query}`, { waitUntil: 'networkidle0' });
	await page.waitForSelector('#app:not([hidden])', { timeout: 10000 });
	page.errors = errors;
	return page;
}

const text = (page, selector) => page.$eval(selector, (node) => node.textContent.trim());
const count = (page, selector) => page.$$eval(selector, (nodes) => nodes.length);
const tiles = (page) =>
	page.$$eval('#totals .tile', (nodes) =>
		Object.fromEntries(
			nodes.map((node) => [node.querySelector('.label').textContent.trim(), node.querySelector('.value').textContent.trim()]),
		),
	);
const shot = async (page, name, { fullPage = true } = {}) => {
	if (process.env.SHOTS) {
		fs.mkdirSync(OUT, { recursive: true });
		await page.screenshot({ path: path.join(OUT, `${name}.png`), fullPage });
	}
};

async function main() {
	const server = await serve();
	const base = `http://127.0.0.1:${server.address().port}`;
	const browser = await puppeteer.launch({
		executablePath: CHROME,
		headless: true,
		args: ['--no-sandbox'],
		env: { ...process.env, TZ: 'UTC' },
	});

	try {
		section('unfiltered: everything adds up');
		let page = await open(browser, base);
		const all = expected(() => true);
		let t = await tiles(page);
		check(`spend is ${money(all.cost)}`, t.Spend === money(all.cost), t.Spend);
		check(`${all.days} days with usage`, t['Days with usage'] === String(all.days), t['Days with usage']);
		check('one bar group per day', (await count(page, '#series .day')) === DAY_COUNT);
		check('no legend while the chart is one series', await page.$eval('#legend', (node) => node.hidden));
		check('all ten sandboxes are listed, by label', (await count(page, '#machines tbody tr')) === 10 && (await text(page, '#machines tbody')).includes('sandbox-10'));
		check('a retired sandbox says so', (await text(page, '#machines tbody')).includes('retired'));
		check('three agents', (await count(page, '#agents tbody tr')) === 3);
		check('four models', (await count(page, '#models tbody tr')) === 4);
		check('the Projects and Sessions panels appear', !(await page.$eval('#sessions-panel', (n) => n.hidden)) && !(await page.$eval('#projects-panel', (n) => n.hidden)));
		check('hashed projects are labelled as hashed', (await text(page, '#projects')).includes('hashed 01234567'));
		check('no script errors', page.errors.length === 0, page.errors.join('; '));
		await shot(page, 'unfiltered');
		await page.close();

		section('stacking: eight colours, the rest folded into Other, fixed by rank');
		page = await open(browser, base, '?stack=machine');
		const legend = await page.$$eval('#legend .legend-item', (nodes) =>
			nodes.map((node) => ({ label: node.textContent.trim(), colour: node.querySelector('.swatch').getAttribute('style') })),
		);
		check('nine legend entries: eight sandboxes and Other', legend.length === 9, String(legend.length));
		check('the last is Other, in the neutral', legend.at(-1)?.label === 'Other' && legend.at(-1).colour.includes('--series-other'));
		check('the top spender is series 1', legend[0].label === 'sandbox-10' && legend[0].colour.includes('--series-1)'), JSON.stringify(legend[0]));
		check('colours are the eight slots in order', legend.slice(0, 8).every((entry, n) => entry.colour.includes(`--series-${n + 1})`)));
		const before = Object.fromEntries(legend.map((entry) => [entry.label, entry.colour]));
		await shot(page, 'stacked-by-sandbox');
		await page.close();

		page = await open(browser, base, '?stack=machine&agent=claude');
		const filtered = await page.$$eval('#legend .legend-item', (nodes) =>
			nodes.map((node) => ({ label: node.textContent.trim(), colour: node.querySelector('.swatch').getAttribute('style') })),
		);
		check(
			'filtering does not repaint the survivors',
			filtered.length > 0 && filtered.every((entry) => entry.label === 'Other' || before[entry.label] === entry.colour),
			JSON.stringify(filtered.map((entry) => `${entry.label}:${entry.colour}`)),
		);
		await page.close();

		page = await open(browser, base, '?stack=agent');
		check('three agents need three legend entries and no Other', (await count(page, '#legend .legend-item')) === 3);
		await page.close();

		section('URL filters slice every panel the same way');
		for (const [query, keep, label] of [
			['?machine=m03', (item) => item.k === 2, 'one sandbox'],
			['?agent=codex', (item) => item.k % 3 === 1, 'one agent'],
			['?model=model-d', (item) => item.k % 4 === 3, 'one model'],
			['?from=2026-10-04&to=2026-10-10', (item) => item.date >= '2026-10-04', 'a date range'],
			['?agent=claude&model=model-a', (item) => item.k % 3 === 0 && item.k % 4 === 0, 'agent and model together'],
		]) {
			page = await open(browser, base, query);
			const want = expected(keep);
			t = await tiles(page);
			check(`${label}: spend ${money(want.cost)}`, t.Spend === money(want.cost), t.Spend);
			check(`${label}: ${want.days} days`, t['Days with usage'] === String(want.days), t['Days with usage']);
			check(`${label}: ${want.days} bars`, (await count(page, '#series .day')) === want.days);
			check(`${label}: the Reset button is offered`, !(await page.$eval('.reset', (node) => node.hidden)));
			await page.close();
		}

		section('drill-down by clicking');
		page = await open(browser, base);
		await page.click('#machines tbody tr:nth-child(1)');
		const topName = await page.$eval('#machines tbody tr', (row) => row.querySelector('div').firstChild.textContent.trim());
		t = await tiles(page);
		check('clicking a sandbox narrows everything to it', (await count(page, '#machines tbody tr')) === 1 || t.Spend !== money(all.cost), t.Spend);
		check('the URL records it', new URL(page.url()).searchParams.get('machine') !== null, page.url());
		check('the sandbox filter shows it', (await page.$eval('select[aria-label="Sandbox"]', (node) => node.selectedOptions[0].textContent)) === topName);
		await page.click('#machines tbody tr.picked');
		t = await tiles(page);
		check('clicking it again clears it', t.Spend === money(all.cost) && !new URL(page.url()).searchParams.has('machine'));
		await page.click('#agents tbody tr:nth-child(1)');
		check('an agent row is a filter too', new URL(page.url()).searchParams.has('agent'));
		await page.click('.reset');
		check('Reset clears everything', (await tiles(page)).Spend === money(all.cost) && new URL(page.url()).search === '');
		await page.focus('#models tbody tr:nth-child(2)');
		await page.keyboard.press('Enter');
		check('Enter on a focused row filters too', new URL(page.url()).searchParams.has('model'));
		await page.close();

		section('presets and the date range');
		page = await open(browser, base);
		await page.$$eval('.preset', (nodes) => nodes.find((node) => node.textContent === '7 days').click());
		const week = expected((item) => item.date >= shift(LAST_DAY, -6));
		t = await tiles(page);
		check('7 days counts back from the latest day with data', t['Days with usage'] === '7' && t.Spend === money(week.cost), `${t['Days with usage']} ${t.Spend}`);
		check('weeks are rebuilt from the days shown', (await text(page, '#weekly')).includes('2026-W'));
		await page.$$eval('.preset', (nodes) => nodes.find((node) => node.textContent === 'All time').click());
		check('All time clears the range', (await tiles(page))['Days with usage'] === String(DAY_COUNT));
		await page.close();

		section('the legend is a filter');
		page = await open(browser, base, '?stack=machine');
		check('Other cannot be clicked', await page.$eval('#legend .legend-item:last-child', (node) => node.disabled && node.textContent.trim() === 'Other'));
		await page.click('#legend .legend-item:nth-child(2)');
		check('clicking a legend entry filters to it', new URL(page.url()).searchParams.get('machine') !== null);
		await page.close();

		section('tooltip: hover and keyboard');
		page = await open(browser, base, '?stack=machine');
		const hit = await page.$('#series g.day:nth-of-type(10) .hit');
		const box = await hit.boundingBox();
		await page.mouse.move(box.x + box.width / 2, box.y + box.height / 2);
		check('hovering a day shows the tooltip', !(await page.$eval('.tip', (node) => node.hidden)));
		const tipText = await text(page, '.tip');
		check('it names the day and the total', tipText.includes(DATES[9]) && tipText.includes('total'), tipText);
		const rows = await page.$$eval('.tip .tip-row', (nodes) => nodes.map((node) => node.textContent));
		check('it lists the sandboxes by label', rows.some((row) => row.includes('sandbox-10')));
		await page.mouse.move(5, 5);
		check('moving away hides it', await page.$eval('.tip', (node) => node.hidden));
		await page.$eval('#series g.day:nth-of-type(5) .hit', (node) => node.focus());
		check('keyboard focus shows it too', !(await page.$eval('.tip', (node) => node.hidden)));
		await shot(page, 'tooltip', { fullPage: false });
		await page.close();

		section('table view');
		page = await open(browser, base, '?stack=agent');
		await page.$$eval('.panel-controls .preset', (nodes) => nodes[0].click());
		check('the chart becomes a table of the same numbers', (await count(page, '#series table')) === 1 && (await count(page, '#series svg')) === 0);
		const headers = await page.$$eval('#series th', (nodes) => nodes.map((node) => node.textContent));
		const agentCost = (name) => sum(allCells.filter((item) => AGENTS[item.k % 3] === name), (item) => item.cell.cost);
		const byRank = [...AGENTS].sort((left, right) => agentCost(right) - agentCost(left));
		check('with a column per stack, in rank order, and a total', headers.join(',') === `Date,${byRank.join(',')},Total`, headers.join(','));
		await page.close();

		section('sessions and projects');
		page = await open(browser, base);
		check('every session is listed', (await count(page, '#sessions tbody tr')) === sessions.sessions.length);
		await page.click('#projects tbody tr:nth-child(1)');
		check('clicking a project narrows the sessions', (await count(page, '#sessions tbody tr')) < sessions.sessions.length && (await count(page, '.chip')) === 1);
		await page.click('.chip');
		check('the chip clears it', (await count(page, '#sessions tbody tr')) === sessions.sessions.length);
		await page.goto(`${base}/?machine=m02`, { waitUntil: 'networkidle0' });
		check('the sandbox filter scopes sessions', (await count(page, '#sessions tbody tr')) === 2);
		await page.goto(`${base}/?model=model-a`, { waitUntil: 'networkidle0' });
		check('the model filter is said not to apply to sessions', (await text(page, '#sessions-note')).includes('model filter does not apply'));
		await page.close();

		section('a store with no sessions file still works');
		const kept = sessions.sessions.splice(0);
		server.close();
		const bare = await serveWithout('sessions');
		page = await open(browser, `http://127.0.0.1:${bare.address().port}`);
		check('the dashboard loads', (await tiles(page)).Spend === money(all.cost));
		check('the sessions panels stay hidden', await page.$eval('#sessions-panel', (node) => node.hidden));
		await page.close();
		bare.close();
		sessions.sessions.push(...kept);

		section('themes and a narrow screen (screenshots only)');
		const again = await serve();
		const again_base = `http://127.0.0.1:${again.address().port}`;
		for (const [name, scheme, width] of [
			['light', 'light', 1300],
			['dark', 'dark', 1300],
			['narrow', 'dark', 420],
		]) {
			page = await open(browser, again_base, '?stack=machine', { scheme, width });
			check(`${name}: renders without script errors`, page.errors.length === 0, page.errors.join('; '));
			const wide = await page.evaluate(() =>
				[...document.querySelectorAll('body *')]
					.filter((node) => node.getBoundingClientRect().right > window.innerWidth + 1 && !node.closest('.table-scroll'))
					.slice(0, 6)
					.map((node) => `${node.tagName.toLowerCase()}${node.id ? '#' + node.id : ''}.${node.className && node.className.baseVal === undefined ? node.className : ''} right=${Math.round(node.getBoundingClientRect().right)}`),
			);
			check(`${name}: nothing makes the page scroll sideways`, await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth + 1), wide.join(' | '));
			await shot(page, `theme-${name}`, { fullPage: false });
			await page.close();
		}
		again.close();
	} finally {
		await browser.close();
	}

	console.log(failures === 0 ? '\nPASS' : `\nFAIL (${failures})`);
	process.exit(failures === 0 ? 0 : 1);
}

async function serveWithout(name) {
	const original = sessions.sessions.slice();
	const server = http.createServer((request, response) => {
		const url = new URL(request.url, 'http://localhost');
		const pathname = url.pathname.replace(/^\//, '') || 'index.html';
		if (pathname === `data/${name}.json`) {
			response.writeHead(404);
			return response.end();
		}
		const known = { daily, machines, weekly: { periods: [] }, monthly: { periods: [] }, models: {} };
		if (pathname === 'pricing.json' || pathname === 'model-equivalence.json') {
			response.writeHead(200, { 'Content-Type': 'application/json' });
			return response.end(pathname === 'pricing.json' ? '{"models":{},"attribution":""}' : '{"tiers":[],"providers":[]}');
		}
		const match = pathname.match(/^data\/(\w+)\.json$/);
		if (match && known[match[1]]) {
			response.writeHead(200, { 'Content-Type': 'application/json' });
			return response.end(JSON.stringify(known[match[1]]));
		}
		const file = path.join(ASSETS, pathname);
		if (fs.existsSync(file) && fs.statSync(file).isFile()) {
			const types = { '.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css' };
			response.writeHead(200, { 'Content-Type': types[path.extname(file)] || 'text/plain' });
			return response.end(fs.readFileSync(file));
		}
		response.writeHead(404);
		response.end();
	});
	void original;
	return new Promise((resolve) => server.listen(0, '127.0.0.1', () => resolve(server)));
}

main().catch((error) => {
	console.error(error);
	process.exit(2);
});
