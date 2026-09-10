import type { NextPage } from "next";
import Head from "next/head";
import useSWR from "swr";
import ErrorBox from "../components/error-box";
import Navbar from "../components/navbar";
import ProblemView from "../components/problem";
import { CompetitionGrid } from "./competitions";
import { api_url, fetcher } from "../utils/fetcher";

type FeaturedProblem = {
    id: number;
};

function FeaturedProblemView(): JSX.Element {
    const { data, error } = useSWR<FeaturedProblem[]>(
        api_url("/problems?count=1&sort_by=Newest"),
        fetcher,
        { shouldRetryOnError: false }
    );

    if (!data && !error) {
        return (
            <div
                className="h-full min-h-[16rem] animate-pulse bg-neutral-100 dark:bg-neutral-900"
                aria-busy="true"
                aria-label="Loading featured problem"
            />
        );
    }

    const featuredProblem = data?.[0];

    if (error) {
        return (
            <div className="flex h-full flex-col items-center justify-center bg-white p-8 dark:bg-black">
                <ErrorBox>
                    Could not load featured problem. Check that the API is running and reachable from the frontend.
                </ErrorBox>
            </div>
        );
    }

    if (!featuredProblem) {
        return (
            <div className="flex h-full flex-col items-center justify-center gap-2 bg-white p-8 text-center dark:bg-black">
                <h2 className="text-2xl font-bold">No featured problem yet</h2>
                <p className="max-w-md text-neutral-600 dark:text-neutral-400">
                    Create a problem from the Problems page after logging in as an officer.
                </p>
            </div>
        );
    }

    return <ProblemView id={featuredProblem.id} />;
}

const Home: NextPage = () => {
    return (
        <div className="page-shell overflow-x-hidden gap-4">
            <Head>
                <title>Chico ACM</title>
            </Head>

            <Navbar />

            <main className="flex flex-col gap-4">
                <h1 className="bg-gradient-to-b from-neutral-600 to-neutral-900 bg-clip-text py-4 text-center text-6xl font-extrabold text-transparent drop-shadow-md dark:from-neutral-50 dark:to-neutral-400">
                    Chico ACM
                </h1>

                <div className="w-full mx-auto md:container">
                    <h2 className="mx-2 text-xl font-bold md:mx-0">Local Competitions</h2>
                    <CompetitionGrid />
                </div>

                <div className="mx-auto w-full overflow-auto border-y border-neutral-300 dark:border-neutral-700 md:container md:h-[80vh] md:rounded md:border md:shadow">
                    <FeaturedProblemView />
                </div>
            </main>

        </div>
    );
};

export default Home;
