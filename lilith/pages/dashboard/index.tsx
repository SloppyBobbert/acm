import type { NextPage } from "next";
import Head from "next/head";
import Link from "next/link";
import { useEffect, useState } from "react";
import useSWR from "swr";
import ErrorBox from "../../components/error-box";
import Footer from "../../components/footer";
import Navbar from "../../components/navbar";
import { api_url, fetcher } from "../../utils/fetcher";
import { Submission, User } from "../../utils/state";

function Completion({ completion }: { completion: Submission }): JSX.Element {
    const { data: user } = useSWR<User>(
        api_url(`/user/id/${completion.user_id}`),
        fetcher
    );

    return (
        <Link href={`/submissions/${completion.id}`}>
            <a className="focus-ring flex flex-col border-b border-neutral-300 p-2 last:border-b-0 transition-colors hover:bg-neutral-50 dark:border-neutral-700 dark:hover:bg-neutral-600">
                <span className="font-extrabold">Problem {completion.problem_id}</span>

                {user && <span>{user.username}</span>}
            </a>
        </Link>
    );
}

function JobElement({ job }: { job: Job }): JSX.Element {
    const { data: user } = useSWR<User>(
        api_url(`/user/id/${job.user_id}`),
        fetcher
    );

    const animate = job.queue_position ? "animate-pulse" : "";

    return (
        <div className={`flex flex-col border-b border-neutral-300 p-2 last:border-b-0 transition-colors hover:bg-neutral-50 dark:border-neutral-700 dark:hover:bg-neutral-600 ${animate}`}>
            <span className="font-extrabold">Problem {job.problem_id}</span>

            <div className="grid grid-cols-2">
                <span>job type</span>
                <span>{job.job_type}</span>

                {user && <>
                    <span>username</span>
                    <span>{user.username}</span>
                </>}

                {job.queue_position && <>
                    <span>queue position</span>
                    <span>{job.queue_position}</span>
                </>}
            </div>
        </div>
    );
}

function EmptyColumn({ children }: { children: string }): JSX.Element {
    return (
        <p className="rounded-xl border border-dashed border-neutral-300 bg-white p-4 text-sm text-neutral-500 dark:border-neutral-700 dark:bg-black dark:text-neutral-400">
            {children}
        </p>
    );
}

function LoadingColumn(): JSX.Element {
    return (
        <div
            className="h-24 animate-pulse rounded-xl border border-neutral-300 bg-neutral-100 dark:border-neutral-700 dark:bg-neutral-800"
            aria-hidden="true"
        />
    );
}

function CompletionsList({ completions }: { completions: Submission[] }): JSX.Element {
    if (completions.length == 0) {
        return <EmptyColumn>No completions yet.</EmptyColumn>;
    }

    return (
        <div className="flex flex-col overflow-hidden rounded-xl border border-neutral-300 bg-white dark:border-neutral-700 dark:bg-black">
            {completions.map((completion) =>
                <Completion key={completion.id} completion={completion} />
            )}
        </div>
    );
}

function JobsList({ jobs }: { jobs: Job[] }): JSX.Element {
    if (jobs.length == 0) {
        return <EmptyColumn>No jobs yet.</EmptyColumn>;
    }

    return (
        <div className="flex flex-col overflow-hidden rounded-xl border border-neutral-300 bg-white dark:border-neutral-700 dark:bg-black">
            {jobs.map((job, i) =>
                <JobElement key={job.id ?? i} job={job} />
            )}
        </div>
    );
}

type Job = {
    id?: number;
    job_type: "CustomInput" | "SubmitJob";
    problem_id: number,
    user_id: number,
    queue_position?: number,
};

type DashboardMessage =
    | { NewJob: Job & { id: number } }
    | { FinishedJob: Job & { id: number } }
    | { NewCompletion: Submission };

