---
max_turns: 10
allowed_tools: [Read, Glob, Grep, Skill]
---

Review this C function for bugs:

```c
int sum(const int *a, int n)
{
    int s = 0;
    for (int i = 0; i <= n; i++) {
        s += a[i];
    }
    return s;
}
```
