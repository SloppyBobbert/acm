type ServerErrorResponse = {
    error?: string;
};

export async function getResponseError(
    res: Response,
    fallback = "Request failed."
): Promise<string> {
    try {
        let data = await res.json() as ServerErrorResponse;

        if (typeof data.error === "string" && data.error.trim().length > 0) {
            return data.error;
        }
    }
    catch {
    }

    return fallback;
}
