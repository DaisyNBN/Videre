import { createClient } from "@supabase/supabase-js";
import "dotenv/config";

const supabaseUrl = process.env.SUPABASE_URL;
const supabaseKey = process.env.SERVICE_ROLE_KEY;

if (!supabaseUrl) {
    throw new Error("Missing SUPABASE_URL environment variable");
}

if (!supabaseKey) {
    throw new Error(
        "Missing SERVICE_ROLE_KEY environment variable",
    );
}

export const supabase = createClient(supabaseUrl, supabaseKey);

export default supabase;
