import type { NextPage } from "next";
import Head from "next/head";
import useSWR from "swr";
import Footer from "../components/footer";
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
        return <div className="animate-pulse h-full bg-neutral-100 dark:bg-neutral-900" />;
    }

    const featuredProblem = data?.[0];

    if (error) {
        return (
            <div className="h-full flex flex-col items-center justify-center gap-2 bg-white dark:bg-black p-8 text-center">
                <h2 className="text-2xl font-bold">Could not load featured problem</h2>
                <p className="max-w-md text-neutral-600 dark:text-neutral-400">
                    Check that the API is running and reachable from the frontend.
                </p>
            </div>
        );
    }

    if (!featuredProblem) {
        return (
            <div className="h-full flex flex-col items-center justify-center gap-2 bg-white dark:bg-black p-8 text-center">
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
        <div className="overflow-x-hidden flex flex-col gap-4 min-h-screen">
            <Head>
                <title>Chico ACM</title>
            </Head>

            <Navbar />

            <h1 className="py-4 text-6xl drop-shadow-md text-center font-extrabold text-transparent bg-clip-text bg-gradient-to-b from-neutral-600 to-neutral-900 dark:from-neutral-50 dark:to-neutral-400">
                Chico ACM
            </h1>

            <div className="md:container w-full mx-auto">
                <h2 className="font-bold text-xl mx-2 md:mx-0">Local Competitions</h2>
                <CompetitionGrid />
            </div>

            <div className="md:container md:h-[80vh] md:shadow md:rounded border-neutral-300 dark:border-neutral-700 mx-auto border-y md:border-x w-full overflow-auto">
                <FeaturedProblemView />
            </div>

            <Footer />
        </div>
    );
};

export default Home;
