---
type: regex
target: trace
pattern: '"tool_use_result":(?:\{"stdout":)?"(?:(?:[^"\\]|\\.)*?\\n)?(?: inbox/thermal-derating\.md +(?:\([a-z ]+\) +)?\| +\d+ [+-]|diff --git (?:\w/)?inbox/thermal-derating\.md |(?:[AM]|\d+\\t\d+|:\d{6} \d{6} [0-9a-f.]+ [0-9a-f.]+ [AM])\\tinbox/thermal-derating\.md)'
---
