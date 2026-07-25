# P3 fixture policy

Battle and quest fixtures must be synthetic, public, or developer-owned and
redacted. Never add `api_token`, cookies, member IDs, nicknames, login IDs, or
passwords. Expected phase order and final HP must be calculated independently
from the Swift implementation.

## Task 8 quest fixtures

`quest_track_minimal.json` and `quests_jp_minimal.json` are a minimal, non-user-data subset extracted from:

- `/Users/haozhe/GitHub/kcanotify-master/app/src/main/assets/quest_track.json`
- `/Users/haozhe/GitHub/kcanotify-master/app/src/main/assets/quests-jp.json`

They retain only representative daily/weekly/monthly/quarterly definitions and the Android compatibility IDs needed by task 8 (`211/212`, `311/318/330/337/339/342`, `411/607/608`). They contain public static quest metadata only—no account, token, member ID, request body, or user progress.

`questlist_sync.json` is synthetic and tests `api_list` synchronization, including the `-1` placeholder and a definition-missing server-only quest.
