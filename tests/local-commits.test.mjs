import { test } from "node:test"
import assert from "node:assert/strict"
import { execFileSync } from "node:child_process"
import { mkdtempSync, writeFileSync, rmSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"

const script = new URL("../scripts/local-commits.sh", import.meta.url).pathname

function git(repo, ...args) {
  return execFileSync("git", ["-C", repo, ...args], { encoding: "utf8" })
}

// A single-commit repo is the regression case: git's `format:` emits no
// trailing newline, which made the read loop drop each repo's last line.
test("single-commit repo yields exactly one TSV line", () => {
  const root = mkdtempSync(join(tmpdir(), "shiplog-scan-"))
  try {
    const repo = join(root, "one")
    execFileSync("git", ["init", "-q", repo])
    git(repo, "config", "user.email", "scan-test@example.com")
    git(repo, "config", "user.name", "Scan Test")
    writeFileSync(join(repo, "f.txt"), "x\n")
    git(repo, "add", "f.txt")
    git(repo, "commit", "-qm", "only commit\twith a tab")

    const out = execFileSync("bash", [script, "0", root], { encoding: "utf8" })
    const lines = out.split("\n").filter(Boolean)
    assert.equal(lines.length, 1)
    const parts = lines[0].split("\t")
    assert.equal(parts.length, 5)
    assert.match(parts[0], /^[0-9a-f]{40}$/)
    assert.ok(Number(parts[1]) > 0)
    assert.equal(parts[parts.length - 1], repo)
  } finally {
    rmSync(root, { recursive: true, force: true })
  }
})

test("commits before the since cutoff are excluded", () => {
  const root = mkdtempSync(join(tmpdir(), "shiplog-scan-"))
  try {
    const repo = join(root, "one")
    execFileSync("git", ["init", "-q", repo])
    git(repo, "config", "user.email", "scan-test@example.com")
    git(repo, "config", "user.name", "Scan Test")
    writeFileSync(join(repo, "f.txt"), "x\n")
    git(repo, "add", "f.txt")
    git(repo, "commit", "-qm", "old commit")

    const future = String(Math.floor(Date.now() / 1000) + 3600)
    const out = execFileSync("bash", [script, future, root], { encoding: "utf8" })
    assert.equal(out.trim(), "")
  } finally {
    rmSync(root, { recursive: true, force: true })
  }
})
