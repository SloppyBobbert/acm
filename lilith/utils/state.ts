import { createWithEqualityFn } from "zustand/traditional";
import { persist, StateStorage } from "zustand/middleware";
import produce from "immer";
import { FunctionValue, Test, WasmFunctionCall } from "../components/problem/submission/tests";
import { Activity } from "../pages/meetings/new";
import { CompilerRequest, sameRequest } from "./editor-diagnostics";

type EditorThemeType = "light" | "dark" | "system";

type Auth = "ADMIN" | "OFFICER" | "MEMBER";

export interface User {
    id: number;
    name: string;
    username: string;
    discord_id: string;
    auth: Auth;
}

export type AsymptoticComplexity =
    "EXPONENTIAL" |
    "QUADRATIC" |
    "LOG_LINEAR" |
    "LINEAR" |
    "SQRT" |
    "LOG" |
    "CONSTANT";

export type Language = "cpp" | "rust";

export type Submission = {
    language?: Language;
    id: number;
    problem_id: number;
    user_id: number;
    error?: string;
    success: boolean;
    code: string;
    runtime: number;
    time: string;
    complexity?: AsymptoticComplexity;
}


export interface Store {
    vimEnabled: boolean;
    inlineCodeChecks: boolean;
    setInlineCodeChecks: (enabled: boolean) => void;
    editorTheme: EditorThemeType;
    editorFontSize: number;

    problemImpls: { [key: number]: string };
    rustImpls: { [key: number]: string };
    problemLanguages: { [key: number]: Language };
    setProblemLanguage: (id: number, language: Language) => void;

    setVimEnabled: (vimEnabled: boolean) => void;
    setEditorTheme: (editorTheme: EditorThemeType) => void;
    setEditorFontSize: (fontSize: number) => void;

    setProblemImpl: (id: number, impl: string, language?: Language) => void;
}

export function getProblemImpl(state: Store, id: number, language = state.problemLanguages[id] ?? "cpp") {
    return language === "rust" ? state.rustImpls[id] : state.problemImpls[id];
}

export const useStore = createWithEqualityFn<Store>()(
    persist(
        (set) => ({
            vimEnabled: false,
            inlineCodeChecks: false,
            setInlineCodeChecks: (inlineCodeChecks) => {
                useSession.getState().invalidateDiagnostics(true);
                set({ inlineCodeChecks });
            },
            editorTheme: "system",
            editorFontSize: 18,
            problemImpls: {},
            rustImpls: {},
            problemLanguages: {},
            setProblemLanguage: (id, language) => {
                useSession.getState().invalidateDiagnostics();
                set(produce((state: Store) => { state.problemLanguages[id] = language; }));
            },

            setProblemImpl: (id, impl, language = "cpp") => {
                useSession.getState().invalidateDiagnostics();
                set(
                    produce((state: Store) => {
                        if (language === "rust") state.rustImpls[id] = impl;
                        else state.problemImpls[id] = impl;
                        state.problemLanguages[id] = language;
                    })
                );
            },

            setVimEnabled: (vimEnabled) =>
                set(
                    produce((state: Store) => {
                        state.vimEnabled = vimEnabled;
                    })
                ),

            setEditorTheme: (editorTheme) =>
                set(
                    produce((state: Store) => {
                        state.editorTheme = editorTheme;
                    })
                ),

            setEditorFontSize: (fontSize) =>
                set(
                    produce((state: Store) => {
                        state.editorFontSize = fontSize;
                    })
                ),
        }),
        {
            name: "data",
        }
    )
);

export interface Session {
    error: string;
    errorShown: boolean;
    submissionShown: boolean;
    diagnosticEditor: number;
    diagnosticGeneration: number;
    diagnosticRevision: number;
    diagnosticRequestId: number;
    compilerRequest: CompilerRequest | null;
    compilerError: string | null;
    invalidateDiagnostics: (newGeneration?: boolean) => void;
    mountDiagnosticEditor: () => number;
    beginCompilerCheck: (problem: number, language: Language, source: string) => CompilerRequest | null;
    finishCompilerCheck: (request: CompilerRequest | null, error?: unknown) => void;