function isDashboardMessage(value: unknown): value is DashboardMessage {
    if (typeof value !== "object" || value === null) return false;

    const isMessagePayload = (payload: unknown, isJob: boolean): boolean =>
        typeof payload === "object" &&
        payload !== null &&
        "id" in payload && typeof payload.id === "number" &&
        "problem_id" in payload && typeof payload.problem_id === "number" &&
        "user_id" in payload && typeof payload.user_id === "number" &&
        (!isJob || ("job_type" in payload && typeof payload.job_type === "string"));

    return (
        ("NewJob" in value && isMessagePayload(value.NewJob, true)) ||
        ("FinishedJob" in value && isMessagePayload(value.FinishedJob, true)) ||
        ("NewCompletion" in value && isMessagePayload(value.NewCompletion, false))
    );
}

const DashboardPage: NextPage = () => {
    const [completions, setCompletions] = useState<Submission[]>([]);
    const [pendingJobs, setPendingJobs] = useState<Map<number, Job>>(new Map);
    const [finishedJobs, setFinishedJobs] = useState<Job[]>([]);
    const [connection, setConnection] = useState<"connecting" | "open" | "closed">("connecting");

    useEffect(() => {
        let cancelled = false;
        const client = new WebSocket(process.env.NEXT_PUBLIC_WS_URL!);

        client.addEventListener("open", () => {
            if (!cancelled) setConnection("open");
        });
        client.addEventListener("error", () => {
            if (!cancelled) setConnection("closed");
        });
        client.addEventListener("close", () => {
            if (!cancelled) setConnection("closed");
        });

        client.addEventListener('message', (event) => {
            let parsed: unknown;

            try {
                parsed = JSON.parse(event.data);
            } catch {
                return;
            }

            const data = parsed;

            if (!isDashboardMessage(data)) return;

            if ("NewJob" in data) {
                const newJob: Job = {
                    id: data.NewJob.id,
                    job_type: data.NewJob.job_type,
                    problem_id: data.NewJob.problem_id,
                    user_id: data.NewJob.user_id,
                    queue_position: data.NewJob.queue_position,
                };

                setPendingJobs(oldJobs =>
                    new Map(oldJobs.set(data.NewJob.id, newJob))
                );
            } else if ("FinishedJob" in data) {
                const newJob: Job = {
                    id: data.FinishedJob.id,
                    job_type: data.FinishedJob.job_type,
                    problem_id: data.FinishedJob.problem_id,
                    user_id: data.FinishedJob.user_id,
                };

                setPendingJobs(oldJobs => {
                    oldJobs.delete(data.FinishedJob.id);
                    return new Map(oldJobs);
                });
                setFinishedJobs(oldJobs => [newJob, ...oldJobs]);

            } else if ("NewCompletion" in data) {
                setCompletions(oldCompletions => [data.NewCompletion, ...oldCompletions]);
            }
        });

        return () => {
            cancelled = true;
            client.close();
        };
    }, []);

    const showLists = connection !== "connecting";

    return (
        <div className="page-shell">
            <Navbar />

            <Head>
                <title>Admin Dashboard</title>
            </Head>

            <main className="flex-1 p-4">
                <h1 className="page-heading mb-4">Dashboard</h1>

                {connection === "connecting" && (
                    <p className="mb-4 text-sm text-neutral-500" aria-busy="true">
                        Connecting to live updates…
                    </p>
                )}

                {connection === "closed" && (
                    <ErrorBox>
                        Could not connect to the live dashboard. Check that the API is running.
                    </ErrorBox>
                )}

                <div className="grid grid-cols-1 gap-4 md:grid-cols-3">
                    <section className="flex flex-col gap-4">
                        <h2 className="text-2xl font-extrabold">Pending Jobs</h2>
                        {showLists ? <JobsList jobs={Array.from(pendingJobs.values())} /> : <LoadingColumn />}
                    </section>
                    <section className="flex flex-col gap-4">
                        <h2 className="text-2xl font-extrabold">Finished Jobs</h2>
                        {showLists ? <JobsList jobs={finishedJobs} /> : <LoadingColumn />}
                    </section>
                    <section className="flex flex-col gap-4">
                        <h2 className="text-2xl font-extrabold">Completions</h2>
                        {showLists ? <CompletionsList completions={completions} /> : <LoadingColumn />}
                    </section>
                </div>
            </main>

            <Footer />
        </div>
    );
};

export default DashboardPage;
