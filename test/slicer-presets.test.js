'use strict';
/**
 * Presets for slicing a bare model with an Orca/Bambu fork (#1778). Each case is a shape met on
 * a real install while building this (Snapmaker Orca, OrcaSlicer, Bambu Studio on macOS).
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const P = require('../lib/slicer-presets');
const S = require('../lib/slicers');

/** An in-memory profile tree: { 'a/b/c.json': {...} }. */
function memIo(files) {
  const tree = {};
  for (const [p, v] of Object.entries(files)) tree[p] = typeof v === 'string' ? v : JSON.stringify(v);
  return {
    readText: (p) => { if (!(p in tree)) throw new Error('ENOENT'); return tree[p]; },
    isFile: (p) => p in tree,
    listDir: (dir) => {
      const pre = dir + '/';
      const out = new Set();
      for (const p of Object.keys(tree)) if (p.startsWith(pre)) out.add(p.slice(pre.length).split('/')[0]);
      if (!out.size) throw new Error('ENOENT');
      return [...out];
    },
    join: (...xs) => xs.join('/'),
  };
}
const roots = (conf) => ({ conf, user: 'cfg/user', system: 'cfg/system', bundled: 'app/profiles' });
const CONF = (presets) => JSON.stringify({ app: {}, presets }) + '\n# MD5 checksum 0123456789ABCDEF\n';

test('the printer the slicer last used, with a process and filament it accepts (Bambu records all three)', () => {
  const io = memIo({
    'app/profiles/BBL/machine/fdm_machine_common.json': { gcode_flavor: 'marlin', nozzle_diameter: ['0.4'] },
    'app/profiles/BBL/machine/Bambu Lab H2D 0.4 nozzle.json': { inherits: 'fdm_machine_common', printer_model: 'Bambu Lab H2D', default_print_profile: '0.20mm Standard @BBL H2D' },
    'app/profiles/BBL/process/0.20mm Standard @BBL H2D.json': { layer_height: '0.2', compatible_printers: ['Bambu Lab H2D 0.4 nozzle'] },
    'app/profiles/BBL/filament/Bambu PLA Basic @BBL H2D.json': { filament_type: ['PLA'], compatible_printers: ['Bambu Lab H2D 0.4 nozzle'] },
  });
  const r = P.choosePresets(io, roots(CONF({ machine: 'Bambu Lab H2D 0.4 nozzle', process: '0.20mm Standard @BBL H2D',
    filaments: '["Bambu PLA Basic @BBL H2D", "Bambu PLA Basic @BBL H2D"]' })));
  assert.equal(r.ok, true);
  assert.equal(r.machine.name, 'Bambu Lab H2D 0.4 nozzle');
  assert.equal(r.machine.gcode_flavor, 'marlin', 'flattened along inherits');
  assert.ok(!('inherits' in r.machine));
  assert.equal(r.process.name, '0.20mm Standard @BBL H2D');
  assert.equal(r.filament.name, 'Bambu PLA Basic @BBL H2D');
});

test('a default_print_profile that is not a real file falls back to a compatible 0.20mm Standard (Snapmaker U1)', () => {
  const U1 = 'Snapmaker U1 (0.4 nozzle)';
  const io = memIo({
    [`app/profiles/Snapmaker/machine/${U1}.json`]: { default_print_profile: '0.20 Standard @Snapmaker U1 (0.4 nozzle)', default_filament_profile: ['Snapmaker PLA'] },
    'app/profiles/Snapmaker/process/0.08mm Standard @Snapmaker U1 (0.4 nozzle).json': { compatible_printers: [U1] },
    'app/profiles/Snapmaker/process/0.20mm Standard @Snapmaker U1 (0.4 nozzle).json': { compatible_printers: [U1] },
    'app/profiles/Snapmaker/process/0.20mm Standard @Snapmaker U1 (0.2 nozzle).json': { compatible_printers: ['Snapmaker U1 (0.2 nozzle)'] },
    // The declared default filament exists but does not list the U1; the U1's own are "@U1", not "@Snapmaker U1".
    'app/profiles/Snapmaker/filament/Snapmaker PLA.json': { compatible_printers: ['Snapmaker A250 (0.4 nozzle)'] },
    'app/profiles/Snapmaker/filament/Generic PLA @U1 base.json': { instantiation: 'false' },
    'app/profiles/Snapmaker/filament/Generic PLA @U1.json': { compatible_printers: [U1] },
  });
  const r = P.choosePresets(io, roots(CONF({ machine: U1, filaments: null })));
  assert.equal(r.ok, true, r.error);
  assert.equal(r.process.name, '0.20mm Standard @Snapmaker U1 (0.4 nozzle)', 'not 0.08mm, not the 0.2 nozzle one');
  assert.equal(r.filament.name, 'Generic PLA @U1');
});