    setSubmissionShown: (shown: boolean) => void;
    setError: (error: string, shown: boolean) => void;
}

export const useSession = createWithEqualityFn<Session>()((set, get) => ({
    error: "",
    errorShown: false,
    submissionShown: true,
    diagnosticEditor: 0,
    diagnosticGeneration: 0,
    diagnosticRevision: 0,
    diagnosticRequestId: 0,
    compilerRequest: null,
    compilerError: null,
    invalidateDiagnostics: (newGeneration = false) => set(state => ({
        diagnosticRevision: state.diagnosticRevision + 1,
        diagnosticGeneration: state.diagnosticGeneration + (newGeneration ? 1 : 0),
        compilerRequest: null, compilerError: null,
    })),
    mountDiagnosticEditor: () => {
        get().invalidateDiagnostics(true);
        const diagnosticEditor = get().diagnosticEditor + 1;
        set({ diagnosticEditor });
        return diagnosticEditor;
    },
    beginCompilerCheck: (problem, language, source) => {
        if (useStore.getState().inlineCodeChecks !== true) return null;
        const state = get();
        const request: CompilerRequest = { problem, language, source,
            editor: state.diagnosticEditor, generation: state.diagnosticGeneration,
            revision: state.diagnosticRevision, request: state.diagnosticRequestId + 1 };
        // Keep the last result until compilation replaces it; transport failures are not new diagnostics.
        set({ compilerRequest: request, diagnosticRequestId: request.request });
        return request;
    },
    finishCompilerCheck: (request, error) => {
        const state = get();
        if (useStore.getState().inlineCodeChecks !== true || !sameRequest(request, state.compilerRequest)) return;
        set({ compilerError: typeof error === "string" ? error : null });
    },

    setSubmissionShown: (shown) =>
        set(
            produce((state: Session) => {
                state.submissionShown = shown;
            })
        ),

    setError: (error, shown) =>
        set(
            produce((state: Session) => {
                state.error = error;
                state.errorShown = shown;
            })
        ),
}));

// TODO: restructure this to use nested classes instead.
export interface AdminState {
    problemTitle: string;
    problemTestFormat: WasmFunctionCall;
    problemDescription: string;
    problemReference: string;
    problemTemplate: string;
    problemPublishTime?: string;
    problemTests: Test[];
    problemDateShown: boolean;
    problemRuntimeMultiplier: number;
    problemCompetitionId?: number;

    setProblemTitle: (title: string) => void;
    setProblemTestFormat: (type: WasmFunctionCall) => void;
    setProblemDescription: (description: string) => void;
    setProlbemReference: (reference: string) => void;
    setProblemTemplate: (template: string) => void;
    setProblemDateShown: (shown: boolean) => void;

    updateProblemTest: (index: number, test: Partial<Test>) => void;
    pushProblemTest: (test: Test) => void;
    popProblemTest: () => void;
    setProblemTests: (tests: Test[]) => void;

    clearProblemCreation: () => void,

    meetingTitle: string;
    meetingDescription: string;
    meetingTime: string;
    meetingActivities: Activity[];

    setProblemPublishTime: (time?: string) => void;
    setProblemCompetitionId: (competitionId?: number) => void;
    setProblemRuntimeMultiplier: (multiplier: number) => void;

    setMeetingTitle: (title: string) => void;
    setMeetingDescription: (description: string) => void;
    setMeetingTime: (time: string) => void;

    updateMeetingActivity: (index: number, test: Partial<Activity>) => void;
    pushMeetingActivity: () => void;
    popMeetingActivity: () => void;
}

