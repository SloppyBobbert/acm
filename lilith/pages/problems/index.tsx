import type { NextPage } from "next";
import Navbar from "../../components/navbar";
import useSWRInfinite from "swr/infinite";
import { marked } from "marked";
import Link from "next/link";
import { api_url, fetcher } from "../../utils/fetcher";
import { User, useStore } from "../../utils/state";
import { useContext, useEffect, useRef, useState } from "react";
import renderLatex from "../../utils/latex";
import { CompetitionIDContext } from "../competitions/[id]";
import useSWR, { mutate } from "swr";
import LoadingButton from "../../components/loading-button";
import Head from "next/head";
import ErrorBox from "../../components/error-box";

function ProblemLoading(): JSX.Element {
    return (
        <div className="animate-fade-in sm:rounded-md border-neutral-300 dark:border-neutral-700 border-y sm:border sm:mx-2 md:m-0 bg-white dark:bg-black dark:hover:bg-neutral-800 p-4 hover:shadow-md max-h-52 hover:max-h-64 overflow-hidden transition-all">
            <div className="animate-pulse">
                <h1 className="rounded bg-neutral-200 w-64 text-2xl h-6 mb-4"></h1>
                <p className="rounded bg-neutral-200 w-full h-3 mb-2"></p>
                <p className="rounded bg-neutral-200 w-full h-3 mb-2"></p>
                <p className="rounded bg-neutral-200 w-full h-3"></p>
            </div>
        </div>
    );
}

export type Problem = {
    id: number;
    title: string;

    // markdown formatted
    description: string;
    runtime_multiplier: number;

    template: string;

    visible: boolean;
    difficulty?: string;
};

type ProblemStatus = "Complete" | "InProgress" | "NotStarted";

function ProblemTeamStatus({ problem_id }: { problem_id: number }): JSX.Element {

    const competition_id = useContext(CompetitionIDContext);

    const { data, error } = useSWR<ProblemStatus>(
        api_url(`/competitions/${competition_id}/problem-status/${problem_id}`),
        fetcher
    );

    if (!data || error) return <></>;

    if (data == "InProgress") {
        return (
            <div className="ml-auto bg-blue-700 text-blue-50 rounded-full px-4 py-2 text-sm">
                In Progress
            </div>
        );
    } else if (data == "Complete") {
        return (
            <div className="ml-auto bg-green-700 text-blue-50 rounded-full px-4 py-2 text-sm">
                Completed
            </div>
        );
    } else {
        return <></>;
    }
}

interface ProblemListingProps extends Problem {
    show_team_status?: boolean;
};

function DifficultyBadge({ difficulty }: { difficulty: string }): JSX.Element {
    if (difficulty == "Easy") {
        return <span className="bg-green-600 text-green-50 rounded-full px-4 py-2 text-sm">Easy</span>;
    }

    if (difficulty == "Medium") {
        return <span className="bg-yellow-600 text-yellow-50 rounded-full px-4 py-2 text-sm">Medium</span>;
    }

    if (difficulty == "Hard") {
        return <span className="bg-red-600 text-red-50 rounded-full px-4 py-2 text-sm">Hard</span>;
    }

    return <>{difficulty}</>;
}

function ProblemListing({ id, title, description, show_team_status, difficulty }: ProblemListingProps): JSX.Element {
    let desc = marked.parse(description);
    const content = useRef<HTMLDivElement>(null);

    useEffect(() => {
        if (content.current) {
            renderLatex(content.current);
        }
    });

    return (
        <Link href={`/problems/${id}`}>
            <a className="sm:rounded-md border-neutral-300 dark:border-neutral-700 border-y sm:border sm:mx-2 md:m-0 bg-white dark:bg-black dark:hover:bg-neutral-800 p-4 hover:shadow-md max-h-52 hover:max-h-64 overflow-hidden transition-all">
                <div className="flex items-center mb-4">
                    <h1 className="text-2xl font-extrabold">{title}</h1>

                    <div className="flex ml-auto gap-4">
                        {difficulty !== undefined && <DifficultyBadge difficulty={difficulty} />}
                        {show_team_status && <ProblemTeamStatus problem_id={id} />}
                    </div>
                </div>

                <div
                    ref={content}
                    className="prose prose-neutral dark:prose-invert"
                    dangerouslySetInnerHTML={{ __html: desc }}
                />
            </a>
        </Link>
    );
}

