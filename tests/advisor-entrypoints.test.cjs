const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const root = path.join(__dirname, '..', 'guanpan-pro-native', 'Sources');
const content = fs.readFileSync(path.join(root, 'ContentView.swift'), 'utf8');
const hubs = fs.readFileSync(path.join(root, 'WorkspaceHubs.swift'), 'utf8');

test('user-facing holding guidance routes to the unified real-holdings advisor', () => {
  assert.match(hubs, /NavigationLink\s*\{\s*LabResearchView\(\)\s*\} label: \{ ProActionRow\(title: "AI 今日指导"/);
  assert.doesNotMatch(hubs, /NavigationLink\s*\{\s*DayGridView\(\)/);
});

test('legacy simulation and grid-replay sheets are not reachable from the tools page', () => {
  assert.doesNotMatch(content, /activeSheet\s*=\s*\.(?:grid|gridReview|longGridPlanner|addCash)\b/);
  assert.doesNotMatch(content, /case \.(?:grid|gridReview|longGridPlanner|addCash):/);
});