test('a printer the shop made itself is found in user/<id>/machine and wins over the bundled tree', () => {
  const io = memIo({
    'app/profiles/Custom/machine/MyKlipper 0.4 nozzle.json': { nozzle_diameter: ['0.4'] },
    'cfg/user/default/machine/MyKlipper 0.2 nozzle.json': { inherits: 'MyKlipper 0.4 nozzle', nozzle_diameter: ['0.2'], default_print_profile: '0.08mm Extra Fine @MyKlipper' },
    'cfg/user/default/process/0.08mm Extra Fine @MyKlipper.json': { compatible_printers: ['MyKlipper 0.2 nozzle'] },
    'app/profiles/OrcaFilamentLibrary/filament/Generic PLA @System.json': { compatible_printers: [] },
  });
  const r = P.choosePresets(io, roots(CONF({ machine: 'MyKlipper 0.2 nozzle', filaments: null })));
  assert.equal(r.ok, true, r.error);
  assert.deepEqual(r.machine.nozzle_diameter, ['0.2']);
  assert.equal(r.process.name, '0.08mm Extra Fine @MyKlipper');
  assert.equal(r.filament.name, 'Generic PLA @System', 'an empty compatible_printers means any printer');
});

test('no printer chosen, or one missing from the profiles, is said rather than guessed', () => {
  const io = memIo({ 'app/profiles/X/machine/Other.json': {} });
  assert.equal(P.choosePresets(io, roots(CONF({ filaments: null }))).code, 'no-printer');
  assert.equal(P.choosePresets(io, roots('')).code, 'no-printer');
  assert.equal(P.choosePresets(io, roots(CONF({ machine: 'Gone 0.4 nozzle' }))).code, 'printer-missing');
});

test('a preset name cannot walk out of the profile tree', () => {
  const io = memIo({ 'app/profiles/X/machine/ok.json': {} });
  assert.equal(P.resolve(io, roots(''), 'machine', '../../../etc/passwd'), null);
  assert.equal(P.choosePresets(io, roots(CONF({ machine: '../ok' }))).code, 'printer-missing');
});

test('the CLI files say "system": Bambu Studio refuses a flattened User process (run 3002)', () => {
  const j = JSON.parse(P.presetFileJson('process', { name: 'p', inherits: 'x', layer_height: '0.2' }));
  assert.equal(j.from, 'system');
  assert.equal(j.type, 'process');
  assert.ok(!('inherits' in j));
});

test('where each platform keeps a fork\'s presets', () => {
  const mac = P.presetRoots('/Applications/Snapmaker Orca.app/Contents/MacOS/Snapmaker_Orca', { platform: 'darwin', home: '/Users/s' })[0];
  assert.equal(mac.dir, '/Users/s/Library/Application Support/Snapmaker_Orca');
  assert.equal(mac.confFile, '/Users/s/Library/Application Support/Snapmaker_Orca/Snapmaker_Orca.conf');
  assert.equal(mac.bundled, '/Applications/Snapmaker Orca.app/Contents/Resources/profiles');
  const win = P.presetRoots('C:\\Program Files\\Bambu Studio\\bambu-studio.exe', { platform: 'win32', home: 'C:\\Users\\s', env: { APPDATA: 'C:\\Users\\s\\AppData\\Roaming' } });
  assert.equal(win[0].dir, 'C:\\Users\\s\\AppData\\Roaming\\BambuStudio');
  assert.equal(win[0].bundled, 'C:\\Program Files\\Bambu Studio\\resources\\profiles');
  const lin = P.presetRoots('/opt/OrcaSlicer/orca-slicer', { platform: 'linux', home: '/home/s', env: {} });
  assert.equal(lin[0].dir, '/home/s/.config/OrcaSlicer');
});

test('only a project carrying its own settings slices without presets', () => {
  assert.equal(P.needsPresets('part.stl', null), true);
  assert.equal(P.needsPresets('mesh.3mf', ['3D/3dmodel.model', '[Content_Types].xml']), true);
  assert.equal(P.needsPresets('project.3mf', ['3D/3dmodel.model', 'Metadata/project_settings.config']), false);
});

test('presets go on the argv only for a fork running the arguments Khayt chose', () => {
  const presets = { settings: ['/t/khayt-machine.json', '/t/khayt-process.json'], filaments: ['/t/khayt-filament.json'] };
  const base = { model: '/m/part.stl', output: '/t/out.gcode', outdir: '/t', presets };
  assert.deepEqual(S.sliceArgv('', { ...base, slicer: '/Applications/OrcaSlicer.app/Contents/MacOS/OrcaSlicer' }),
    ['--load-settings', '/t/khayt-machine.json;/t/khayt-process.json', '--load-filaments', '/t/khayt-filament.json',
     '--slice', '0', '--outputdir', '/t', '/m/part.stl']);
  assert.deepEqual(S.sliceArgv('--slice 1 --outputdir {outdir} {model}', { ...base, slicer: '/x/OrcaSlicer' }),
    ['--slice', '1', '--outputdir', '/t', '/m/part.stl'], 'the shop\'s own arguments are left alone');
  assert.deepEqual(S.sliceArgv('', { ...base, slicer: '/x/PrusaSlicer' }), ['--export-gcode', '-o', '/t/out.gcode', '/m/part.stl']);
  assert.deepEqual(S.sliceArgv('', { ...base, slicer: '/x/OrcaSlicer', presets: { settings: ['a;b'] } }),
    ['--slice', '0', '--outputdir', '/t', '/m/part.stl'], 'a path that would split the list is refused');
});

test('a slicer that crashed is said to have crashed', () => {
  assert.match(S.sliceFailureReason({ code: null, signal: 'SIGSEGV', stdout: '' }), /crashed \(SIGSEGV\)/);
  assert.match(S.sliceFailureReason({ code: 139, stdout: '' }), /crashed/);
});