function ListLoading(): JSX.Element {
    return (
        <>
            <ProblemLoading />
            <ProblemLoading />
            <ProblemLoading />
            <ProblemLoading />
        </>
    );
}

function EmptyProblemResults({ title, description }: { title: string, description: string }): JSX.Element {
    return (
        <div className="sm:rounded-md border-neutral-300 dark:border-neutral-700 border-y sm:border sm:mx-2 md:m-0 bg-white dark:bg-black p-6 text-center">
            <h2 className="text-2xl font-bold">{title}</h2>
            <p className="mt-2 text-neutral-600 dark:text-neutral-400">{description}</p>
        </div>
    );
}

export function ProblemList({ problems, show_team_status, show_difficulty }: { problems: Problem[], show_team_status?: boolean, show_difficulty?: boolean }): JSX.Element {
    return (
        <>
            {problems.map(({ id, title, description, difficulty, visible }) => (
                <ProblemListing
                    key={id}
                    id={id}
                    title={title}
                    template={""}
                    runtime_multiplier={0.0}
                    description={description}
                    show_team_status={show_team_status}
                    difficulty={(show_difficulty ?? true) ? difficulty : undefined}
                    visible={visible}
                />
            ))}
        </>
    );
}

function ProblemSearchResults({ query }: { query: string }) {
    const { data: problems, error } = useSWR<Problem[]>(
        "PROBLEMS_QUERY",
        () => fetcher(api_url(`/problems?query=${query}&count=10`))
    );

    useEffect(() => {
        mutate("PROBLEMS_QUERY");
    }, [query]);

    if (error) return (
        <ErrorBox>
            Could not fetch problems
        </ErrorBox>
    );

    if (problems && problems.length === 0) {
        return (
            <EmptyProblemResults
                title="No matching problems"
                description="Try a different search or clear the filters to see more local problems."
            />
        );
    }

    if (problems) {
        return <ProblemList problems={problems} />;
    } else {
        return <ListLoading />;
    }
}

function ProblemInfiniteResults({ difficulty, showCompetitionProblems, sortBy }: { difficulty: number, showCompetitionProblems: boolean, sortBy: string }) {
    const { data, error, isValidating, size, setSize } = useSWRInfinite<Problem[]>(
        (pageIndex, previousProblems) => {
            if (previousProblems && !previousProblems.length) return null;

            return api_url(`/problems?offset=${7 * pageIndex}&count=7&difficulty=${difficulty}&show_competition_problems=${showCompetitionProblems}&sort_by=${sortBy}`);
        },
        fetcher
    );

    if (error) return (
        <ErrorBox>
            Could not fetch problems
        </ErrorBox>
    );

    const isEmpty = !!data && data.length > 0 && data[0].length === 0;

    return <>
        {isEmpty && (
            <EmptyProblemResults
                title="No problems yet"
                description="Add a local problem or adjust the filters to populate this list."
            />
        )}

        {!data ? <ListLoading /> : data.map((problems, i) => <ProblemList key={i} problems={problems} />)}

        {!isEmpty && <LoadingButton
            loading={isValidating}
            className="rounded-full bg-neutral-200 hover:bg-neutral-300 px-6 py-3 transition-colors mx-auto dark:hover:bg-neutral-700 dark:bg-neutral-800"
            onClick={() => setSize(size + 1)}
        >Load more</LoadingButton>}
    </>;
}

