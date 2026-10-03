#!/data/data/com.termux/files/usr/bin/node
// gosync.js - copy new photos and videos from a USB-connected GoPro into
// DCIM/Camera, then run gosane.sh to convert the videos.
//
// Talks to the camera over its Open GoPro HTTP API on the USB network link
// (camera USB mode: GoPro Connect). Remembers what it has copied in
// ~/.gosync/copied.tsv, so each run copies only new files.
//
// Usage: gosync.js [-n]
//   -n   dry run: list what would be copied

'use strict';
const fs = require('fs');
const os = require('os');
const path = require('path');
const { execFileSync, spawnSync } = require('child_process');

const STORAGE = '/storage/emulated/0';
const OUT_DIR = `${STORAGE}/DCIM/Camera`;
const ARCHIVE = `${STORAGE}/DCIM/GoPro-HEVC`;   // where gosane.sh moves HEVC originals
const HOME = os.homedir();
const STATE_DIR = `${HOME}/.gosync`;
const LEDGER = `${STATE_DIR}/copied.tsv`;
const LOCK = `${STATE_DIR}/lock`;
const LOG = `${HOME}/gosync.log`;
const GOSANE = `${HOME}/.local/bin/gosane.sh`;
const SPARE_BYTES = 2e9;            // free space to leave beyond the copy itself
const SANE_CLOCK = Date.UTC(2020, 0, 1) / 1000;  // earlier = camera clock was wrong

const dry = process.argv.includes('-n');
for (const a of process.argv.slice(2))
    if (a !== '-n') die(`unknown argument: ${a}\nUsage: gosync.js [-n]`);

function die(msg) { console.error(`gosync: ${msg}`); process.exit(1); }

function log(msg) {
    const line = `${new Date().toLocaleString('sv')} ${msg}`;  // sv = YYYY-MM-DD HH:MM:SS
    console.log(line);
    fs.appendFileSync(LOG, line + '\n');
}

const mb = n => `${(n / 1e6).toFixed(1)} MB`;

// --- Preflight ---------------------------------------------------------------

try { fs.accessSync(OUT_DIR, fs.constants.W_OK); } catch {
    die(`can't write to ${OUT_DIR}.
  Run termux-setup-storage and allow file access, or turn on Termux's
  Files/Storage permission in Android Settings > Apps > Termux > Permissions.`);
}
if (spawnSync('curl', ['--version']).error) die('curl not found. Install it with: pkg install curl');

fs.mkdirSync(STATE_DIR, { recursive: true });
try {
    fs.writeFileSync(LOCK, String(process.pid), { flag: 'wx' });
} catch {
    const pid = Number(fs.readFileSync(LOCK, 'utf8'));
    let alive = false;
    try { process.kill(pid, 0); alive = true; } catch {}
    if (alive) die(`already running (pid ${pid})`);
    fs.writeFileSync(LOCK, String(process.pid));   // stale lock from a crashed run
}
process.on('exit', () => { try { fs.unlinkSync(LOCK); } catch {} });
process.on('SIGINT', () => process.exit(130));
process.on('SIGTERM', () => process.exit(143));

// --- Find the camera ---------------------------------------------------------

// Over USB the camera is 172.2X.1YZ.51 (XYZ = last serial digits) and the
// phone gets another address in the same /24. Android routes app traffic over
// Wi-Fi unless the socket is bound to the USB interface, hence curl --interface.
let iface, base;
for (const [name, addrs] of Object.entries(os.networkInterfaces())) {
    const a = addrs.find(a => a.family === 'IPv4' && /^172\.2\d\.1\d\d\.\d+$/.test(a.address));
    if (a) { iface = name; base = `http://${a.address.replace(/\d+$/, '51')}:8080`; break; }
}
if (!iface) die(`no GoPro found on USB.
  Plug the camera into the phone and turn it on. If it still isn't found, set
  the camera's USB mode to GoPro Connect (Preferences > Connections > USB Connection).`);

function api(urlPath, timeout = 15000) {
    return execFileSync('curl', ['-sS', '--fail', '-m', String(timeout / 1000),
        '--interface', iface, base + urlPath], { encoding: 'utf8', maxBuffer: 64e6 });
}

let info;
try { info = JSON.parse(api('/gopro/camera/info', 5000)); } catch {
    die(`found a USB network on ${iface} but no GoPro answered at ${base}.
  Make sure the camera is on and not asleep, then try again.`);
}
log(`camera: ${info.model_name} (firmware ${info.firmware_version}) on ${iface}`);

// --- Work out what's new -----------------------------------------------------

const key = f => `${f.n}\t${f.cre}\t${f.s}`;
const copied = new Set(fs.existsSync(LEDGER) ? fs.readFileSync(LEDGER, 'utf8').split('\n').filter(Boolean) : []);
const record = f => { copied.add(key(f)); fs.appendFileSync(LEDGER, key(f) + '\n'); };

const list = JSON.parse(api('/gopro/media/list', 60000));
const media = list.media.flatMap(d => d.fs.map(f => ({ ...f, dir: d.d, s: Number(f.s), cre: Number(f.cre) })))
    .filter(f => /\.(mp4|jpg)$/i.test(f.n))          // skip .LRV/.THM previews and anything else
    .sort((a, b) => a.cre - b.cre);

const size = p => { try { return fs.statSync(p).size; } catch { return -1; } };

