// Phase 0 spike test: load the hand-written N-API addon and call add(2,3).
const addon = require('./hello_napi.node');
const r = addon.add(2, 3);
if (r === 5) {
  console.log('spike: ok');
  process.exit(0);
} else {
  console.error('spike: FAIL — add(2,3) returned', r);
  process.exit(1);
}