const ProblemListPage: NextPage = () => {
    const [difficulty, setDifficulty] = useState(0);
    const [showCompetitionProblems, setShowCompetitionProblems] = useState(false);
    const [sortBy, setSortBy] = useState("Newest");
    const [query, setQuery] = useState("");
    const [isComponentMounted, setIsComponentMounted] = useState(false);
    const [showFilters, setShowFilters] = useState(false);

    const { data: user } = useSWR<User>(
        api_url("/user/me"),
        fetcher, {
        shouldRetryOnError: false,
    });

    useEffect(() => setIsComponentMounted(true), []);

    return (
        <>
            <Navbar />

            <Head>
                <title>Problems</title>
            </Head>

            <div className="max-w-screen-md mx-auto my-4 flex flex-col gap-4">
                <div className="grid grid-cols-5 gap-4 items-center justify-center">
                    <button
                        onClick={() => setShowFilters(!showFilters)}
                        aria-expanded={showFilters}
                        aria-controls="problem-filters"
                        className="col-end-2 mr-auto bg-neutral-100 dark:bg-neutral-800 dark:hover:bg-neutral-700 hover:bg-neutral-200 px-4 py-2 rounded-full transition-colors"
                    >
                        Filters
                    </button>

                    <div className="col-start-2 col-end-5 focus-within:outline focus-within:outline-2 focus-within:border-neutral-200 focus-within:outline-neutral-200 border-neutral-100 dark:border-neutral-800 border rounded-full bg-white dark:bg-black dark:text-white overflow-hidden h-10 flex">
                        <input aria-label="Search problems" className="outline-0 w-full ml-4 h-full dark:bg-black" value={query} onChange={e => setQuery(e.target.value)} />

                        <div className="h-10 aspect-square inline-flex items-center justify-center">
                            <svg className="w-4 dark:fill-white dark:stroke-white" enableBackground="new 0 0 32 32" id="Glyph" version="1.1" viewBox="0 0 32 32"><path d="M27.414,24.586l-5.077-5.077C23.386,17.928,24,16.035,24,14c0-5.514-4.486-10-10-10S4,8.486,4,14  s4.486,10,10,10c2.035,0,3.928-0.614,5.509-1.663l5.077,5.077c0.78,0.781,2.048,0.781,2.828,0  C28.195,26.633,28.195,25.367,27.414,24.586z M7,14c0-3.86,3.14-7,7-7s7,3.14,7,7s-3.14,7-7,7S7,17.86,7,14z" id="XMLID_223_" /></svg>
                        </div>
                    </div>

                    {isComponentMounted && user && (user.auth === "OFFICER" || user.auth === "ADMIN") && (
                        <Link href="/problems/new">
                            <a className="col-start-5 ml-auto text-green-50 text-sm font-bold rounded-full bg-green-700 hover:bg-green-500 transition-colors px-4 py-2 mr-4 md:mr-0">
                                New
                            </a>
                        </Link>
                    )}
                </div>

                {showFilters && <div id="problem-filters" className="bg-neutral-100 dark:bg-neutral-800 rounded-xl p-4 flex flex-col gap-4 sm:flex-row sm:gap-24">
                    <fieldset className="flex flex-col">
                        <legend className="font-bold mb-2">Difficulty</legend>

                        <div className="flex items-center gap-2">
                            <input id="easy" type="checkbox" checked={(difficulty & 1) !== 0} onChange={() => setDifficulty(difficulty ^ 1)} />
                            <label htmlFor="easy">Easy</label>
                        </div>

                        <div className="flex items-center gap-2">
                            <input id="medium" type="checkbox" checked={(difficulty & 2) !== 0} onChange={() => setDifficulty(difficulty ^ 2)} />
                            <label htmlFor="medium">Medium</label>
                        </div>

                        <div className="flex items-center gap-2">
                            <input id="hard" type="checkbox" checked={(difficulty & 4) !== 0} onChange={() => setDifficulty(difficulty ^ 4)} />
                            <label htmlFor="hard">Hard</label>
                        </div>
                    </fieldset>

                    <fieldset>
                        <legend className="font-bold">Misc</legend>

                        <div className="flex items-center gap-2">
                            <input id="show-competition-problems" type="checkbox" name="time" checked={showCompetitionProblems} onChange={() => setShowCompetitionProblems(!showCompetitionProblems)} />
                            <label htmlFor="show-competition-problems">Show competition problems</label>
                        </div>
                    </fieldset>

                    <fieldset>
                        <legend className="font-bold">Sort By</legend>

                        <div className="flex items-center gap-2">
                            <input id="newest" type="radio" name="sort-by" checked={sortBy == "Newest"} onChange={() => setSortBy("Newest")} />
                            <label htmlFor="newest">Newest</label>
                        </div>

                        <div className="flex items-center gap-2">
                            <input id="oldest" type="radio" name="sort-by" checked={sortBy == "Oldest"} onChange={() => setSortBy("Oldest")} />
                            <label htmlFor="oldest">Oldest</label>
                        </div>
                    </fieldset>
                </div>}

                {query === ""
                    ? <ProblemInfiniteResults
                        showCompetitionProblems={showCompetitionProblems}
                        difficulty={difficulty}
                        sortBy={sortBy}
                    />
                    : <ProblemSearchResults query={query} />}
            </div>
        </>
    );
};

export default ProblemListPage;
