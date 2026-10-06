// The parity harness's normalizer over one file: node script/normalize.mts FILE [document|fragment]
import { readFileSync } from "node:fs"
import { normalizeDocument, normalizeFragment } from "../../../once-campfire-rust/parity/capture/normalize.ts"
const [file, mode] = process.argv.slice(2)
const html = readFileSync(file, "utf8")
const options = { seedTime: Date.parse("2026-03-02T16:00:00Z") }
process.stdout.write(mode === "fragment" ? normalizeFragment(html, options) : normalizeDocument(html, options))
