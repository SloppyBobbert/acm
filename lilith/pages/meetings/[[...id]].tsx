import Navbar from "../../components/navbar";
import { MeetingContext, Meeting } from "../../components/meetings";
import Activities from "../../components/meetings/activities";
import useSWR from "swr";
import { NextPage } from "next";
import { api_url } from "../../utils/fetcher";
import Schedule from "../../components/meetings/schedule";
import MeetingView from "../../components/meetings/meeting";
import { useRouter } from "next/router";
import NextError from "next/error";

type MeetingFetchError = Error & {
  status?: number;
};

async function fetchMeeting(url: string): Promise<Meeting> {
  const res = await fetch(url, {
    method: "GET",
    credentials: "include",
  });

  if (!res.ok) {
    const error = new Error("failed to make request") as MeetingFetchError;
    error.status = res.status;
    throw error;
  }

  return await res.json();
}

function EmptyMeetingState(): JSX.Element {
  return (
    <div className="bg-white dark:bg-black border-y sm:border sm:rounded-md border-neutral-300 dark:border-neutral-700 px-4 py-8">
      <h1 className="text-3xl font-extrabold">No upcoming meeting</h1>
      <p className="mt-2 text-neutral-600 dark:text-neutral-400">
        There isn&apos;t a meeting on the schedule yet. Check back later for the next ACM meeting.
      </p>
    </div>
  );
}

const Meetings: NextPage = () => {
  const { query, isReady } = useRouter();
  const meetingIdSegments = Array.isArray(query.id)
    ? query.id
    : query.id
      ? [query.id]
      : [];
  const hasInvalidMeetingPath = isReady && meetingIdSegments.length > 1;
  const id = meetingIdSegments[0] ?? "next";
  const isBaseMeetingsRoute = isReady && meetingIdSegments.length === 0;

  const { data: meeting, error } = useSWR<Meeting, MeetingFetchError>(
    isReady && !hasInvalidMeetingPath ? api_url(`/meetings/${id}`) : null,
    fetchMeeting
  );

  if (hasInvalidMeetingPath) return <NextError statusCode={404} />;
  if (error && (!isBaseMeetingsRoute || error.status !== 404)) {
    return <NextError statusCode={error.status ?? 500} />;
  }

  return (
    <MeetingContext.Provider value={meeting}>
      <Navbar />

      <div className="grid grid-rows-[min-content_1fr] md:grid-cols-[1fr_300px] md:grid-rows-1 max-w-screen-lg mx-auto gap-2 my-2">
        <div className="sm:px-2 flex flex-col gap-2">
          {isBaseMeetingsRoute && error ? (
            <EmptyMeetingState />
          ) : (
            <>
              <MeetingView />
              <Activities />
            </>
          )}
        </div>

        <Schedule />
      </div>
    </MeetingContext.Provider>
  );
};

export default Meetings;
