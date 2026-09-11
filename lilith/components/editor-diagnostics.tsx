import { useEffect, useState } from "react";
import * as monaco from "monaco-editor";
import { compilerMarkers } from "../utils/editor-diagnostics";
import { useSession, useStore } from "../utils/state";
import { syntaxChecks } from "../utils/syntax-checks";

const syntaxOwner = "submission-syntax";
const compilerOwner = "submission-compiler";

export default function EditorDiagnostics({ editor, problem, language }: {
    editor: monaco.editor.IStandaloneCodeEditor;
    problem: number;
    language: "cpp" | "rust";
}) {
    const enabled = useStore(state => state.inlineCodeChecks === true);
    const [status, setStatus] = useState("");

    useEffect(() => {
        useSession.getState().mountDiagnosticEditor();
        return () => useSession.getState().invalidateDiagnostics(true);
    }, [editor, problem, language]);

    useEffect(() => {
        const model = editor.getModel();
        if (!model || !enabled) return;
        const clear = () => {
            if (!model.isDisposed()) {
                monaco.editor.setModelMarkers(model, syntaxOwner, []);
                monaco.editor.setModelMarkers(model, compilerOwner, []);
            }
        };
        const checks = syntaxChecks(
            () => new Worker("/editor-diagnostics/worker.js", { type: "module" }),
            result => {
                const state = useSession.getState();
                if (model.isDisposed() || useStore.getState().inlineCodeChecks !== true ||
                    result.editor !== state.diagnosticEditor || result.session !== state.diagnosticGeneration ||
                    result.revision !== state.diagnosticRevision || result.version !== model.getVersionId()) return;
                monaco.editor.setModelMarkers(model, syntaxOwner, (result.markers ?? []).slice(0, 100).map(marker => {
                    const length = model.getValueLength();
                    const start = model.getPositionAt(Math.max(0, Math.min(marker.start, Math.max(0, length - 1))));
                    const end = model.getPositionAt(Math.min(length, Math.max(marker.end, marker.start + 1)));
                    return { startLineNumber: start.lineNumber, startColumn: start.column,
                        endLineNumber: end.lineNumber, endColumn: end.column,
                        message: marker.message, severity: monaco.MarkerSeverity.Warning, source: "Syntax (advisory)" };
                }));
            }, setStatus);
        const schedule = () => {
            if (model.isDisposed()) return;
            clear();
            const state = useSession.getState();
            checks.update({ editor: state.diagnosticEditor, session: state.diagnosticGeneration,
                revision: state.diagnosticRevision, version: model.getVersionId(),
                source: model.getValue(), language });
        };
        schedule();
        const content = model.onDidChangeContent(schedule);
        const unsubscribe = useSession.subscribe((state, previous) => {
            if (model.isDisposed()) return;
            if (state.diagnosticRevision !== previous.diagnosticRevision) schedule();
            if (state.compilerRequest !== previous.compilerRequest || state.compilerError !== previous.compilerError) {
                const request = state.compilerRequest;
                const matches = request?.editor === state.diagnosticEditor && request?.problem === problem &&
                    request?.generation === state.diagnosticGeneration && request?.revision === state.diagnosticRevision &&
                    request?.language === language && request?.source === model.getValue();
                monaco.editor.setModelMarkers(model, compilerOwner,
                    matches ? compilerMarkers(state.compilerError, model.getValue()) : []);
            }
        });
        // Clear synchronously at opt-out, before React's effect cleanup.
        const preference = useStore.subscribe(state => {
            if (state.inlineCodeChecks !== true) { checks.dispose(); clear(); }
        });
        return () => { unsubscribe(); preference(); content.dispose(); checks.dispose(); clear(); };
    }, [editor, enabled, language, problem]);

    return enabled ? <p role="status" className="text-xs px-2 py-1">{status}</p> : null;
}