export const useAdminStore = createWithEqualityFn<AdminState>()(
    persist(
        (set) => ({
            problemTitle: "",
            problemDescription: "",
            problemReference: "",
            problemTemplate: "",
            problemTestFormat: {
                name: "",
                arguments: [],
                return_type: { Int: "Single" }
            },
            problemTests: [],
            problemRuntimeMultiplier: 1.1,
            problemDateShown: false,

            meetingTitle: "",
            meetingDescription: "",
            meetingTime: "",
            meetingActivities: [],

            setProblemTitle: (title: string) =>
                set(
                    produce((state: AdminState) => {
                        state.problemTitle = title
                    })
                ),


            setProblemTestFormat: (testFormat: WasmFunctionCall) => set(
                produce((state: AdminState) => {
                    state.problemTestFormat = testFormat;
                })
            ),

            setProblemDescription: (description: string) =>
                set(
                    produce((state: AdminState) => {
                        state.problemDescription = description;
                    })
                ),

            setProlbemReference: (reference: string) =>
                set(
                    produce((state: AdminState) => {
                        state.problemReference = reference;
                    })
                ),

            setProblemTemplate: (template: string) =>
                set(
                    produce((state: AdminState) => {
                        state.problemTemplate = template;
                    })
                ),

            setProblemDateShown: (shown: boolean) =>
                set(
                    produce((state: AdminState) => {
                        state.problemDateShown = shown;
                    })
                ),

            // assumes test index is valid. should always be the case.
            updateProblemTest: (index: number, test: Partial<Test>) =>
                set(
                    produce((state: AdminState) => {
                        state.problemTests[index]! = {
                            ...state.problemTests[index]!,
                            ...test,
                        };
                    })
                ),

            pushProblemTest: (test: Test) =>
                set(
                    produce((state: AdminState) => {
                        state.problemTests.push(test);
                    })
                ),

            popProblemTest: () =>
                set(
                    produce((state: AdminState) => {
                        state.problemTests.pop();
                    })
                ),

            setProblemPublishTime: (time?: string) =>
                set(
                    produce((state: AdminState) => {
                        state.problemPublishTime = time;
                    })
                ),

            setProblemCompetitionId: (competitionId?: number) =>
                set(
                    produce((state: AdminState) => {
                        state.problemCompetitionId = competitionId;
                    })
                ),

            setProblemTests: (tests: Test[]) =>
                set(
                    produce((state: AdminState) => {
                        state.problemTests = tests;
                    })
                ),

            clearProblemCreation: () =>
                set(
                    produce((state: AdminState) => {
                        state.problemTests = [];
                        state.problemTitle = "";
                        state.problemDescription = "";
                        state.problemReference = "";
                        state.problemTemplate = "";
                    })
                ),

            setMeetingTitle: (title: string) =>
                set(
                    produce((state: AdminState) => {
                        state.meetingTitle = title;
                    })
                ),

            setMeetingTime: (time: string) =>
                set(
                    produce((state: AdminState) => {
                        state.meetingTime = time;
                    })
                ),

            setMeetingDescription: (description: string) =>
                set(
                    produce((state: AdminState) => {
                        state.meetingDescription = description;
                    })
                ),

            // assumes test index is valid. should always be the case.
            updateMeetingActivity: (index: number, activity: Partial<Activity>) =>
                set(
                    produce((state: AdminState) => {
                        state.meetingActivities[index]! = {
                            ...state.meetingActivities[index]!,
                            ...activity,
                        };
                    })
                ),

            pushMeetingActivity: () =>
                set(
                    produce((state: AdminState) => {
                        state.meetingActivities.push({
                            title: "",
                            description: "",
                            activity_type: "SOLO"
                        });
                    })
                ),

            popMeetingActivity: () =>
                set(
                    produce((state: AdminState) => {
                        state.meetingActivities.pop();
                    })
                ),


            setProblemRuntimeMultiplier: (multiplier: number) =>
                set(
                    produce((state: AdminState) => {
                        state.problemRuntimeMultiplier = multiplier;
                    })
                )

        }),
        {
            name: "admin_data",
        }
    )
);
