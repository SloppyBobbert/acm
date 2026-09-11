import { Parser, Language } from "./web-tree-sitter.js";

let parser;
let language;
self.onmessage = async ({ data }) => {
    const { source, id, editor, version, revision, session, language: selected } = data;
    const identity = { id, editor, version, revision, session, language: selected };
    let tree;
    let cursor;
    try {
        if (typeof source !== "string" || !["cpp", "rust"].includes(selected) ||
            source.length > 200 * 1024 || new TextEncoder().encode(source).length > 200 * 1024) {
            throw new Error("Source exceeds the 200 KiB syntax-check limit.");
        }
        if (!parser) {
            await Parser.init({ locateFile: () => new URL("./web-tree-sitter.wasm", import.meta.url).href });
            language = selected;
            const grammar = await Language.load(new URL(`./tree-sitter-${selected}.wasm`, import.meta.url).href);
            parser = new Parser();
            parser.setLanguage(grammar);
        }
        if (language !== selected) throw new Error("Syntax language changed.");
        self.postMessage({ ...identity, ready: true });
        const started = performance.now();
        tree = parser.parse(source, null, { progressCallback: () => performance.now() - started > 2000 });
        if (!tree) throw new Error("Syntax check exceeded two seconds.");
        const markers = [];
        cursor = tree.walk();
        do {
            const node = cursor.currentNode;
            if (node.isError || node.isMissing) {
                // web-tree-sitter string input exposes UTF-16 offsets, not UTF-8 bytes.
                markers.push({ start: node.startIndex, end: node.endIndex,
                    message: node.isMissing ? `Syntax: missing ${node.type}` : "Syntax: unexpected input" });
            }
            if (markers.length >= 100) break;
            if (cursor.gotoFirstChild()) continue;
            while (!cursor.gotoNextSibling()) {
                if (!cursor.gotoParent()) {
                    self.postMessage({ ...identity, markers, elapsed: performance.now() - started });
                    return;
                }
            }
        } while (performance.now() - started <= 2000);
        if (performance.now() - started > 2000) throw new Error("Syntax check exceeded two seconds.");
        self.postMessage({ ...identity, markers, elapsed: performance.now() - started });
    } catch (error) {
        parser?.delete();
        parser = undefined;
        self.postMessage({ ...identity, error: "Syntax checks unavailable. Editing and Run/Submit still work." });
    } finally {
        cursor?.delete();
        tree?.delete();
    }
};
