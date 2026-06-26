import type { NextPage } from "next";
import Head from "next/head";
import Link from "next/link";
import useSWR from "swr";
import Navbar from "../../components/navbar";
import { api_url, fetcher } from "../../utils/fetcher";
import { User } from "../../utils/state";

export type Competition = {
  id: number,
  name: string,
  start: string,
  end: string,
};

function CompetitionListItem({ id, name, start }: Competition): JSX.Element {
  return (
    <Link href={`/competitions/${id}`}>
      <a className="border-neutral-300 p-4 border-y md:border md:rounded-md bg-white dark:bg-black dark:border-neutral-700 dark:hover:bg-neutral-900 flex flex-col gap-2 hover:shadow-md transition-all">
        <h1 className="text-2xl font-bold">{name}</h1>
        <span className="text-neutral-700 dark:text-neutral-400">{new Intl.DateTimeFormat('en-US', { dateStyle: 'long', timeStyle: undefined }).format(new Date(start))}</span>
      </a>
    </Link>
  );
}

function EmptyCompetitions({ canCreate }: { canCreate: boolean }): JSX.Element {
  return (
    <div className="border-y md:border md:rounded-md border-neutral-300 bg-white dark:bg-black dark:border-neutral-700 px-6 py-10 text-center">
      <h2 className="text-2xl font-bold">No competitions yet</h2>
      <p className="mt-2 text-neutral-600 dark:text-neutral-400">
        Add a local competition to see it listed here.
      </p>

      {canCreate && (
        <Link href="/competitions/new">
          <a className="inline-flex mt-4 text-green-50 text-sm font-bold rounded-full bg-green-700 hover:bg-green-500 transition-colors px-4 py-2">
            Create Competition
          </a>
        </Link>
      )}
    </div>
  );
}

export function CompetitionGrid({ canCreate = false }: { canCreate?: boolean }): JSX.Element {
  const { data, error } = useSWR<Competition[]>(api_url("/competitions"), fetcher);

  if (error)
    return <></>;

  if (!data)
    return <></>;

  if (data.length === 0)
    return <EmptyCompetitions canCreate={canCreate} />;

  return (
    <div className="grid md:grid-cols-2 gap-4">

      {data.map((competition, i) => <CompetitionListItem key={i} {...competition} />)}
    </div>
  );
}

const CompetitionsPage: NextPage = () => {
  const { data: user, error: _error } = useSWR<User>(
    api_url("/user/me"),
    fetcher, {
    shouldRetryOnError: false,
  });

  const canCreate = !!user && (user.auth === "OFFICER" || user.auth === "ADMIN");

  return (
    <>
      <Navbar />

      <Head>
        <title>Competitions</title>
      </Head>

      <div className="flex flex-col max-w-screen-md mx-auto my-4 gap-4">
        <div className="flex">
          <h1 className="text-3xl font-extrabold ml-4 md:ml-0">Competitions</h1>

          {canCreate && (
            <Link href="/competitions/new">
              <a className="ml-auto text-green-50 text-sm font-bold rounded-full bg-green-700 hover:bg-green-500 transition-colors px-4 py-2 mr-4 md:mr-0">
                New Competition
              </a>
            </Link>
          )}
        </div>

        <CompetitionGrid canCreate={canCreate} />
      </div>
    </>
  );
};

export default CompetitionsPage;