const todo = [];
for (const f of media) {
    if (copied.has(key(f))) continue;
    // Already on the phone from some other route (e.g. Quik)? Then just note it.
    if (size(`${OUT_DIR}/${f.n}`) === f.s || size(`${ARCHIVE}/${f.n}`) === f.s) {
        if (!dry) record(f);
        continue;
    }
    // Same name but different file: GoPro numbering restarted (e.g. card format).
    let dest = f.n;
    if (size(`${OUT_DIR}/${f.n}`) >= 0 || size(`${ARCHIVE}/${f.n}`) >= 0) {
        const ext = path.extname(f.n);
        dest = `${path.basename(f.n, ext)}_${f.cre}${ext}`;
    }
    todo.push({ ...f, dest });
}

const total = todo.reduce((n, f) => n + f.s, 0);
log(`${media.length} files on camera, ${todo.length} new (${mb(total)})`);
if (dry) {
    for (const f of todo) console.log(`would copy ${f.dir}/${f.n} -> ${OUT_DIR}/${f.dest}`);
    process.exit(0);
}

const { bavail, bsize } = fs.statfsSync(OUT_DIR);
if (bavail * bsize < total + SPARE_BYTES)
    die(`not enough space: need ${mb(total + SPARE_BYTES)}, have ${mb(bavail * bsize)} free.`);

// --- Copy ----------------------------------------------------------------

// The camera reports capture times as local wall-clock time dressed up as UTC.
const cameraTime = cre => {
    const d = new Date(cre * 1000);
    return new Date(d.getUTCFullYear(), d.getUTCMonth(), d.getUTCDate(),
        d.getUTCHours(), d.getUTCMinutes(), d.getUTCSeconds());
};

// Rewrite the EXIF date strings of a JPG in place. They're fixed-length
// "YYYY:MM:DD HH:MM:SS", so nothing else in the file moves.
function setJpegDate(file, when) {
    const p = n => String(n).padStart(2, '0');
    const stamp = `${when.getFullYear()}:${p(when.getMonth() + 1)}:${p(when.getDate())} ` +
        `${p(when.getHours())}:${p(when.getMinutes())}:${p(when.getSeconds())}`;
    const fd = fs.openSync(file, 'r+');
    try {
        const head = Buffer.alloc(131072);
        const len = fs.readSync(fd, head, 0, head.length, 0);
        for (let i = 2; i + 4 <= len && head[i] === 0xff;) {   // walk JPEG segments
            const marker = head[i + 1], segLen = head.readUInt16BE(i + 2);
            if (marker === 0xe1 && head.toString('latin1', i + 4, i + 10) === 'Exif\0\0') {
                const end = Math.min(i + 2 + segLen, len);
                const seg = head.toString('latin1', i, end)
                    .replace(/\d{4}:\d\d:\d\d \d\d:\d\d:\d\d/g, stamp);
                fs.writeSync(fd, Buffer.from(seg, 'latin1'), 0, end - i, i);
                return true;
            }
            if (marker === 0xda) break;                       // image data: no EXIF found
            i += 2 + segLen;
        }
        return false;
    } finally { fs.closeSync(fd); }
}

let done = 0, failed = 0, tmp = null;
process.on('exit', () => { if (tmp) try { fs.unlinkSync(tmp); } catch {} });
const runStart = new Date();

for (const [i, f] of todo.entries()) {
    try { api('/gopro/camera/keep_alive', 5000); } catch {}   // stop the camera dozing off
    const dest = `${OUT_DIR}/${f.dest}`;
    tmp = `${OUT_DIR}/.${f.dest}.part`;
    const t0 = Date.now();
    // --speed-time: give up if the transfer stalls for 30s (camera switched off).
    const r = spawnSync('curl', ['-sS', '--fail', '-m', '1800', '--speed-limit', '1', '--speed-time', '30',
        '--interface', iface, '-o', tmp, `${base}/videos/DCIM/${f.dir}/${f.n}`],
        { stdio: ['ignore', 'inherit', 'inherit'] });
    if (r.status !== 0 || size(tmp) !== f.s) {
        log(`FAIL ${f.n}: download ${r.status !== 0 ? `error (curl exit ${r.status})` : `size ${size(tmp)} != ${f.s}`}`);
        try { fs.unlinkSync(tmp); } catch {}
        tmp = null; failed++;
        // Camera unplugged or switched off? Then every remaining file would fail too.
        let gone = false;
        try { api('/gopro/camera/info', 5000); } catch { gone = true; }
        if (gone) {
            log(`camera stopped answering; ${todo.length - i - 1} files not tried. ` +
                `Plug it back in, turn it on, and run gosync again to resume.`);
            break;
        }
        continue;
    }

    // Camera clock was wrong (2016): date it by when we copied it instead.
    let when = cameraTime(f.cre), note = '';
    if (f.cre < SANE_CLOCK) {
        when = runStart;
        note = ', bad camera date -> copy time';
        if (/\.jpg$/i.test(f.n) && !setJpegDate(tmp, when)) note += ' (no EXIF found)';
    }
    fs.utimesSync(tmp, when, when);
    fs.renameSync(tmp, dest);
    tmp = null;
    record(f);
    done++;
    const secs = (Date.now() - t0) / 1000;
    log(`[${i + 1}/${todo.length}] ${f.n}${f.dest !== f.n ? ` -> ${f.dest}` : ''}, ` +
        `${mb(f.s)} in ${secs.toFixed(1)}s${note}`);
}

log(`copied ${done}, failed ${failed}`);

// --- Convert -------------------------------------------------------------

// Copied files carry their capture time, so gosane's "still syncing" check
// would wrongly hold back the ones just dated to now; turn it off.
const r = spawnSync(GOSANE, [], { stdio: 'inherit', env: { ...process.env, GOSANE_SETTLE_SECS: '0' } });
process.exitCode = failed || r.status ? 1 : 0;
