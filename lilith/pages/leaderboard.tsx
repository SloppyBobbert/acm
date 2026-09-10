import { NextPage } from "next";
import Head from "next/head";
import Link from "next/link";
import useSWR from "swr";
import ErrorBox from "../components/error-box";
import Navbar from "../components/navbar";
import { api_url, fetcher } from "../utils/fetcher";

type LeaderboardItem = {
  username: string;
  name: string;
  count: number;
};

type LeaderboardEntryProps = {
  index: number;
  username: string;
  name: string;
  count: number;
};

function LeaderboardEntry({
  name,
  username,
  index,
  count,
}: LeaderboardEntryProps): JSX.Element {
  return (
    <Link href={`/user/${username}`}>
      <a className="focus-ring surface-list-item flex flex-row gap-4 p-4">
        <div className="flex h-9 w-9 items-center justify-center self-center rounded-full bg-blue-700 text-xl font-bold text-neutral-50">
          {index}
        </div>
        <div className="flex flex-col">
          <span className="text-xl font-bold">{name}</span>
          <span className="text-neutral-500 dark:text-neutral-400">
            {username}
          </span>
        </div>
        <span className="badge-star ml-auto">
          {count} ★
        </span>
      </a>
    </Link>
  );
}

function LoadingLeaderboardEntry(): JSX.Element {
  return (
    <div className="flex flex-col gap-4 border-b border-neutral-300 p-4 last:border-b-0 dark:border-neutral-700">
      <div className="h-5 w-32 animate-pulse rounded bg-neutral-300" />
      <div className="h-4 w-24 animate-pulse rounded bg-neutral-300" />
    </div>
  );
}

const Leaderboard: NextPage = () => {
  const { data, error } = useSWR<LeaderboardItem[]>(
    api_url("/leaderboard/first-place"),
    fetcher
  );

  return (
    <div className="page-shell">
      <Navbar />

      <Head>
        <title>Leaderboard</title>
      </Head>

      <main className="page-main mb-12">
        <h1 className="page-heading mb-4 px-4 md:px-0">Leaderboard</h1>

        {error ? (
          <div className="px-4 md:px-0">
            <ErrorBox>Could not load the leaderboard.</ErrorBox>
          </div>
        ) : (
          <div className="surface-card sm:mx-2 md:mx-0">
            {!data ? (
              <div aria-busy="true" aria-label="Loading leaderboard">
                {Array(3)
                  .fill(0)
                  .map((_, i) => (
                    <LoadingLeaderboardEntry key={i} />
                  ))}
              </div>
            ) : data.length === 0 ? (
              <p className="p-4 text-neutral-500 dark:text-neutral-400">
                No rankings yet.
              </p>
            ) : (
              data.map((entry, i) => (
                <LeaderboardEntry key={entry.username} index={i + 1} {...entry} />
              ))
            )}
          </div>
        )}
      </main>

    </div>
  );
};

export default Leaderboard;
