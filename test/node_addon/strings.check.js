// Assertions for strings.zbr's N-API addon. Required by tools/node_addon_test.sh.
'use strict';
const assert = require('assert');
const m = require('./strings.node');
assert.strictEqual(m.greet('Zebra'), 'Hello, Zebra!', 'greet');
assert.strictEqual(m.greet(''), 'Hello, !', 'greet empty');
assert.strictEqual(m.echo('round-trip'), 'round-trip', 'echo');
assert.strictEqual(m.echo('héllo·χ'), 'héllo·χ', 'echo UTF-8');
assert.strictEqual(m.blank(), '', 'blank');
assert.strictEqual(m.join2('a', 'b'), 'a/b', 'join2');
console.log('strings: ok');
