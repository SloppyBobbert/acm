export type SyntaxRequest = {
    id: number; editor: number; session: number; revision: number;
    version: number; language: "cpp" | "rust"; source: string;
};
export type SyntaxResult = Omit<SyntaxRequest, "source"> & {
    markers?: { start: number; end: number; message: string }[];
    error?: string;
};

type WorkerPort = {
    postMessage: (request: SyntaxRequest) => void;
    terminate: () => void;
    onmessage: ((event: MessageEvent<SyntaxResult>) => void) | null;
    onerror: ((event: ErrorEvent) => void) | null;
};

// One in-flight parse and one replaceable pending snapshot, including during asset loading.
export function syntaxChecks(createWorker: () => WorkerPort,
    deliver: (result: SyntaxResult) => void, status: (message: string) => void) {
    let worker: WorkerPort | undefined;
    let pending: SyntaxRequest | undefined;
    let active: SyntaxRequest | undefined;
    let latest = 0;
    let disposed = false;
    let debounce: ReturnType<typeof setTimeout> | undefined;
    let deadline: ReturnType<typeof setTimeout> | undefined;
    const stop = () => {
        clearTimeout(deadline);
        if (worker) { worker.onmessage = null; worker.onerror = null; worker.terminate(); }
        worker = undefined;
        active = undefined;
    };
    const fail = () => {
        if (disposed) return;
        stop();
        pending = undefined;
        status("Syntax checks unavailable. Editing and Run/Submit still work. Edit to retry.");
    };
    const send = () => {
        if (disposed || active || !pending) return;
        active = pending;
        pending = undefined;
        try {
            if (!worker) {
                worker = createWorker();
                worker.onerror = fail;
                worker.onmessage = ({ data }) => {
                    if (disposed || !active || data.id !== active.id ||
                        data.editor !== active.editor || data.session !== active.session ||
                        data.revision !== active.revision || data.version !== active.version ||
                        data.language !== active.language) return;
                    clearTimeout(deadline);
                    active = undefined;
                    if (data.id === latest) {
                        status(data.error ?? "Syntax checks are advisory; macros and preprocessing may differ from compilation.");
                        deliver(data);
                    }
                    if (data.error) stop();
                    send();
                };
            }
            // Includes asset loading: a slow or hung worker cannot retain source indefinitely.
            deadline = setTimeout(fail, 2000);
            worker.postMessage(active);
        } catch { fail(); }
    };
    return {
        update(request: Omit<SyntaxRequest, "id">) {
            if (disposed) return;
            latest++;
            clearTimeout(debounce);
            pending = undefined;
            if (request.source.length > 200 * 1024 || new TextEncoder().encode(request.source).length > 200 * 1024) {
                stop();
                status("Syntax check skipped: source exceeds 200 KiB. Run/Submit still work.");
                return;
            }
            debounce = setTimeout(() => {
                pending = { ...request, id: latest };
                send();
            }, 300);
        },
        dispose() {
            disposed = true;
            pending = undefined;
            clearTimeout(debounce);
            stop();
        },
    };
}
