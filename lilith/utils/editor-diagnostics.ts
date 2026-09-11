export type Diagnostic = {
    line: number;
    col: number;
    diagnostic_type: "Error" | "Warning" | "Note";
    message: string;
};

const RESULT_PANEL_LIMIT = 500;

export function parseDiagnostics(error: unknown): Diagnostic[] | null {
    if (typeof error !== "string" || error.length > 1024 * 1024) return null;
    try {
        const parsed: unknown = JSON.parse(error);
        if (!Array.isArray(parsed)) return null;
        const items = parsed.filter(item => item &&
            Number.isSafeInteger(item.line) && item.line >= 0 &&
            Number.isSafeInteger(item.col) && item.col >= 0 &&
            ["Error", "Warning", "Note"].includes(item.diagnostic_type) &&
            typeof item.message === "string");
        if (parsed.length && !items.length) return null;
        if (items.length <= RESULT_PANEL_LIMIT) return items;
        return [...items.slice(0, RESULT_PANEL_LIMIT), {
            line: 0, col: 0, diagnostic_type: "Note",
            message: `${items.length - RESULT_PANEL_LIMIT} additional diagnostics omitted. Fix the reported errors and run again.`,
        }];
    } catch { return null; }
}

export function compilerMarkers(error: unknown, source: string) {
    const lines = source.split(/\r?\n/);
    return (parseDiagnostics(error) ?? []).filter(d => d.line > 0 && d.line <= lines.length)
        .slice(0, 100).map(d => {
            const line = lines[d.line - 1];
            // Compiler column units differ; non-ASCII or tabs use a safe whole-line range.
            const precise = /^[\x20-\x7e]*$/.test(line) && d.col > 0 && d.col <= line.length + 1;
            const column = precise ? Math.min(d.col, Math.max(1, line.length)) : 1;
            return { startLineNumber: d.line, endLineNumber: d.line,
                startColumn: column, endColumn: precise ? Math.min(column + 1, line.length + 1) : line.length + 1,
                message: d.message, severity: d.diagnostic_type === "Error" ? 8 : d.diagnostic_type === "Warning" ? 4 : 2,
                source: "Compiler" };
        });
}

export type CompilerRequest = {
    editor: number; generation: number; revision: number; request: number;
    problem: number; language: "cpp" | "rust"; source: string;
};

export function sameRequest(a: CompilerRequest | null, b: CompilerRequest | null) {
    return !!a && !!b && a.editor === b.editor && a.generation === b.generation &&
        a.revision === b.revision && a.request === b.request && a.problem === b.problem &&
        a.language === b.language && a.source === b.source;
}
