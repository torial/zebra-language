// Assertions for math.zbr's N-API addon. Required by tools/node_addon_test.sh.
'use strict';
const assert = require('assert');
const m = require('./math.node');
assert.strictEqual(m.add(2, 3), 5, 'add');
assert.strictEqual(m.add(-4, 4), 0, 'add negative');
assert.ok(Math.abs(m.mul(2.5, 4.0) - 10) < 1e-9, 'mul');
assert.strictEqual(m.negate(true), false, 'negate true');
assert.strictEqual(m.negate(false), true, 'negate false');
assert.strictEqual(m.answer(), 42, 'answer (no-arg)');
assert.strictEqual(m.touch(5), undefined, 'touch (void -> undefined)');
assert.strictEqual(m.square(7), 49, 'square (class static)');
console.log('math: ok');
