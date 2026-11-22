#!/usr/bin/env node
'use strict';
const fs = require('fs');
const path = require('path');
const { execSync } = require('child_process');
const dir = path.join(__dirname, '../renderer/locales');
for (const name of fs.readdirSync(dir).filter(f => f.endsWith('.js')).sort()) {
  execSync(`node --check ${JSON.stringify(path.join(dir, name))}`, { stdio: 'inherit' });
}
